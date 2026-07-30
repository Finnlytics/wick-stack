defmodule Wick.Uplink do
  @moduledoc """
  Transport-agnostic types for **client-initiated** LwM2M messages — the client (device)
  pushes data to the server.

  In contrast to `Wick.Request` (server → client), uplinks travel client → server. Wick
  models the two directions in different namespaces because the operational surface is
  small enough on the uplink side, and it keeps "who initiates" pattern-match-visible at
  consumer call sites.

  ## Operations covered

  | Struct                | LwM2M § | Purpose                                                  |
  |-----------------------|:-------:|----------------------------------------------------------|
  | `Wick.Uplink.Notify`  | RFC 7641 / 6.4.6 | One value-update for a previously established Observe relation |
  | `Wick.Uplink.Send`    | 6.4.13  | Client-initiated push of one or more Resource values without a prior Observe (1.1+) |

  The Registration interface (Register / Update / De-register) lives in
  `Wick.Registration`; Bootstrap-Request lives in `Wick.Bootstrap`.

  ## Wire form

  `to_wire/1` and `from_wire/1` map both uplinks onto their transport-agnostic form. Note
  the two land on **different** types, because they are different things at the CoAP layer:

  * A **Send** is a request the client initiates — `POST /dp` — so it becomes a
    `Wick.Wire`.
  * A **Notify** is a *response* in an Observe exchange — a `2.05 Content` carrying the
    RFC 7641 Observe option — so it becomes a `Wick.Wire.Response`.

  `from_wire/1` dispatches on which of the two it is handed, so a receiver can funnel both
  through one call.

  ## Notify vs Send

  Both carry a SenML-encoded payload of one or more Resource values. The differences are
  semantic, not structural:

  * **Notify** is the response stream of an `Observe` request. The server already knows
    which path(s) it asked to observe; the Notify carries the new value(s) plus an
    Observe sequence number that the server uses to detect reorderings.
  * **Send** has no prior server request. The client decides to push, the server decides
    whether and how to record. There is no sequence number; deduplication is the
    consumer's problem (typically via a per-record timestamp).

  Pattern match on the struct to dispatch:

      def handle_uplink(%Wick.Uplink.Notify{} = n), do: ...
      def handle_uplink(%Wick.Uplink.Send{} = s), do: ...
  """

  alias Wick.Error
  alias Wick.Wire

  @data_path ["dp"]

  @typedoc "Any client-initiated uplink message."
  @type t :: __MODULE__.Notify.t() | __MODULE__.Send.t()

  defmodule Notify do
    @moduledoc """
    A Notification — one value-update for a previously established `Wick.Request.Observe`
    or `Wick.Request.ObserveComposite` relation.

    Wick does not carry the path here. The path(s) covered by this Notify are determined
    by the gateway from the Observe relation registry (token + source-device tuple). For
    Composite Observe the payload itself carries the paths.

    `:observe_seq` is the [RFC 7641 §3.4](https://www.rfc-editor.org/rfc/rfc7641#section-3.4)
    Observe sequence number — a 24-bit unsigned counter that the server uses to detect
    notifications delivered out of order. Larger values are newer modulo the standard
    "less-than" comparison defined by the RFC.

    ## Examples

        iex> n = %Wick.Uplink.Notify{content_format: 112, payload: <<0x81, 0xA1, 0x02, 0x05>>, observe_seq: 42}
        iex> n.observe_seq
        42
    """

    @typedoc "A Notification."
    @type t :: %__MODULE__{
            content_format: non_neg_integer(),
            payload: binary(),
            observe_seq: non_neg_integer()
          }

    @enforce_keys [:content_format, :payload, :observe_seq]
    defstruct [:content_format, :payload, :observe_seq]
  end

  defmodule Send do
    @moduledoc """
    A Send operation — client-initiated push of one or more Resource values
    (LwM2M 1.1+, §6.4.13).

    The CoAP wire form is a POST to `/dp` (data path); the body is a SenML payload where
    each record's `name` is the source path. Wick keeps `payload` as the encoded bytes;
    the gateway decodes via `Wick.Codec.SenmlCbor` / `Wick.Codec.SenmlJson` to produce a
    `Wick.Senml.Pack`.

    Send carries no Observe sequence number — there's no prior relation. Deduplication
    and ordering are the consumer's concern, typically via per-record timestamps in the
    SenML payload (`bt` / `t`).

    ## Examples

        iex> s = %Wick.Uplink.Send{content_format: 112, payload: <<0x80>>}
        iex> s.content_format
        112
    """

    @typedoc "A Send operation."
    @type t :: %__MODULE__{
            content_format: non_neg_integer(),
            payload: binary()
          }

    @enforce_keys [:content_format, :payload]
    defstruct [:content_format, :payload]
  end

  # ── Wire conversion ────────────────────────────────────────────────────────

  @doc """
  The URI path a Send is POSTed to (LwM2M 1.2 §6.4.13): `/dp`, the "data push" endpoint.
  """
  @spec data_path() :: [String.t()]
  def data_path, do: @data_path

  @doc """
  Convert an uplink to its transport-agnostic wire form.

  A `Wick.Uplink.Send` becomes a `Wick.Wire` (a `POST` to `/dp`); a `Wick.Uplink.Notify`
  becomes a `Wick.Wire.Response` (`2.05 Content` plus the Observe sequence number).

  ## Examples

      iex> wire = Wick.Uplink.to_wire(%Wick.Uplink.Send{content_format: 112, payload: <<0x80>>})
      iex> {wire.method, wire.path, wire.content_format}
      {:post, ["dp"], 112}

      iex> notify = %Wick.Uplink.Notify{content_format: 112, payload: <<0x80>>, observe_seq: 7}
      iex> Wick.Uplink.to_wire(notify)
      %Wick.Wire.Response{status: :content, content_format: 112, payload: <<0x80>>, observe_seq: 7}
  """
  @spec to_wire(__MODULE__.Send.t()) :: Wire.t()
  @spec to_wire(__MODULE__.Notify.t()) :: Wire.Response.t()
  def to_wire(%__MODULE__.Send{} = send) do
    %Wire{
      method: :post,
      path: @data_path,
      payload: send.payload,
      content_format: send.content_format
    }
  end

  def to_wire(%__MODULE__.Notify{} = notify) do
    %Wire.Response{
      status: :content,
      payload: notify.payload,
      content_format: notify.content_format,
      observe_seq: notify.observe_seq
    }
  end

  @doc """
  Recover an uplink from its wire form — the inverse of `to_wire/1`.

  Dispatches on the wire type, so a receiver handling both inbound requests and inbound
  notifications can funnel everything through this one call.

  Returns `{:error, %Wick.Error{}}` with code:

  * `:not_an_uplink` — a `Wick.Wire` that is not a `POST` to `/dp`, or a
    `Wick.Wire.Response` with no Observe option (i.e. an ordinary response, not a Notify).
  * `:missing_content_format` — a payload with no Content-Format to interpret it by.

  ## Examples

      iex> {:ok, wire} = Wick.Wire.parse(:post, [{11, "dp"}, {12, <<112>>}], <<0x80>>)
      iex> Wick.Uplink.from_wire(wire)
      {:ok, %Wick.Uplink.Send{content_format: 112, payload: <<0x80>>}}

      iex> {:ok, wire} = Wick.Wire.Response.parse({2, 5}, [{6, <<7>>}, {12, <<112>>}], <<0x80>>)
      iex> Wick.Uplink.from_wire(wire)
      {:ok, %Wick.Uplink.Notify{content_format: 112, payload: <<0x80>>, observe_seq: 7}}

      iex> {:ok, wire} = Wick.Wire.parse(:post, [{11, "rd"}], "")
      iex> {:error, err} = Wick.Uplink.from_wire(wire)
      iex> err.code
      :not_an_uplink
  """
  @spec from_wire(Wire.t() | Wire.Response.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(%Wire{method: :post, path: @data_path} = wire) do
    with {:ok, content_format} <- require_content_format(wire.content_format, "Send") do
      {:ok, %__MODULE__.Send{content_format: content_format, payload: wire.payload}}
    end
  end

  def from_wire(%Wire{} = wire) do
    {:error,
     Error.new(
       :not_an_uplink,
       "expected a POST to /dp, got #{inspect(wire.method)} /#{Enum.join(wire.path, "/")}",
       method: wire.method,
       path: wire.path
     )}
  end

  def from_wire(%Wire.Response{observe_seq: nil}) do
    {:error,
     Error.new(
       :not_an_uplink,
       "a Notify must carry the Observe option; this response has none"
     )}
  end

  def from_wire(%Wire.Response{} = wire) do
    with {:ok, content_format} <- require_content_format(wire.content_format, "Notify") do
      {:ok,
       %__MODULE__.Notify{
         content_format: content_format,
         payload: wire.payload,
         observe_seq: wire.observe_seq
       }}
    end
  end

  defp require_content_format(nil, operation) do
    {:error,
     Error.new(
       :missing_content_format,
       "a #{operation} payload needs a Content-Format option to be interpretable"
     )}
  end

  defp require_content_format(content_format, _operation), do: {:ok, content_format}
end

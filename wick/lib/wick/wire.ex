defmodule Wick.Wire do
  @moduledoc """
  Transport-agnostic wire specification for an LwM2M request, plus a
  dependency-free mapping onto CoAP option numbers.

  Every LwM2M operation ultimately becomes a CoAP message. Wick refuses to depend on a
  CoAP library (see [ADR 0001](../decisions/0001-zero-runtime-dependencies.md) and
  [ADR 0004](../decisions/0004-wick-coap-as-sibling-library.md)), so the boundary is drawn
  here: Wick produces a `%Wick.Wire{}` describing *what* to send, along with
  `to_coap_options/1`, which flattens the spec into `{option_number, value_bytes}` tuples
  the consumer hands straight to its CoAP layer.

  With `wick_coap` that adapter is two lines:

      wire = Wick.Request.to_wire(request)

      options =
        Enum.map(Wick.Wire.to_coap_options(wire), fn {number, value} ->
          WickCoap.Option.new(number, value)
        end)

      %WickCoap.Message{
        type: :con,
        code: wire.method,
        message_id: 0,
        token: <<>>,
        options: options,
        payload: wire.payload
      }

  The reverse direction — a device or gateway receiving a request — is `parse/3`. See
  [ADR 0005](../decisions/0005-coap-option-tuples-at-the-wick-boundary.md) for why the
  boundary sits at option *numbers* rather than at a CoAP struct.

  ## Methods

  `:get`, `:post`, `:put`, `:delete` are RFC 7252. `:fetch` and `:ipatch` are
  [RFC 8132](https://www.rfc-editor.org/rfc/rfc8132) and carry the LwM2M 1.1+ Composite
  operations. The atoms match `WickCoap.Code`'s method atoms exactly, so a consumer can
  assign `wire.method` to a CoAP message's `:code` field without translation.

  ## Option numbers

  Wick emits only the six options LwM2M needs. The numbers are fixed by the CoAP
  registry, mirrored here so consumers can filter or assert on them by name:

  | Option         | Number | Source            |
  |----------------|:------:|-------------------|
  | Observe        | 6      | RFC 7641 §2       |
  | Location-Path  | 8      | RFC 7252 §5.10.7  |
  | Uri-Path       | 11     | RFC 7252 §5.10.1  |
  | Content-Format | 12     | RFC 7252 §5.10.3  |
  | Uri-Query      | 15     | RFC 7252 §5.10.1  |
  | Accept         | 17     | RFC 7252 §5.10.4  |

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0/9")
      iex> wire = Wick.Request.to_wire(%Wick.Request.Read{path: path, accept_content_format: 112})
      iex> Wick.Wire.to_coap_options(wire)
      [{11, "3"}, {11, "0"}, {11, "9"}, {17, <<112>>}]

      iex> {:ok, wire} = Wick.Wire.parse(:get, [{11, "3"}, {11, "0"}, {11, "9"}], "")
      iex> {wire.method, wire.path}
      {:get, ["3", "0", "9"]}
  """

  alias Wick.Error

  @observe 6
  @location_path 8
  @uri_path 11
  @content_format 12
  @uri_query 15
  @accept 17

  @typedoc "A CoAP method that LwM2M uses. Matches `WickCoap.Code`'s method atoms."
  @type method :: :get | :post | :put | :delete | :fetch | :ipatch

  @typedoc """
  Uri-Query parameters as ordered key/value pairs.

  A `nil` value emits a bare flag (`Q`) rather than `key=value`.
  """
  @type query :: [{String.t(), String.t() | number() | nil}]

  @typedoc """
  The Observe option value: `0` registers an observation, `1` cancels one, `nil` omits
  the option entirely ([RFC 7641 §2](https://www.rfc-editor.org/rfc/rfc7641#section-2)).
  """
  @type observe :: 0 | 1 | nil

  @typedoc "A request in transport-agnostic form."
  @type t :: %__MODULE__{
          method: method(),
          path: [String.t()],
          query: query(),
          payload: binary(),
          content_format: non_neg_integer() | nil,
          accept: non_neg_integer() | nil,
          observe: observe()
        }

  defstruct method: :get,
            path: [],
            query: [],
            payload: "",
            content_format: nil,
            accept: nil,
            observe: nil

  @typedoc "A `{option_number, value_bytes}` pair, ready for a CoAP option constructor."
  @type coap_option :: {non_neg_integer(), binary()}

  # ── Option numbers ─────────────────────────────────────────────────────────

  @doc "CoAP option number for Observe (6)."
  @spec observe_option() :: 6
  def observe_option, do: @observe

  @doc "CoAP option number for Location-Path (8)."
  @spec location_path_option() :: 8
  def location_path_option, do: @location_path

  @doc "CoAP option number for Uri-Path (11)."
  @spec uri_path_option() :: 11
  def uri_path_option, do: @uri_path

  @doc "CoAP option number for Content-Format (12)."
  @spec content_format_option() :: 12
  def content_format_option, do: @content_format

  @doc "CoAP option number for Uri-Query (15)."
  @spec uri_query_option() :: 15
  def uri_query_option, do: @uri_query

  @doc "CoAP option number for Accept (17)."
  @spec accept_option() :: 17
  def accept_option, do: @accept

  # ── Encoding ───────────────────────────────────────────────────────────────

  @doc """
  Flatten a wire spec into `{option_number, value_bytes}` tuples, sorted by option
  number ascending (the order CoAP's delta encoding wants).

  Repeated options — Uri-Path segments, Uri-Query parameters — keep their relative order.
  Unsigned-integer options (Observe, Content-Format, Accept) use the shortest byte
  representation per [RFC 7252 §3.2](https://www.rfc-editor.org/rfc/rfc7252#section-3.2),
  so a zero value is the empty binary.

  ## Examples

      iex> wire = %Wick.Wire{method: :post, path: ["rd"], query: [{"ep", "d1"}, {"Q", nil}]}
      iex> Wick.Wire.to_coap_options(wire)
      [{11, "rd"}, {15, "ep=d1"}, {15, "Q"}]

      iex> wire = %Wick.Wire{method: :get, path: ["3"], observe: 0}
      iex> Wick.Wire.to_coap_options(wire)
      [{6, ""}, {11, "3"}]
  """
  @spec to_coap_options(t()) :: [coap_option()]
  def to_coap_options(%__MODULE__{} = wire) do
    [
      uint_option(@observe, wire.observe),
      Enum.map(wire.path, &{@uri_path, &1}),
      Enum.map(wire.query, &encode_query_pair/1),
      uint_option(@content_format, wire.content_format),
      uint_option(@accept, wire.accept)
    ]
    |> List.flatten()
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Encode a non-negative integer in the shortest big-endian form CoAP allows. Zero is the
  empty binary.

  ## Examples

      iex> Wick.Wire.encode_uint(0)
      ""

      iex> Wick.Wire.encode_uint(112)
      <<112>>

      iex> Wick.Wire.encode_uint(1543)
      <<6, 7>>
  """
  @spec encode_uint(non_neg_integer()) :: binary()
  def encode_uint(0), do: <<>>

  def encode_uint(value) when is_integer(value) and value > 0 do
    :binary.encode_unsigned(value, :big)
  end

  @doc """
  Decode a CoAP unsigned-integer option value. The empty binary decodes to `0`.

  ## Examples

      iex> Wick.Wire.decode_uint("")
      0

      iex> Wick.Wire.decode_uint(<<6, 7>>)
      1543
  """
  @spec decode_uint(binary()) :: non_neg_integer()
  def decode_uint(<<>>), do: 0
  def decode_uint(value) when is_binary(value), do: :binary.decode_unsigned(value, :big)

  # ── Decoding ───────────────────────────────────────────────────────────────

  @doc """
  Build a wire spec from an inbound CoAP request: its method, its options as
  `{number, value_bytes}` tuples, and its payload.

  Options Wick does not model are ignored — a CoAP layer may legitimately carry Block1,
  Block2, Uri-Host, and others that have no bearing on LwM2M semantics.

  Returns `{:error, %Wick.Error{code: :unsupported_method}}` for a method LwM2M never
  uses (notably `:patch`, which LwM2M 1.2 does not define an operation for).

  ## Examples

      iex> {:ok, wire} = Wick.Wire.parse(:put, [{11, "3"}, {11, "0"}, {12, <<112>>}], <<0x80>>)
      iex> {wire.method, wire.path, wire.content_format, wire.payload}
      {:put, ["3", "0"], 112, <<128>>}

      iex> {:ok, wire} = Wick.Wire.parse(:post, [{15, "ep=d1"}, {15, "Q"}], "")
      iex> wire.query
      [{"ep", "d1"}, {"Q", nil}]

      iex> {:error, err} = Wick.Wire.parse(:patch, [], "")
      iex> err.code
      :unsupported_method
  """
  @spec parse(atom(), [coap_option()], binary()) :: {:ok, t()} | {:error, Error.t()}
  def parse(method, options, payload)
      when method in [:get, :post, :put, :delete, :fetch, :ipatch] and is_list(options) and
             is_binary(payload) do
    {:ok,
     %__MODULE__{
       method: method,
       path: collect(options, @uri_path),
       query: options |> collect(@uri_query) |> Enum.map(&decode_query_pair/1),
       payload: payload,
       content_format: first_uint(options, @content_format),
       accept: first_uint(options, @accept),
       observe: first_uint(options, @observe)
     }}
  end

  def parse(method, options, payload)
      when is_atom(method) and is_list(options) and is_binary(payload) do
    {:error,
     Error.new(:unsupported_method, "LwM2M defines no operation for method #{inspect(method)}",
       method: method
     )}
  end

  @doc """
  Collect every value for `number` from a CoAP option list, in order.

  ## Examples

      iex> Wick.Wire.collect([{11, "3"}, {12, <<0>>}, {11, "0"}], 11)
      ["3", "0"]
  """
  @spec collect([coap_option()], non_neg_integer()) :: [binary()]
  def collect(options, number) when is_list(options) and is_integer(number) do
    for {^number, value} <- options, do: value
  end

  @doc """
  Read the first occurrence of `number` as an unsigned integer, or `nil` when absent.

  ## Examples

      iex> Wick.Wire.first_uint([{12, <<112>>}], 12)
      112

      iex> Wick.Wire.first_uint([{6, ""}], 6)
      0

      iex> Wick.Wire.first_uint([], 6)
      nil
  """
  @spec first_uint([coap_option()], non_neg_integer()) :: non_neg_integer() | nil
  def first_uint(options, number) when is_list(options) and is_integer(number) do
    case collect(options, number) do
      [] -> nil
      [value | _] -> decode_uint(value)
    end
  end

  @doc """
  Look up a Uri-Query parameter by key in a parsed `t:query/0`.

  Returns `{:ok, value}` (with `nil` for a bare flag) or `:error`. Callers that treat a
  flag's presence as the whole signal can pattern match `{:ok, _}`.

  ## Examples

      iex> Wick.Wire.fetch_query([{"ep", "device-1"}, {"Q", nil}], "ep")
      {:ok, "device-1"}

      iex> Wick.Wire.fetch_query([{"Q", nil}], "Q")
      {:ok, nil}

      iex> Wick.Wire.fetch_query([], "ep")
      :error
  """
  @spec fetch_query(query(), String.t()) :: {:ok, String.t() | number() | nil} | :error
  def fetch_query(query, key) when is_list(query) and is_binary(key) do
    case List.keyfind(query, key, 0) do
      {^key, value} -> {:ok, value}
      nil -> :error
    end
  end

  # ── Response ───────────────────────────────────────────────────────────────

  defmodule Response do
    @moduledoc """
    Transport-agnostic wire form of a response to any LwM2M operation.

    The counterpart to `Wick.Wire`. `status` is a `t:Wick.Status.t/0` atom — the consumer
    converts to a CoAP code pair via `Wick.Status.to_coap/1`, which is exactly the shape
    `WickCoap.Code.encode/1` accepts.

    `location_path` holds raw path segments rather than a `Wick.Path`, because the two
    LwM2M uses of Location-Path have different shapes: Create returns an Object Instance
    path (`["3", "0"]`) while Register returns a registration handle (`["rd", "xyz"]`).
    `Wick.Response.from_wire/1` narrows the former to a `Wick.Path`.

    `observe_seq` carries the [RFC 7641 §3.4](https://www.rfc-editor.org/rfc/rfc7641#section-3.4)
    notification sequence number on Notify responses, and the initial sequence number on
    the response to an Observe. It is `nil` on every other response.
    """

    alias Wick.Status
    alias Wick.Wire

    @typedoc "A response in transport-agnostic form."
    @type t :: %__MODULE__{
            status: Status.t(),
            payload: binary(),
            content_format: non_neg_integer() | nil,
            location_path: [String.t()],
            observe_seq: non_neg_integer() | nil
          }

    @enforce_keys [:status]
    defstruct [:status, :content_format, :observe_seq, payload: "", location_path: []]

    @doc """
    Flatten a response spec into `{option_number, value_bytes}` tuples, sorted by option
    number ascending.

    ## Examples

        iex> resp = %Wick.Wire.Response{status: :content, content_format: 112, payload: <<0x80>>}
        iex> Wick.Wire.Response.to_coap_options(resp)
        [{12, <<112>>}]

        iex> resp = %Wick.Wire.Response{status: :created, location_path: ["3", "0"]}
        iex> Wick.Wire.Response.to_coap_options(resp)
        [{8, "3"}, {8, "0"}]
    """
    @spec to_coap_options(t()) :: [Wire.coap_option()]
    def to_coap_options(%__MODULE__{} = response) do
      observe =
        case response.observe_seq do
          nil -> []
          seq -> [{Wire.observe_option(), Wire.encode_uint(seq)}]
        end

      content_format =
        case response.content_format do
          nil -> []
          value -> [{Wire.content_format_option(), Wire.encode_uint(value)}]
        end

      location = Enum.map(response.location_path, &{Wire.location_path_option(), &1})

      (observe ++ location ++ content_format)
      |> Enum.sort_by(&elem(&1, 0))
    end

    @doc """
    Build a response spec from an inbound CoAP response: its code, its options as
    `{number, value_bytes}` tuples, and its payload.

    The code is accepted either as a `{class, detail}` pair or as the single packed byte
    CoAP puts on the wire, since that is the form a transport is most likely to hand over.
    `WickCoap` exposes codes as atoms, so convert with `WickCoap.Code.encode/1` first:

        Wick.Wire.Response.parse(WickCoap.Code.encode(message.code), options, message.payload)

    Returns `{:error, %Wick.Error{code: :unrecognised_status}}` for a CoAP code outside
    LwM2M's recognised set — see `Wick.Status.from_coap/1`.

    ## Examples

        iex> {:ok, resp} = Wick.Wire.Response.parse({2, 5}, [{12, <<112>>}], <<0x80>>)
        iex> {resp.status, resp.content_format, resp.payload}
        {:content, 112, <<128>>}

        iex> {:ok, resp} = Wick.Wire.Response.parse(0x45, [{12, <<112>>}], <<0x80>>)
        iex> resp.status
        :content

        iex> {:ok, resp} = Wick.Wire.Response.parse({2, 1}, [{8, "3"}, {8, "0"}], "")
        iex> {resp.status, resp.location_path}
        {:created, ["3", "0"]}

        iex> {:error, err} = Wick.Wire.Response.parse({4, 3}, [], "")
        iex> err.code
        :unrecognised_status
    """
    @spec parse(Status.coap_code() | 0..255, [Wire.coap_option()], binary()) ::
            {:ok, t()} | {:error, Wick.Error.t()}
    def parse(byte, options, payload)
        when is_integer(byte) and byte in 0..255 and is_list(options) and is_binary(payload) do
      parse({Bitwise.bsr(byte, 5), Bitwise.band(byte, 0x1F)}, options, payload)
    end

    def parse({class, detail} = code, options, payload)
        when class in 0..7 and detail in 0..31 and is_list(options) and is_binary(payload) do
      case Status.from_coap(code) do
        nil ->
          {:error,
           Wick.Error.new(
             :unrecognised_status,
             "CoAP code #{class}.#{String.pad_leading(Integer.to_string(detail), 2, "0")} " <>
               "is not an LwM2M status",
             code: code
           )}

        status ->
          {:ok,
           %__MODULE__{
             status: status,
             payload: payload,
             content_format: Wire.first_uint(options, Wire.content_format_option()),
             location_path: Wire.collect(options, Wire.location_path_option()),
             observe_seq: Wire.first_uint(options, Wire.observe_option())
           }}
      end
    end
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp uint_option(_number, nil), do: []
  defp uint_option(number, value), do: [{number, encode_uint(value)}]

  defp encode_query_pair({key, nil}), do: {@uri_query, key}

  defp encode_query_pair({key, value}) when is_binary(value),
    do: {@uri_query, key <> "=" <> value}

  defp encode_query_pair({key, value}) when is_integer(value),
    do: {@uri_query, key <> "=" <> Integer.to_string(value)}

  defp encode_query_pair({key, value}) when is_float(value),
    do: {@uri_query, key <> "=" <> Wick.Json.encode_float(value)}

  defp decode_query_pair(raw) do
    case String.split(raw, "=", parts: 2) do
      [key] -> {key, nil}
      [key, value] -> {key, value}
    end
  end
end

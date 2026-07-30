defmodule Wick.Request do
  @moduledoc """
  Transport-agnostic types for the LwM2M downlink request operations a server can issue
  against a client.

  Each operation has its own struct, all under the `Wick.Request` namespace. Pattern match
  on the struct name to dispatch:

      def handle(%Wick.Request.Read{} = req), do: ...
      def handle(%Wick.Request.Write{} = req), do: ...
      def handle(%Wick.Request.Execute{} = req), do: ...

  ## Operations covered

  | Struct                  | LwM2M § | Purpose |
  |-------------------------|:-------:|---------|
  | `Wick.Request.Read`     | 6.4.6   | Retrieve a Resource / Object Instance / Object value |
  | `Wick.Request.Write`    | 6.4.7   | Update Resource / Object Instance values             |
  | `Wick.Request.Execute`  | 6.4.8   | Invoke an Executable Resource                         |
  | `Wick.Request.Discover` | 6.4.9   | Enumerate Resources at a path (CoRE Link Format)      |
  | `Wick.Request.Create`   | 6.4.10  | Create a new Object Instance                          |
  | `Wick.Request.Delete`   | 6.4.11  | Delete an Object Instance                             |
  | `Wick.Request.WriteAttributes` | 6.4.12 | Set notification attributes (pmin / pmax / gt / lt / st) |
  | `Wick.Request.ReadComposite`     | 6.4.6.1  | Read multiple Resources / Object Instances in one exchange (1.1+) |
  | `Wick.Request.WriteComposite`    | 6.4.7.1  | Write multiple Resources in one exchange (1.1+)                  |
  | `Wick.Request.Observe`           | 6.4.6 / RFC 7641 | Establish an Observe relation on a path |
  | `Wick.Request.CancelObserve`     | 6.4.6 / RFC 7641 | Tear down an Observe relation           |
  | `Wick.Request.ObserveComposite`  | 6.4.6.1 | Establish a multi-path Observe relation (1.1+) |

  Client-initiated uplink operations (`Notify`, `Send`) live under `Wick.Uplink`. The
  registration interface (Register / Update / De-register) is its own protocol layer and
  lives in `Wick.Registration`; the Bootstrap interface lives in `Wick.Bootstrap`.

  ## Wire form

  `to_wire/1` turns any request into a `Wick.Wire` — the transport-agnostic spec a CoAP
  layer consumes. `from_wire/1` is the inverse, for the receiving side (a device, or a
  gateway inspecting traffic):

      iex> {:ok, path} = Wick.Path.parse("/3/0/9")
      iex> wire = Wick.Request.to_wire(%Wick.Request.Read{path: path})
      iex> {wire.method, wire.path}
      {:get, ["3", "0", "9"]}
      iex> {:ok, %Wick.Request.Read{}} = Wick.Request.from_wire(wire)

  ## Path

  Every request carries a `Wick.Path`. Path validity for an operation (e.g. Write to an
  Object root path is invalid; Execute requires a Resource path) is the gateway's
  responsibility — these structs are pure data with no semantic checks.

  ## Content-Format

  Where applicable, requests carry an `accept_content_format` (server tells the client
  which Content-Format the response should be in). For Write/Create, `content_format` is
  the format of the inbound payload. Both are CoAP Content-Format integers (see
  `Wick.Codec.SenmlCbor.content_format/0` and friends).

  ## Union type

  `t:t/0` is the union of every request struct — useful for typespecs at gateway
  boundaries.

      @spec dispatch(Wick.Request.t()) :: Wick.Response.t()
  """

  alias Wick.Attributes
  alias Wick.Codec
  alias Wick.Error
  alias Wick.Path
  alias Wick.Senml.Pack
  alias Wick.Wire

  @typedoc "Any LwM2M request struct."
  @type t ::
          __MODULE__.Read.t()
          | __MODULE__.Write.t()
          | __MODULE__.Execute.t()
          | __MODULE__.Discover.t()
          | __MODULE__.Create.t()
          | __MODULE__.Delete.t()
          | __MODULE__.WriteAttributes.t()
          | __MODULE__.ReadComposite.t()
          | __MODULE__.WriteComposite.t()
          | __MODULE__.Observe.t()
          | __MODULE__.CancelObserve.t()
          | __MODULE__.ObserveComposite.t()

  defmodule Read do
    @moduledoc """
    A Read request — retrieve the value at `path`.

    The server may indicate which Content-Format it would prefer in the response via
    `:accept_content_format` (CoAP Accept option). The client may honour or override.
    """

    @typedoc "A Read request."
    @type t :: %__MODULE__{
            path: Path.t(),
            accept_content_format: non_neg_integer() | nil
          }

    @enforce_keys [:path]
    defstruct [:path, :accept_content_format]
  end

  defmodule Write do
    @moduledoc """
    A Write request — update the value(s) at `path`.

    LwM2M defines two Write modes:

    * `:replace` — replace the entire Resource / Object Instance value (CoAP PUT)
    * `:partial_update` — merge into existing Resource Instances (CoAP POST)

    Default is `:replace`.
    """

    @typedoc "Write semantics: replace target, or merge into it."
    @type mode :: :replace | :partial_update

    @typedoc "A Write request."
    @type t :: %__MODULE__{
            path: Path.t(),
            content_format: non_neg_integer(),
            payload: binary(),
            mode: mode()
          }

    @enforce_keys [:path, :content_format, :payload]
    defstruct [:path, :content_format, :payload, mode: :replace]
  end

  defmodule Execute do
    @moduledoc """
    An Execute request — invoke an Executable Resource.

    Executable Resources optionally accept arguments per LwM2M 1.2 §6.4.8.1. The argument
    string is opaque to Wick at this layer; the consumer parses or constructs it.
    """

    @typedoc "An Execute request."
    @type t :: %__MODULE__{
            path: Path.t(),
            arguments: binary() | nil
          }

    @enforce_keys [:path]
    defstruct [:path, :arguments]
  end

  defmodule Discover do
    @moduledoc """
    A Discover request — enumerate Resources at `path`.

    The response is a CoRE Link Format string ([RFC 6690](https://www.rfc-editor.org/rfc/rfc6690))
    listing every Resource at the requested level along with its attributes.
    """

    @typedoc "A Discover request."
    @type t :: %__MODULE__{path: Path.t()}

    @enforce_keys [:path]
    defstruct [:path]
  end

  defmodule Create do
    @moduledoc """
    A Create request — create a new Object Instance under the Object at `path`.

    `path` must be an Object path (`/{object_id}`); the new Instance ID is either chosen
    by the server (if specified in the payload) or assigned by the client.
    """

    @typedoc "A Create request."
    @type t :: %__MODULE__{
            path: Path.t(),
            content_format: non_neg_integer(),
            payload: binary()
          }

    @enforce_keys [:path, :content_format, :payload]
    defstruct [:path, :content_format, :payload]
  end

  defmodule Delete do
    @moduledoc """
    A Delete request — delete the Object Instance at `path`.

    `path` must be an Object Instance path (`/{object_id}/{instance_id}`).
    """

    @typedoc "A Delete request."
    @type t :: %__MODULE__{path: Path.t()}

    @enforce_keys [:path]
    defstruct [:path]
  end

  defmodule WriteAttributes do
    @moduledoc """
    A Write-Attributes request — set or clear the notification attributes that govern when
    the client emits a Notification for `path` (LwM2M 1.2 §6.4.12).

    The CoAP wire form is a `PUT` carrying the attributes as Uri-Query parameters and
    **no payload**. That is what distinguishes it from `Wick.Request.Write`, which is
    also a `PUT` but always carries a body.

    Attributes are modelled by `Wick.Attributes`. Setting a field to `:clear` removes that
    attribute on the client (the bare `?pmin` query form).

    ## Examples

        iex> {:ok, p} = Wick.Path.parse("/3303/0/5700")
        iex> req = %Wick.Request.WriteAttributes{
        ...>   path: p,
        ...>   attributes: %Wick.Attributes{pmin: 10, pmax: 60}
        ...> }
        iex> Wick.Request.to_wire(req).query
        [{"pmin", 10}, {"pmax", 60}]
    """

    @typedoc "A Write-Attributes request."
    @type t :: %__MODULE__{
            path: Path.t(),
            attributes: Wick.Attributes.t()
          }

    @enforce_keys [:path, :attributes]
    defstruct [:path, :attributes]
  end

  defmodule ReadComposite do
    @moduledoc """
    A Read-Composite request — read multiple Resources, Object Instances, or Objects in
    one exchange (LwM2M 1.1+, §6.4.6.1).

    The wire form is a SenML payload listing the requested paths with **no value field**
    on each record. Wick stores the paths in their decoded form and `Wick.Request.to_wire/1`
    encodes them, using `:content_format` to pick the codec (`Wick.Senml.Pack.from_paths/1`
    builds the Pack, encoded with `:allow_no_value` set). `Wick.Request.from_wire/1`
    decodes the payload back into a path list.

    `:content_format` describes the **request body**; `:accept_content_format` asks for a
    format on the response. Only the SenML codecs can carry a Pack, so `:content_format`
    must be `110` or `112` — anything else raises from `to_wire/1`.

    The CoAP method for Read-Composite is **FETCH**; the URI is the LwM2M root.

    ## Examples

        iex> {:ok, p1} = Wick.Path.parse("/3/0/9")
        iex> {:ok, p2} = Wick.Path.parse("/3303/0/5700")
        iex> req = %Wick.Request.ReadComposite{paths: [p1, p2], accept_content_format: 112}
        iex> length(req.paths)
        2
        iex> req.content_format
        112
    """

    @typedoc "A Read-Composite request."
    @type t :: %__MODULE__{
            paths: [Path.t()],
            content_format: non_neg_integer(),
            accept_content_format: non_neg_integer() | nil
          }

    @enforce_keys [:paths]
    defstruct [:paths, :accept_content_format, content_format: 112]
  end

  defmodule WriteComposite do
    @moduledoc """
    A Write-Composite request — write multiple Resources in one exchange
    (LwM2M 1.1+, §6.4.7.1).

    The wire form is a SenML payload where each record carries a `name` (full path) and a
    value. Unlike `Wick.Request.Write`, there is no implicit base path on the URI — the
    paths are encoded into the payload.

    Wick mirrors the field shape of `Wick.Request.Write` here: `content_format` and
    `payload` carry the encoded SenML Pack. The gateway decodes via
    `Wick.Codec.SenmlCbor` / `Wick.Codec.SenmlJson` to produce a `Wick.Senml.Pack`, then
    iterates the records to apply each Write.

    The CoAP method for Write-Composite is **iPATCH**; the URI is the LwM2M root.

    Write-Composite is always **partial-update** semantics — there is no replace mode.
    Unlike `Wick.Request.Write`, no `:mode` field is exposed.

    ## Examples

        iex> req = %Wick.Request.WriteComposite{content_format: 112, payload: <<0x80>>}
        iex> req.content_format
        112
    """

    @typedoc "A Write-Composite request."
    @type t :: %__MODULE__{
            content_format: non_neg_integer(),
            payload: binary()
          }

    @enforce_keys [:content_format, :payload]
    defstruct [:content_format, :payload]
  end

  defmodule Observe do
    @moduledoc """
    An Observe request — establish an Observe relation on a path
    ([RFC 7641](https://www.rfc-editor.org/rfc/rfc7641), [LwM2M 1.2 §6.4.6](https://www.openmobilealliance.org/release/LightweightM2M/V1_2_1-20221209-A/OMA-TS-LightweightM2M_Core-V1_2_1-20221209-A.pdf)).

    The CoAP wire form is a GET with the **Observe** option set to 0 (register). The
    target sends an immediate Notify carrying the current value, then continues to send
    a Notify whenever the value changes (subject to any pmin/pmax/lt/gt attributes set
    via Write-Attributes).

    Set `:accept_content_format` if the server requires a specific Content-Format on
    notifications. Otherwise the target picks.

    Cancellation has its own dedicated struct, `Wick.Request.CancelObserve`, to keep the
    intent visible at pattern-match sites — even though wire-level CoAP encodes both as
    a GET with the Observe option = 0 / 1 respectively.

    ## Examples

        iex> {:ok, p} = Wick.Path.parse("/3303/0/5700")
        iex> req = %Wick.Request.Observe{path: p}
        iex> req.path == p
        true
    """

    @typedoc "An Observe request."
    @type t :: %__MODULE__{
            path: Path.t(),
            accept_content_format: non_neg_integer() | nil
          }

    @enforce_keys [:path]
    defstruct [:path, :accept_content_format]
  end

  defmodule CancelObserve do
    @moduledoc """
    A Cancel Observe request — tear down a previously established Observe relation
    on a path.

    Pairs with `Wick.Request.Observe`. After Cancel-Observe is sent and acknowledged, the
    target stops sending Notifications for the path.

    The CoAP wire form is a GET with the Observe option = 1 (deregister). Wick keeps it
    as its own struct rather than overloading `Observe` with a flag, because at the
    domain layer the two operations have different semantics: Observe is "begin listening";
    Cancel-Observe is "stop listening".
    """

    @typedoc "A Cancel-Observe request."
    @type t :: %__MODULE__{path: Path.t()}

    @enforce_keys [:path]
    defstruct [:path]
  end

  defmodule ObserveComposite do
    @moduledoc """
    An Observe-Composite request — establish a single Observe relation covering multiple
    paths in one exchange (LwM2M 1.1+, §6.4.6.1).

    The wire form is a FETCH with the Observe option set to 0; the request body is a
    SenML payload listing the paths to observe (no value field). The target sends a
    single Notify per cycle carrying every observed Resource, encoded as a multi-record
    SenML Pack.

    Wick stores the paths in their decoded form. `Wick.Senml.Pack.from_paths/1` builds the
    payload for the gateway when sending.

    Cancellation is handled by `Wick.Request.CancelObserve` against the same logical
    relation — but in the Composite case, all paths in the relation share the relation
    token, so the gateway tracks the binding rather than per-path state.

    As with `Wick.Request.ReadComposite`, `:content_format` describes the request body and
    must be a SenML format.

    ## Examples

        iex> {:ok, p1} = Wick.Path.parse("/3/0/9")
        iex> {:ok, p2} = Wick.Path.parse("/6/0/0")
        iex> req = %Wick.Request.ObserveComposite{paths: [p1, p2]}
        iex> length(req.paths)
        2
        iex> Wick.Request.to_wire(req).observe
        0
    """

    @typedoc "An Observe-Composite request."
    @type t :: %__MODULE__{
            paths: [Path.t()],
            content_format: non_neg_integer(),
            accept_content_format: non_neg_integer() | nil
          }

    @enforce_keys [:paths]
    defstruct [:paths, :accept_content_format, content_format: 112]
  end

  # ── Wire conversion ────────────────────────────────────────────────────────

  @link_format 40
  @text_plain 0

  @doc """
  Convert any request to its transport-agnostic `Wick.Wire` form.

  The method and option mapping follows LwM2M 1.2 §6.4:

  | Request              | Method   | URI          | Notes |
  |----------------------|----------|--------------|-------|
  | `Read`               | `GET`    | the path     | `Accept` when `:accept_content_format` is set |
  | `Write` (replace)    | `PUT`    | the path     | body + `Content-Format` |
  | `Write` (partial)    | `POST`   | the path     | body + `Content-Format` |
  | `Execute`            | `POST`   | the path     | arguments as a `text/plain` body |
  | `Discover`           | `GET`    | the path     | `Accept: 40` (`application/link-format`) |
  | `Create`             | `POST`   | the Object   | body + `Content-Format` |
  | `Delete`             | `DELETE` | the path     | — |
  | `WriteAttributes`    | `PUT`    | the path     | attributes as `Uri-Query`, no body |
  | `ReadComposite`      | `FETCH`  | root         | SenML path list as body |
  | `WriteComposite`     | `iPATCH` | root         | body + `Content-Format` |
  | `Observe`            | `GET`    | the path     | `Observe: 0` |
  | `CancelObserve`      | `GET`    | the path     | `Observe: 1` |
  | `ObserveComposite`   | `FETCH`  | root         | `Observe: 0` + SenML path list as body |

  Raises `ArgumentError` when a Composite request's `:content_format` is not a SenML
  format, since no other codec can carry a path list.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0/9")
      iex> Wick.Request.to_wire(%Wick.Request.Read{path: path})
      %Wick.Wire{method: :get, path: ["3", "0", "9"]}

      iex> {:ok, path} = Wick.Path.parse("/1/0/1")
      iex> wire = Wick.Request.to_wire(%Wick.Request.Write{
      ...>   path: path, content_format: 0, payload: "60", mode: :partial_update
      ...> })
      iex> {wire.method, wire.content_format, wire.payload}
      {:post, 0, "60"}

      iex> {:ok, path} = Wick.Path.parse("/3/0/4")
      iex> wire = Wick.Request.to_wire(%Wick.Request.Execute{path: path, arguments: "1='x'"})
      iex> {wire.method, wire.path, wire.payload, wire.content_format}
      {:post, ["3", "0", "4"], "1='x'", 0}

      iex> {:ok, path} = Wick.Path.parse("/3")
      iex> Wick.Request.to_wire(%Wick.Request.Discover{path: path}).accept
      40
  """
  @spec to_wire(t()) :: Wire.t()
  def to_wire(%__MODULE__.Read{} = req) do
    %Wire{method: :get, path: Path.to_segments(req.path), accept: req.accept_content_format}
  end

  def to_wire(%__MODULE__.Write{} = req) do
    %Wire{
      method: write_method(req.mode),
      path: Path.to_segments(req.path),
      payload: req.payload,
      content_format: req.content_format
    }
  end

  def to_wire(%__MODULE__.Execute{} = req) do
    # LwM2M §6.4.8: arguments travel as a text/plain body. An Execute with no arguments
    # sends no body and therefore no Content-Format.
    {payload, content_format} =
      case req.arguments do
        nil -> {"", nil}
        "" -> {"", nil}
        args -> {args, @text_plain}
      end

    %Wire{
      method: :post,
      path: Path.to_segments(req.path),
      payload: payload,
      content_format: content_format
    }
  end

  def to_wire(%__MODULE__.Discover{} = req) do
    %Wire{method: :get, path: Path.to_segments(req.path), accept: @link_format}
  end

  def to_wire(%__MODULE__.Create{} = req) do
    %Wire{
      method: :post,
      path: Path.to_segments(req.path),
      payload: req.payload,
      content_format: req.content_format
    }
  end

  def to_wire(%__MODULE__.Delete{} = req) do
    %Wire{method: :delete, path: Path.to_segments(req.path)}
  end

  def to_wire(%__MODULE__.WriteAttributes{} = req) do
    %Wire{
      method: :put,
      path: Path.to_segments(req.path),
      query: Attributes.to_query(req.attributes)
    }
  end

  def to_wire(%__MODULE__.ReadComposite{} = req) do
    %Wire{
      method: :fetch,
      payload: encode_paths(req.paths, req.content_format),
      content_format: req.content_format,
      accept: req.accept_content_format
    }
  end

  def to_wire(%__MODULE__.WriteComposite{} = req) do
    %Wire{method: :ipatch, payload: req.payload, content_format: req.content_format}
  end

  def to_wire(%__MODULE__.Observe{} = req) do
    %Wire{
      method: :get,
      path: Path.to_segments(req.path),
      accept: req.accept_content_format,
      observe: 0
    }
  end

  def to_wire(%__MODULE__.CancelObserve{} = req) do
    %Wire{method: :get, path: Path.to_segments(req.path), observe: 1}
  end

  def to_wire(%__MODULE__.ObserveComposite{} = req) do
    %Wire{
      method: :fetch,
      payload: encode_paths(req.paths, req.content_format),
      content_format: req.content_format,
      accept: req.accept_content_format,
      observe: 0
    }
  end

  @doc """
  Recover a request struct from a `Wick.Wire` — the receiving side of `to_wire/1`.

  Several LwM2M operations share a CoAP method, so the mapping back is not a simple table
  lookup. The disambiguation rules, which follow LwM2M 1.2 §6.4 and match Leshan's
  server-side dispatch:

  * **`GET`** — `Observe: 0` is an Observe, `Observe: 1` a Cancel-Observe. Otherwise
    `Accept: 40` (`application/link-format`) means Discover; anything else is a Read.
  * **`PUT`** — a `Content-Format` means there is a body, so it is a Write (replace).
    Without one it is Write-Attributes.
  * **`POST`** — the *path depth* decides, because each operation targets a different
    level: an Object path is a Create, an Object Instance path is a partial-update Write,
    and a Resource path is an Execute.
  * **`FETCH`** — `Observe: 0` is an Observe-Composite, otherwise a Read-Composite.
  * **`iPATCH`** — always a Write-Composite.
  * **`DELETE`** — always a Delete.

  Returns `{:error, %Wick.Error{}}` with code:

  * `:invalid_path` — the Uri-Path is not a valid LwM2M path. Note that this is what you
    get for `/rd` and `/bs` traffic: those belong to `Wick.Registration` and
    `Wick.Bootstrap`, not here.
  * `:unsupported_operation` — a method/path/option combination LwM2M does not define,
    e.g. a `POST` to a Resource Instance path.
  * `:malformed_senml` or a codec error — a Composite body that will not decode.

  ## Examples

      iex> {:ok, wire} = Wick.Wire.parse(:get, [{11, "3"}, {11, "0"}], "")
      iex> {:ok, %Wick.Request.Read{path: path}} = Wick.Request.from_wire(wire)
      iex> Wick.Path.format(path)
      "/3/0"

      iex> {:ok, wire} = Wick.Wire.parse(:get, [{11, "3"}, {17, <<40>>}], "")
      iex> {:ok, %Wick.Request.Discover{}} = Wick.Request.from_wire(wire)

      iex> {:ok, wire} = Wick.Wire.parse(:put, [{11, "1"}, {11, "0"}, {15, "pmin=10"}], "")
      iex> {:ok, req} = Wick.Request.from_wire(wire)
      iex> req.attributes.pmin
      10

      iex> {:ok, wire} = Wick.Wire.parse(:post, [{11, "3"}, {11, "0"}, {11, "4"}], "1")
      iex> {:ok, %Wick.Request.Execute{arguments: "1"}} = Wick.Request.from_wire(wire)

      iex> {:ok, wire} = Wick.Wire.parse(:get, [{11, "rd"}], "")
      iex> {:error, err} = Wick.Request.from_wire(wire)
      iex> err.code
      :invalid_path
  """
  @spec from_wire(Wire.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(%Wire{method: :get} = wire) do
    with {:ok, path} <- Path.from_segments(wire.path) do
      case {wire.observe, wire.accept} do
        {0, _accept} ->
          {:ok, %__MODULE__.Observe{path: path, accept_content_format: wire.accept}}

        {1, _accept} ->
          {:ok, %__MODULE__.CancelObserve{path: path}}

        {_observe, @link_format} ->
          {:ok, %__MODULE__.Discover{path: path}}

        _read ->
          {:ok, %__MODULE__.Read{path: path, accept_content_format: wire.accept}}
      end
    end
  end

  def from_wire(%Wire{method: :put} = wire) do
    with {:ok, path} <- Path.from_segments(wire.path) do
      case wire.content_format do
        nil ->
          with {:ok, attributes} <- Attributes.from_query(wire.query) do
            {:ok, %__MODULE__.WriteAttributes{path: path, attributes: attributes}}
          end

        content_format ->
          {:ok,
           %__MODULE__.Write{
             path: path,
             content_format: content_format,
             payload: wire.payload,
             mode: :replace
           }}
      end
    end
  end

  def from_wire(%Wire{method: :post} = wire) do
    with {:ok, path} <- Path.from_segments(wire.path) do
      post_by_depth(path, wire)
    end
  end

  def from_wire(%Wire{method: :delete} = wire) do
    with {:ok, path} <- Path.from_segments(wire.path) do
      {:ok, %__MODULE__.Delete{path: path}}
    end
  end

  def from_wire(%Wire{method: :fetch} = wire) do
    with {:ok, paths} <- decode_paths(wire.payload, wire.content_format) do
      case wire.observe do
        0 ->
          {:ok,
           %__MODULE__.ObserveComposite{
             paths: paths,
             content_format: wire.content_format,
             accept_content_format: wire.accept
           }}

        _not_observing ->
          {:ok,
           %__MODULE__.ReadComposite{
             paths: paths,
             content_format: wire.content_format,
             accept_content_format: wire.accept
           }}
      end
    end
  end

  def from_wire(%Wire{method: :ipatch} = wire) do
    case wire.content_format do
      nil ->
        {:error,
         Error.new(:unsupported_operation, "Write-Composite requires a Content-Format option")}

      content_format ->
        {:ok, %__MODULE__.WriteComposite{content_format: content_format, payload: wire.payload}}
    end
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp write_method(:replace), do: :put
  defp write_method(:partial_update), do: :post

  # POST is overloaded three ways in LwM2M; the target's depth is what distinguishes them.
  defp post_by_depth(%Path{object_instance_id: nil} = path, wire) do
    {:ok,
     %__MODULE__.Create{
       path: path,
       content_format: wire.content_format,
       payload: wire.payload
     }}
  end

  defp post_by_depth(%Path{resource_id: nil} = path, wire) do
    {:ok,
     %__MODULE__.Write{
       path: path,
       content_format: wire.content_format,
       payload: wire.payload,
       mode: :partial_update
     }}
  end

  defp post_by_depth(%Path{resource_instance_id: nil} = path, wire) do
    arguments = if wire.payload == "", do: nil, else: wire.payload
    {:ok, %__MODULE__.Execute{path: path, arguments: arguments}}
  end

  defp post_by_depth(%Path{} = path, _wire) do
    {:error,
     Error.new(
       :unsupported_operation,
       "LwM2M defines no POST operation on a Resource Instance path",
       path: Path.format(path)
     )}
  end

  defp encode_paths(paths, content_format) do
    case Codec.senml_codec(content_format) do
      {:ok, codec} -> encode_pack!(codec, Pack.from_paths(paths))
      :error -> raise ArgumentError, composite_format_message(content_format)
    end
  end

  defp encode_pack!(codec, pack) do
    case codec.encode(pack, allow_no_value: true) do
      {:ok, encoded} -> IO.iodata_to_binary(encoded)
      {:error, err} -> raise ArgumentError, "could not encode path list: #{err.message}"
    end
  end

  defp decode_paths(payload, content_format) do
    case Codec.senml_codec(content_format) do
      {:ok, codec} ->
        with {:ok, pack} <- codec.decode(payload, []), do: Pack.to_paths(pack)

      :error ->
        {:error,
         Error.new(:unsupported_operation, composite_format_message(content_format),
           content_format: content_format
         )}
    end
  end

  defp composite_format_message(content_format) do
    "Composite operations need a SenML Content-Format (110 or 112), got: " <>
      inspect(content_format)
  end
end

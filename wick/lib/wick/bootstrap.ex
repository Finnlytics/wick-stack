defmodule Wick.Bootstrap do
  @moduledoc """
  LwM2M Bootstrap Interface (OMA TS LwM2M Core 1.2, §6.1).

  Bootstrapping is how a device learns which LwM2M Server to talk to and with what
  credentials. A device ships knowing only a *Bootstrap* Server; it asks that server to
  provision Object 0 (Security) and Object 1 (Server), and only then registers normally.

  Six operations, and note that the traffic runs **both ways** — unlike the Registration
  interface (always client→server) or Device Management (always server→client):

  | Operation         | §     | Direction        | Method   | URI |
  |-------------------|:-----:|------------------|----------|-----|
  | `Request`         | 6.1.2 | client → server  | `POST`   | `/bs?ep=…` |
  | `Write`           | 6.1.3 | server → client  | `PUT`    | the path |
  | `Delete`          | 6.1.4 | server → client  | `DELETE` | the path, or `/` for everything |
  | `Discover`        | 6.1.5 | server → client  | `GET`    | the path, `Accept: 40` |
  | `Read`            | 6.1.7 | server → client  | `GET`    | the path |
  | `Finish`          | 6.1.6 | server → client  | `POST`   | `/bs` |

  ## `POST /bs` means two different things

  `Request` and `Finish` are both a `POST` to `/bs`. They are told apart by the `ep` query
  parameter, which only the client-initiated `Request` carries. `from_wire/1` implements
  that rule, so a client receiving `POST /bs` with no `ep` correctly reads it as "the server
  is done provisioning me".

  ## Bootstrap-Write is not Write

  `Wick.Bootstrap.Write` and `Wick.Request.Write` are the same bytes on the wire — a `PUT`
  with a body. They differ in what the receiver is permitted to do: a Bootstrap-Write may
  target the Security Object (which a normal Write may never touch) and may create Object
  Instances that do not yet exist. So a device must route by *session*, not by wire shape:
  use `Wick.Bootstrap.from_wire/1` while a bootstrap session is open and
  `Wick.Request.from_wire/1` otherwise. `Wick.Bootstrap.Session` is what tracks that.

  ## Examples

      iex> wire = Wick.Bootstrap.to_wire(%Wick.Bootstrap.Request{endpoint_name: "device-1"})
      iex> {wire.method, wire.path, wire.query}
      {:post, ["bs"], [{"ep", "device-1"}]}

      iex> wire = Wick.Bootstrap.to_wire(%Wick.Bootstrap.Finish{})
      iex> {wire.method, wire.path, wire.query}
      {:post, ["bs"], []}
  """

  alias Wick.Error
  alias Wick.Path
  alias Wick.Wire

  @bootstrap_path ["bs"]
  @link_format 40

  defmodule Request do
    @moduledoc """
    A Bootstrap-Request — the client asks a Bootstrap Server to provision it (§6.1.2).

    `endpoint_name` is the device's globally-unique identity, the same value it later uses
    for `ep` on Register.

    `preferred_content_format` (LwM2M 1.1+, the `pct` query) tells the server which
    Content-Format the client would rather receive Bootstrap-Writes in — a constrained
    device may only implement one codec.
    """

    @typedoc "A Bootstrap-Request."
    @type t :: %__MODULE__{
            endpoint_name: String.t(),
            preferred_content_format: non_neg_integer() | nil
          }

    @enforce_keys [:endpoint_name]
    defstruct [:endpoint_name, :preferred_content_format]
  end

  defmodule Finish do
    @moduledoc """
    A Bootstrap-Finish — the server signals that provisioning is complete (§6.1.6).

    On receiving it the client validates what it was given (does it now have a usable
    Security and Server Object pair?) and answers `2.04 Changed` if so, or
    `4.06 Not Acceptable` if the configuration is incomplete. Carries no payload and no
    parameters.
    """

    @typedoc "A Bootstrap-Finish."
    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule Write do
    @moduledoc """
    A Bootstrap-Write — provision the value(s) at `path` (§6.1.3).

    Unlike `Wick.Request.Write`, a Bootstrap-Write may target the Security Object (0) and
    may create Object Instances that do not exist yet. `path` may be an Object, an Object
    Instance, or a Resource.
    """

    @typedoc "A Bootstrap-Write."
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
    A Bootstrap-Delete — remove Object Instances (§6.1.4).

    `path` may be `nil`, which is the root form (`DELETE /`) meaning "delete every Instance
    of every Object I am allowed to delete". Servers use it to wipe stale provisioning
    before writing fresh configuration, and it is the reason a half-finished bootstrap can
    leave a device with nothing usable — hence Bootstrap-Finish's validation step.
    """

    @typedoc "A Bootstrap-Delete. A `nil` path is the root form."
    @type t :: %__MODULE__{path: Path.t() | nil}

    defstruct [:path]
  end

  defmodule Discover do
    @moduledoc """
    A Bootstrap-Discover — enumerate what the client currently has (§6.1.5).

    `path` may be `nil` for the root form, which reports every Object. The response is CoRE
    Link Format, where each Object Instance carries `ssid` (Short Server ID) and `uri`
    params so the server can see which Server Accounts already exist.
    """

    @typedoc "A Bootstrap-Discover. A `nil` path is the root form."
    @type t :: %__MODULE__{path: Path.t() | nil}

    defstruct [:path]
  end

  defmodule Read do
    @moduledoc """
    A Bootstrap-Read — read back provisioned values (§6.1.7, LwM2M 1.1+).

    Permitted only on the Server Object (1) and the Access Control Object (2); reading the
    Security Object (0) back is forbidden, since it holds credentials. Wick does not enforce
    that — it is the client's access-control decision — but a client should answer
    `4.05 Method Not Allowed` for anything else.
    """

    @typedoc "A Bootstrap-Read."
    @type t :: %__MODULE__{
            path: Path.t(),
            accept_content_format: non_neg_integer() | nil
          }

    @enforce_keys [:path]
    defstruct [:path, :accept_content_format]
  end

  @typedoc "Any Bootstrap operation."
  @type t ::
          Request.t()
          | Finish.t()
          | Write.t()
          | Delete.t()
          | Discover.t()
          | Read.t()

  @doc "The URI path the Bootstrap interface is rooted at: `/bs`."
  @spec bootstrap_path() :: [String.t()]
  def bootstrap_path, do: @bootstrap_path

  # ── Wire conversion ────────────────────────────────────────────────────────

  @doc """
  Convert a Bootstrap operation to its transport-agnostic `Wick.Wire` form.

  ## Examples

      iex> request = %Wick.Bootstrap.Request{endpoint_name: "d1", preferred_content_format: 112}
      iex> Wick.Bootstrap.to_wire(request).query
      [{"ep", "d1"}, {"pct", 112}]

      iex> {:ok, path} = Wick.Path.parse("/0/0")
      iex> wire = Wick.Bootstrap.to_wire(%Wick.Bootstrap.Write{
      ...>   path: path, content_format: 112, payload: <<0x80>>
      ...> })
      iex> {wire.method, wire.path}
      {:put, ["0", "0"]}

      iex> Wick.Bootstrap.to_wire(%Wick.Bootstrap.Delete{}).path
      []

      iex> Wick.Bootstrap.to_wire(%Wick.Bootstrap.Discover{}).accept
      40
  """
  @spec to_wire(t()) :: Wire.t()
  def to_wire(%Request{} = request) do
    query =
      case request.preferred_content_format do
        nil -> [{"ep", request.endpoint_name}]
        pct -> [{"ep", request.endpoint_name}, {"pct", pct}]
      end

    %Wire{method: :post, path: @bootstrap_path, query: query}
  end

  def to_wire(%Finish{}) do
    %Wire{method: :post, path: @bootstrap_path}
  end

  def to_wire(%Write{} = write) do
    %Wire{
      method: :put,
      path: Path.to_segments(write.path),
      payload: write.payload,
      content_format: write.content_format
    }
  end

  def to_wire(%Delete{} = delete) do
    %Wire{method: :delete, path: segments(delete.path)}
  end

  def to_wire(%Discover{} = discover) do
    %Wire{method: :get, path: segments(discover.path), accept: @link_format}
  end

  def to_wire(%Read{} = read) do
    %Wire{
      method: :get,
      path: Path.to_segments(read.path),
      accept: read.accept_content_format
    }
  end

  @doc """
  Recover a Bootstrap operation from a `Wick.Wire`.

  Call this instead of `Wick.Request.from_wire/1` while a bootstrap session is open — the
  two interfaces overlap on the wire and only the session tells them apart. See the module
  docs.

  Disambiguation:

  * **`POST /bs`** — with an `ep` query it is a client's `Request`; without, it is the
    server's `Finish`.
  * **`GET`** — `Accept: 40` (`application/link-format`) is a `Discover`, anything else a
    `Read`. Both accept the root path.
  * **`PUT`** — always a `Write`; a Content-Format is required, since a Bootstrap-Write
    without a body has no meaning.
  * **`DELETE`** — always a `Delete`, root path included.

  Returns `{:error, %Wick.Error{}}` with code `:unsupported_operation` for a method the
  interface does not define, `:missing_endpoint_name` for a `Request` with an empty `ep`,
  or `:invalid_path` for a malformed target.

  ## Examples

      iex> {:ok, wire} = Wick.Wire.parse(:post, [{11, "bs"}, {15, "ep=d1"}], "")
      iex> Wick.Bootstrap.from_wire(wire)
      {:ok, %Wick.Bootstrap.Request{endpoint_name: "d1", preferred_content_format: nil}}

      iex> {:ok, wire} = Wick.Wire.parse(:post, [{11, "bs"}], "")
      iex> Wick.Bootstrap.from_wire(wire)
      {:ok, %Wick.Bootstrap.Finish{}}

      iex> {:ok, wire} = Wick.Wire.parse(:delete, [], "")
      iex> Wick.Bootstrap.from_wire(wire)
      {:ok, %Wick.Bootstrap.Delete{path: nil}}
  """
  @spec from_wire(Wire.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(%Wire{method: :post, path: @bootstrap_path} = wire) do
    case Wire.fetch_query(wire.query, "ep") do
      :error -> {:ok, %Finish{}}
      {:ok, nil} -> {:error, missing_endpoint_name()}
      {:ok, ""} -> {:error, missing_endpoint_name()}
      {:ok, endpoint_name} -> build_request(endpoint_name, wire)
    end
  end

  def from_wire(%Wire{method: :post} = wire) do
    {:error,
     Error.new(
       :unsupported_operation,
       "the Bootstrap interface accepts POST only at /bs, got /#{Enum.join(wire.path, "/")}",
       path: wire.path
     )}
  end

  def from_wire(%Wire{method: :get, accept: @link_format} = wire) do
    with {:ok, path} <- optional_path(wire.path) do
      {:ok, %Discover{path: path}}
    end
  end

  def from_wire(%Wire{method: :get} = wire) do
    with {:ok, path} <- Path.from_segments(wire.path) do
      {:ok, %Read{path: path, accept_content_format: wire.accept}}
    end
  end

  def from_wire(%Wire{method: :put, content_format: nil}) do
    {:error,
     Error.new(:unsupported_operation, "a Bootstrap-Write requires a Content-Format option")}
  end

  def from_wire(%Wire{method: :put} = wire) do
    with {:ok, path} <- Path.from_segments(wire.path) do
      {:ok, %Write{path: path, content_format: wire.content_format, payload: wire.payload}}
    end
  end

  def from_wire(%Wire{method: :delete} = wire) do
    with {:ok, path} <- optional_path(wire.path) do
      {:ok, %Delete{path: path}}
    end
  end

  def from_wire(%Wire{method: method}) do
    {:error,
     Error.new(
       :unsupported_operation,
       "the Bootstrap interface defines no operation for #{inspect(method)}",
       method: method
     )}
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp build_request(endpoint_name, %Wire{} = wire) do
    case Wire.fetch_query(wire.query, "pct") do
      :error ->
        {:ok, %Request{endpoint_name: endpoint_name}}

      {:ok, raw} ->
        with {:ok, pct} <- parse_content_format(raw) do
          {:ok, %Request{endpoint_name: endpoint_name, preferred_content_format: pct}}
        end
    end
  end

  defp parse_content_format(value) when is_integer(value), do: {:ok, value}

  defp parse_content_format(value) when is_binary(value) do
    case Integer.parse(value) do
      {pct, ""} when pct >= 0 -> {:ok, pct}
      _malformed -> {:error, invalid_pct(value)}
    end
  end

  defp parse_content_format(value), do: {:error, invalid_pct(value)}

  defp invalid_pct(value) do
    Error.new(
      :invalid_content_format,
      "pct must be a non-negative Content-Format integer, got: #{inspect(value)}",
      value: value
    )
  end

  defp missing_endpoint_name do
    Error.new(:missing_endpoint_name, "a Bootstrap-Request must carry a non-empty ep parameter")
  end

  defp segments(nil), do: []
  defp segments(%Path{} = path), do: Path.to_segments(path)

  defp optional_path([]), do: {:ok, nil}
  defp optional_path(segments), do: Path.from_segments(segments)
end

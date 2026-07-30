defmodule Wick.Registration do
  @moduledoc """
  LwM2M Client Registration Interface (OMA TS LwM2M Core 1.2, §6.2).

  Three operations the client issues toward the server:

  | Operation   | Method   | Path                | Response on success |
  |-------------|----------|---------------------|---------------------|
  | Register    | `POST`   | `/rd`               | `2.01 Created` + `Location-Path: /rd/<id>` |
  | Update      | `POST`   | `/rd/<id>`          | `2.04 Changed`        |
  | Deregister  | `DELETE` | `/rd/<id>`          | `2.02 Deleted`        |

  This module is pure data: request structs you build, plus a helper that turns each
  struct into a transport-agnostic `%Wick.Wire{}` spec (method, path segments, query,
  payload, content-format). A CoAP-aware layer (typically `WickCoap.Endpoint`) is
  responsible for turning the `Wick.Wire` into an actual `%WickCoap.Message{}` —
  `Wick.Wire.to_coap_options/1` does the option mapping. Wick has no runtime dep on
  WickCoap by design — see ADR 0004.

  The server side lives in `Wick.Registration.Server`; an in-memory store lives in
  `Wick.Registration.Store`.

  ## Examples

      iex> register = %Wick.Registration.Register{
      ...>   endpoint_name: "device-1",
      ...>   lifetime: 86_400,
      ...>   binding: "U",
      ...>   objects: [%Wick.CoreLink.Link{target: "/3/0"}]
      ...> }
      iex> %Wick.Wire{} = Wick.Registration.to_wire(register)
      iex> wire = Wick.Registration.to_wire(register)
      iex> {wire.method, wire.path, wire.content_format}
      {:post, ["rd"], 40}
  """

  alias Wick.CoreLink
  alias Wick.Wire

  defmodule Register do
    @moduledoc """
    A LwM2M Register operation.

    `endpoint_name` and `objects` are required. The other fields are optional query
    parameters per LwM2M Core §6.2.1:

    * `lifetime` — registration lifetime in seconds (default 86 400).
    * `lwm2m_version` — protocol version string, defaults to `"1.2"`.
    * `binding` — current binding mode (`"U"`, `"T"`, `"S"`, `"N"`, or combinations).
    * `queue_mode` — when true, adds the `Q` flag.
    * `sms_number` — MSISDN, only meaningful with SMS binding.
    * `profile_id` — Server Account profile ID (LwM2M 1.1+).
    """

    @type t :: %__MODULE__{
            endpoint_name: String.t(),
            lifetime: pos_integer() | nil,
            lwm2m_version: String.t(),
            binding: String.t() | nil,
            queue_mode: boolean(),
            sms_number: String.t() | nil,
            profile_id: String.t() | nil,
            objects: [Wick.CoreLink.Link.t()]
          }

    @enforce_keys [:endpoint_name, :objects]
    defstruct [
      :endpoint_name,
      :sms_number,
      :profile_id,
      :binding,
      lifetime: nil,
      lwm2m_version: "1.2",
      queue_mode: false,
      objects: []
    ]
  end

  defmodule Update do
    @moduledoc """
    A LwM2M Update operation.

    `location` is the server-assigned ID returned from the original Register response
    (the last segment of `Location-Path`). All other fields are optional — only
    non-nil fields go on the wire as query parameters; an empty `objects` list omits
    the payload entirely.
    """

    @type t :: %__MODULE__{
            location: String.t(),
            lifetime: pos_integer() | nil,
            binding: String.t() | nil,
            sms_number: String.t() | nil,
            objects: [Wick.CoreLink.Link.t()]
          }

    @enforce_keys [:location]
    defstruct [:location, :lifetime, :binding, :sms_number, objects: []]
  end

  defmodule Deregister do
    @moduledoc "A LwM2M Deregister operation. `location` is the registration ID."

    @type t :: %__MODULE__{location: String.t()}
    @enforce_keys [:location]
    defstruct [:location]
  end

  @type request :: Register.t() | Update.t() | Deregister.t()

  # ── Wire conversion ────────────────────────────────────────────────────────

  @doc "Convert a registration operation to its transport-agnostic wire form."
  @spec to_wire(request()) :: Wire.t()
  def to_wire(%Register{} = r) do
    payload = CoreLink.encode(r.objects)

    %Wire{
      method: :post,
      path: ["rd"],
      query: register_query(r),
      payload: payload,
      content_format: CoreLink.content_format()
    }
  end

  def to_wire(%Update{} = u) do
    payload =
      case u.objects do
        [] -> ""
        links -> CoreLink.encode(links)
      end

    %Wire{
      method: :post,
      path: ["rd", u.location],
      query: update_query(u),
      payload: payload,
      content_format: if(payload == "", do: nil, else: CoreLink.content_format())
    }
  end

  def to_wire(%Deregister{location: location}) do
    %Wire{method: :delete, path: ["rd", location]}
  end

  defp register_query(%Register{} = r) do
    [
      {"ep", r.endpoint_name},
      {"lwm2m", r.lwm2m_version}
    ]
    |> maybe_add("lt", r.lifetime)
    |> maybe_add("b", r.binding)
    |> maybe_flag("Q", r.queue_mode)
    |> maybe_add("sms", r.sms_number)
    |> maybe_add("pid", r.profile_id)
  end

  defp update_query(%Update{} = u) do
    []
    |> maybe_add("lt", u.lifetime)
    |> maybe_add("b", u.binding)
    |> maybe_add("sms", u.sms_number)
  end

  defp maybe_add(query, _key, nil), do: query
  defp maybe_add(query, key, value), do: query ++ [{key, value}]

  defp maybe_flag(query, _key, false), do: query
  defp maybe_flag(query, key, true), do: query ++ [{key, nil}]
end

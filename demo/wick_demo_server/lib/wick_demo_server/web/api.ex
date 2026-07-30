defmodule WickDemoServer.Web.Api do
  @moduledoc """
  JSON serialisation for the web UI.

  Kept apart from the router so the shape of the API is readable in one place, and so the
  router stays about routing.

  ## Values on the wire

  Wick stores Resource values as `{type, value}` tuples — `{:float, 22.5}`, `{:opaque, bytes}`
  — because SenML cannot distinguish an Integer from a Float or a String from an Opaque. JSON
  has the same weakness, so the type tag travels explicitly:

      {"type": "float", "value": 22.5}

  Opaque values are Base64-encoded, since raw bytes are not valid JSON strings. Objlnk becomes
  `"1:0"`, matching its SenML form. `parse_value/1` is the inverse and is what the UI's write
  form posts back.
  """

  alias Wick.Attributes
  alias Wick.CoreLink
  alias Wick.Object.Tree
  alias Wick.Observation
  alias Wick.Path
  # `Record` alone would be ambiguous here: this module handles both a registration Record and a
  # SenML Record.
  alias Wick.Registration.Record
  alias Wick.Response
  alias Wick.Senml.Pack
  alias Wick.Senml.Record, as: SenmlRecord

  # ── Registrations ──────────────────────────────────────────────────────────

  @doc "Serialise a registration for the client list."
  @spec registration(Record.t()) :: map()
  def registration(%Record{} = record) do
    %{
      registration_id: record.location_id,
      endpoint_name: record.endpoint_name,
      lifetime: record.lifetime,
      lwm2m_version: record.lwm2m_version,
      binding: record.binding,
      queue_mode: record.queue_mode,
      peer: format_peer(record.peer),
      objects: Enum.map(record.objects, &link/1),
      created_at: record.created_at,
      updated_at: record.updated_at,
      # Seconds until the registration is reaped if no Update arrives. Negative means overdue;
      # the reaper sweeps on an interval rather than instantly.
      expires_in: expires_in(record)
    }
  end

  @doc """
  The Object tree a registration advertised, as a nestable structure for the UI's browser.

  Built from the CoRE Links in the registration payload, which is all the server knows before
  it Reads anything: LwM2M tells a server *which Object Instances exist*, not what is in them.
  So the UI shows the Instance list immediately and fills in Resources as Reads return.
  """
  @spec advertised_tree(Record.t()) :: [map()]
  def advertised_tree(%Record{} = record) do
    record.objects
    |> Enum.map(& &1.target)
    |> Enum.map(&Path.parse/1)
    |> Enum.flat_map(fn
      {:ok, path} -> [path]
      {:error, _not_a_path} -> []
    end)
    |> Enum.group_by(& &1.object_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {object_id, paths} ->
      %{
        object_id: object_id,
        name: object_name(object_id),
        instances:
          paths
          |> Enum.map(& &1.object_instance_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()
          |> Enum.map(&%{instance_id: &1, path: "/#{object_id}/#{&1}"})
      }
    end)
  end

  # ── Responses ──────────────────────────────────────────────────────────────

  @doc """
  Serialise an operation's outcome.

  The payload is decoded where possible: a SenML body becomes `readings`, a link-format body
  becomes `links`, and anything else is passed through as text. The UI renders whichever is
  present, so a Read and a Discover both come back usable without the UI having to know which
  Content-Format implies which shape.
  """
  @spec response(Response.t()) :: map()
  def response(%Response{} = response) do
    base = %{
      status: response.status,
      coap_code: coap_code(response.status),
      success: Response.success?(response),
      content_format: response.content_format
    }

    base
    |> put_unless_nil(
      :location_path,
      response.location_path && Path.format(response.location_path)
    )
    |> Map.merge(decode_payload(response))
  end

  defp decode_payload(%Response{payload: nil}), do: %{}
  defp decode_payload(%Response{payload: ""}), do: %{}

  defp decode_payload(%Response{content_format: 40, payload: payload}) do
    case CoreLink.decode(payload) do
      {:ok, links} -> %{links: Enum.map(links, &link/1)}
      {:error, _malformed} -> %{text: payload}
    end
  end

  defp decode_payload(%Response{} = response) do
    case Wick.Codec.senml_codec(response.content_format) do
      {:ok, codec} -> senml_payload(codec, response.payload)
      :error -> %{text: printable(response.payload)}
    end
  end

  defp senml_payload(codec, payload) do
    case codec.decode(payload, []) do
      {:ok, pack} ->
        %{
          readings:
            Enum.map(Pack.resolve(pack), fn {name, time, record} ->
              %{path: name, time: time, value: senml_value(record)}
            end)
        }

      {:error, error} ->
        %{error: error.message}
    end
  end

  defp senml_value(record) do
    case SenmlRecord.value_type(record) do
      :opaque -> %{type: "opaque", value: Base.encode64(record.opaque_value)}
      :none -> %{type: "none", value: nil}
      type -> %{type: Atom.to_string(type), value: SenmlRecord.value(record)}
    end
  end

  # ── Values ─────────────────────────────────────────────────────────────────

  @doc """
  Serialise a `{type, value}` tuple. Opaque is Base64; Objlnk uses its SenML `"oid:iid"` form.

  ## Examples

      iex> WickDemoServer.Web.Api.value({:float, 22.5})
      %{type: "float", value: 22.5}

      iex> WickDemoServer.Web.Api.value({:opaque, <<0xDE, 0xAD>>})
      %{type: "opaque", value: "3q0="}

      iex> WickDemoServer.Web.Api.value({:objlnk, {1, 0}})
      %{type: "objlnk", value: "1:0"}
  """
  @spec value(Tree.value()) :: map()
  def value({:opaque, bytes}), do: %{type: "opaque", value: Base.encode64(bytes)}

  def value({:objlnk, {object_id, instance_id}}),
    do: %{type: "objlnk", value: "#{object_id}:#{instance_id}"}

  def value({type, raw}), do: %{type: Atom.to_string(type), value: raw}

  @doc """
  Parse the `{"type": ..., "value": ...}` form the UI posts back into a `{type, value}` tuple.

  Returns `{:error, message}` rather than raising: this is untrusted input from a browser form,
  and a bad value should come back as a `400` the UI can display, not a crash.

  ## Examples

      iex> WickDemoServer.Web.Api.parse_value(%{"type" => "float", "value" => 22.5})
      {:ok, {:float, 22.5}}

      iex> WickDemoServer.Web.Api.parse_value(%{"type" => "integer", "value" => "42"})
      {:ok, {:integer, 42}}

      iex> WickDemoServer.Web.Api.parse_value(%{"type" => "float", "value" => "warm"})
      {:error, "value \\"warm\\" is not a float"}
  """
  @spec parse_value(map()) :: {:ok, Tree.value()} | {:error, String.t()}
  def parse_value(%{"type" => type, "value" => raw}), do: cast(type, raw)

  def parse_value(_other),
    do: {:error, ~s|expected an object with "type" and "value" keys|}

  defp cast("string", raw) when is_binary(raw), do: {:ok, {:string, raw}}
  defp cast("core_link", raw) when is_binary(raw), do: {:ok, {:core_link, raw}}
  defp cast("boolean", raw) when is_boolean(raw), do: {:ok, {:boolean, raw}}
  defp cast("boolean", "true"), do: {:ok, {:boolean, true}}
  defp cast("boolean", "false"), do: {:ok, {:boolean, false}}
  defp cast("integer", raw) when is_integer(raw), do: {:ok, {:integer, raw}}
  defp cast("unsigned_integer", raw) when is_integer(raw), do: {:ok, {:unsigned_integer, raw}}
  defp cast("time", raw) when is_integer(raw), do: {:ok, {:time, raw}}
  defp cast("float", raw) when is_float(raw), do: {:ok, {:float, raw}}
  defp cast("float", raw) when is_integer(raw), do: {:ok, {:float, raw * 1.0}}

  defp cast(type, raw) when type in ["integer", "unsigned_integer", "time"] and is_binary(raw) do
    case Integer.parse(raw) do
      {parsed, ""} -> {:ok, {String.to_existing_atom(type), parsed}}
      _malformed -> {:error, ~s|value #{inspect(raw)} is not an integer|}
    end
  end

  defp cast("float", raw) when is_binary(raw) do
    case Float.parse(raw) do
      {parsed, ""} -> {:ok, {:float, parsed}}
      _malformed -> {:error, ~s|value #{inspect(raw)} is not a float|}
    end
  end

  defp cast("opaque", raw) when is_binary(raw) do
    case Base.decode64(raw) do
      {:ok, bytes} -> {:ok, {:opaque, bytes}}
      :error -> {:error, "opaque values must be Base64"}
    end
  end

  defp cast("objlnk", raw) when is_binary(raw) do
    case String.split(raw, ":", parts: 2) do
      [object_id, instance_id] -> parse_objlnk(object_id, instance_id, raw)
      _malformed -> {:error, ~s|objlnk must look like "1:0"|}
    end
  end

  defp cast(type, _raw), do: {:error, "unsupported value type #{inspect(type)}"}

  defp parse_objlnk(object_id, instance_id, raw) do
    with {oid, ""} <- Integer.parse(object_id),
         {iid, ""} <- Integer.parse(instance_id) do
      {:ok, {:objlnk, {oid, iid}}}
    else
      _malformed -> {:error, ~s|objlnk must look like "1:0", got #{inspect(raw)}|}
    end
  end

  # ── Attributes ─────────────────────────────────────────────────────────────

  @doc """
  Parse the attribute form the UI posts. Absent keys stay `nil` (leave alone); an explicit
  `null` becomes `:clear` (remove on the device), which is the distinction the whole `:clear`
  mechanism exists for.

  ## Examples

      iex> {:ok, attrs} = WickDemoServer.Web.Api.parse_attributes(%{"pmin" => 10, "pmax" => nil})
      iex> {attrs.pmin, attrs.pmax, attrs.st}
      {10, :clear, nil}
  """
  @spec parse_attributes(map()) :: {:ok, Attributes.t()} | {:error, String.t()}
  def parse_attributes(params) when is_map(params) do
    Enum.reduce_while(Attributes.notification_fields(), {:ok, %Attributes{}}, fn field,
                                                                                 {:ok, acc} ->
      key = Atom.to_string(field)

      case Map.fetch(params, key) do
        :error -> {:cont, {:ok, acc}}
        {:ok, nil} -> {:cont, {:ok, Map.put(acc, field, :clear)}}
        {:ok, raw} -> cast_attribute(acc, field, key, raw)
      end
    end)
  end

  defp cast_attribute(acc, field, key, raw) do
    case Attributes.from_query([{key, raw}]) do
      {:ok, parsed} -> {:cont, {:ok, Map.put(acc, field, Map.fetch!(parsed, field))}}
      {:error, error} -> {:halt, {:error, error.message}}
    end
  end

  @doc "Serialise an attribute set, mapping `:clear` to `null`."
  @spec attributes(Attributes.t()) :: map()
  def attributes(%Attributes{} = attrs) do
    for field <- Attributes.notification_fields() ++ Attributes.property_fields(),
        value = Map.fetch!(attrs, field),
        into: %{} do
      {field, if(value == :clear, do: nil, else: value)}
    end
  end

  # ── Observations ───────────────────────────────────────────────────────────

  @doc "Serialise an Observe relation, with its handle rendered as an opaque string key."
  @spec observation(term(), Observation.t()) :: map()
  def observation(handle, %Observation{} = observation) do
    %{
      handle: handle_key(handle),
      registration_id: observation.registration_id,
      paths: Enum.map(observation.paths, &Path.format/1),
      composite: Observation.composite?(observation),
      content_format: observation.content_format,
      last_seq: observation.last_seq,
      last_value: observation.last_value,
      notified_at: observation.notified_at,
      created_at: observation.created_at
    }
  end

  @doc """
  A stable string key for an opaque observe handle, so a browser can refer to a relation it
  cannot itself represent.

  `WickCoap.Endpoint` handles are `{peer, token}` tuples — not JSON-representable, and not
  something the UI should depend on the shape of. The key is derived rather than stored, so it
  survives a page reload.
  """
  @spec handle_key(term()) :: String.t()
  def handle_key(handle), do: handle |> :erlang.phash2() |> Integer.to_string(16)

  # ── Events ─────────────────────────────────────────────────────────────────

  @doc "Serialise a bus event for the SSE stream, rendering values the UI can read."
  @spec event(map()) :: map()
  def event(event) when is_map(event) do
    event
    |> Map.new(fn
      {:peer, peer} -> {:peer, format_peer(peer)}
      {:paths, paths} -> {:paths, Enum.map(paths, &path_string/1)}
      {:objects, links} -> {:objects, Enum.map(links, &link/1)}
      {:readings, readings} -> {:readings, Enum.map(readings, &reading/1)}
      {key, value} -> {key, value}
    end)
  end

  defp reading({path, value}), do: %{path: path, value: value}

  defp path_string(%Path{} = path), do: Path.format(path)
  defp path_string(other) when is_binary(other), do: other

  # ── Shared ─────────────────────────────────────────────────────────────────

  defp link(%CoreLink.Link{} = link), do: %{target: link.target, params: link.params}

  defp coap_code(status) do
    {class, detail} = Wick.Status.to_coap(status)
    "#{class}.#{String.pad_leading(Integer.to_string(detail), 2, "0")}"
  end

  defp expires_in(%Record{} = record) do
    elapsed = System.monotonic_time(:millisecond) - record.updated_at
    div(record.lifetime * 1_000 - elapsed, 1_000)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  # Payloads that are not valid UTF-8 (Opaque, TLV) would break JSON encoding, so fall back to
  # hex rather than failing the whole response.
  defp printable(payload) do
    if String.valid?(payload), do: payload, else: "0x" <> Base.encode16(payload, case: :lower)
  end

  defp format_peer(nil), do: nil
  defp format_peer({{a, b, c, d}, port}), do: "#{a}.#{b}.#{c}.#{d}:#{port}"
  defp format_peer({ip, port}), do: "#{inspect(ip)}:#{port}"
  defp format_peer(other), do: inspect(other)

  # A friendly name for the Objects the demo is likely to meet. Anything else shows as its ID,
  # which is honest — the server has no DDF for unknown Objects.
  @object_names %{
    0 => "Security",
    1 => "Server",
    2 => "Access Control",
    3 => "Device",
    4 => "Connectivity Monitoring",
    5 => "Firmware Update",
    6 => "Location",
    7 => "Connectivity Statistics",
    3303 => "Temperature",
    3304 => "Humidity",
    3311 => "Light Control",
    3323 => "Pressure",
    3342 => "On/Off Switch"
  }

  @doc "A human-readable name for a known Object ID, or `nil`."
  @spec object_name(non_neg_integer()) :: String.t() | nil
  def object_name(object_id), do: Map.get(@object_names, object_id)
end

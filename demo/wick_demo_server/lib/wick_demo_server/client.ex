defmodule WickDemoServer.Client do
  @moduledoc """
  Issue Device Management and Information Reporting operations against a registered client.

  This is the half of an LwM2M server that talks *outwards*. Every function takes a
  `location_id` — the registration handle the server minted on Register — looks up the
  device's peer address from `WickDemoServer.Store`, and sends over the same UDP flow the
  device registered on.

  ## Why the registration is the only route to a device

  A device is typically behind NAT or a carrier gateway, so there is no address the server can
  dial. The only reachable address is the source of the device's own Register, which is why
  `Wick.Registration.Record` carries `peer` and why every request here is keyed by
  registration rather than by address. It is also why a registration expiring makes a device
  unreachable rather than merely stale.

  ## Paths

  Every function accepts a path as a string (`"/3303/0/5700"`) and parses it, because that is
  what is comfortable from IEx. Pass a `Wick.Path` if you already have one.

  ## Examples

      iex> [reg] = WickDemoServer.registrations()
      iex> WickDemoServer.Client.read(reg.location_id, "/3/0/0")
      {:ok, %Wick.Response{status: :content}}

      iex> WickDemoServer.Client.observe(reg.location_id, "/3303/0/5700")
      {:ok, handle}

      iex> WickDemoServer.Client.write_attributes(reg.location_id, "/3303/0/5700",
      ...>   %Wick.Attributes{pmin: 5, st: 1})
      {:ok, %Wick.Response{status: :changed}}
  """

  require Logger

  alias Wick.Attributes
  alias Wick.Codec.SenmlCbor
  alias Wick.Object.Tree
  alias Wick.Observation
  alias Wick.Path
  alias Wick.Request
  alias Wick.Response
  alias Wick.Senml.Pack
  alias Wick.Senml.Record
  alias WickDemoServer.Coap
  alias WickDemoServer.Endpoint
  alias WickDemoServer.Events
  alias WickDemoServer.Observations
  alias WickDemoServer.Store

  @senml_cbor 112

  @typedoc "A path, as a string for IEx convenience or an already-parsed `Wick.Path`."
  @type pathish :: String.t() | Path.t()

  @typedoc "The outcome of an operation against a device."
  @type result :: {:ok, Response.t()} | {:error, term()}

  # ── Device Management ──────────────────────────────────────────────────────

  @doc """
  Read a path. Pass `accept: 0` to ask for `text/plain` instead of SenML — handy for reading
  a single Resource in a form you can eyeball.
  """
  @spec read(String.t(), pathish(), keyword()) :: result()
  def read(location_id, path, opts \\ []) do
    with {:ok, path} <- parse(path) do
      send_request(
        location_id,
        %Request.Read{path: path, accept_content_format: Keyword.get(opts, :accept)},
        opts
      )
    end
  end

  @doc """
  Write a value. `value` is a `{type, value}` tuple using `Wick.Value`'s tags, e.g.
  `{:float, 22.5}` or `{:string, "+02:00"}`.

  Defaults to replace semantics (`PUT`). Pass `mode: :partial_update` for a merge into an
  Object Instance (`POST`).
  """
  @spec write(String.t(), pathish(), Tree.value(), keyword()) :: result()
  def write(location_id, path, value, opts \\ []) do
    with {:ok, path} <- parse(path),
         {:ok, payload} <- encode_value(path, value) do
      send_request(
        location_id,
        %Request.Write{
          path: path,
          content_format: @senml_cbor,
          payload: payload,
          mode: Keyword.get(opts, :mode, :replace)
        },
        opts
      )
    end
  end

  @doc "Invoke an Executable Resource, with optional argument string (§6.4.8.1)."
  @spec execute(String.t(), pathish(), String.t() | nil, keyword()) :: result()
  def execute(location_id, path, arguments \\ nil, opts \\ []) do
    with {:ok, path} <- parse(path) do
      send_request(location_id, %Request.Execute{path: path, arguments: arguments}, opts)
    end
  end

  @doc "Enumerate the Resources at a path, with the attributes in force at each level."
  @spec discover(String.t(), pathish(), keyword()) :: result()
  def discover(location_id, path, opts \\ []) do
    with {:ok, path} <- parse(path) do
      send_request(location_id, %Request.Discover{path: path}, opts)
    end
  end

  @doc """
  Create a new Object Instance under an Object path. `resources` is a map of
  `resource_id => {type, value}`.
  """
  @spec create(String.t(), pathish(), %{optional(non_neg_integer()) => Tree.value()}, keyword()) ::
          result()
  def create(location_id, path, resources, opts \\ []) do
    with {:ok, path} <- parse(path),
         {:ok, payload} <- encode_resources(resources) do
      send_request(
        location_id,
        %Request.Create{path: path, content_format: @senml_cbor, payload: payload},
        opts
      )
    end
  end

  @doc "Delete an Object Instance."
  @spec delete(String.t(), pathish(), keyword()) :: result()
  def delete(location_id, path, opts \\ []) do
    with {:ok, path} <- parse(path) do
      send_request(location_id, %Request.Delete{path: path}, opts)
    end
  end

  @doc """
  Set the notification attributes that govern when the device notifies (§6.4.12).

  Set a field to `:clear` to remove it. The attributes are remembered against any observation
  on the same path, so the server can later check whether the device is honouring them.
  """
  @spec write_attributes(String.t(), pathish(), Attributes.t(), keyword()) :: result()
  def write_attributes(location_id, path, %Attributes{} = attributes, opts \\ []) do
    with {:ok, path} <- parse(path) do
      send_request(
        location_id,
        %Request.WriteAttributes{path: path, attributes: attributes},
        opts
      )
    end
  end

  @doc "Read several paths in one exchange (§6.4.6.1)."
  @spec read_composite(String.t(), [pathish()], keyword()) :: result()
  def read_composite(location_id, paths, opts \\ []) do
    with {:ok, parsed} <- parse_all(paths) do
      send_request(
        location_id,
        %Request.ReadComposite{paths: parsed, accept_content_format: @senml_cbor},
        opts
      )
    end
  end

  @doc """
  Write several paths in one exchange (§6.4.7.1). `values` is a map of
  `path_string => {type, value}`.
  """
  @spec write_composite(String.t(), %{optional(String.t()) => Tree.value()}, keyword()) ::
          result()
  def write_composite(location_id, values, opts \\ []) do
    with {:ok, payload} <- encode_absolute(values) do
      send_request(
        location_id,
        %Request.WriteComposite{content_format: @senml_cbor, payload: payload},
        opts
      )
    end
  end

  # ── Information Reporting ──────────────────────────────────────────────────

  @doc """
  Observe a path. On success the relation is recorded in `WickDemoServer.Observations`, which
  is what makes the resulting Notifications interpretable.

  Returns `{:ok, handle}`; pass the handle to `cancel_observe/3`.
  """
  @spec observe(String.t(), pathish(), keyword()) :: {:ok, term()} | {:error, term()}
  def observe(location_id, path, opts \\ []) do
    with {:ok, path} <- parse(path),
         {:ok, peer} <- peer_for(location_id) do
      request = %Request.Observe{path: path, accept_content_format: @senml_cbor}

      case Coap.observe(endpoint(opts), peer, Request.to_wire(request),
             notify: Observations.notify_pid(observations(opts)),
             timeout: timeout(opts)
           ) do
        {:ok, handle, %Response{status: :content} = response, observe_seq} ->
          register_relation(location_id, [path], handle, observe_seq, response, opts)
          {:ok, handle}

        {:ok, _handle, response, _seq} ->
          Logger.warning("OBSERVE #{Path.format(path)} refused: #{response.status}")
          {:error, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Observe several paths under a single relation (§6.4.6.1)."
  @spec observe_composite(String.t(), [pathish()], keyword()) :: {:ok, term()} | {:error, term()}
  def observe_composite(location_id, paths, opts \\ []) do
    with {:ok, parsed} <- parse_all(paths),
         {:ok, peer} <- peer_for(location_id) do
      request = %Request.ObserveComposite{paths: parsed, accept_content_format: @senml_cbor}

      case Coap.observe(endpoint(opts), peer, Request.to_wire(request),
             notify: Observations.notify_pid(observations(opts)),
             timeout: timeout(opts)
           ) do
        {:ok, handle, %Response{status: :content} = response, observe_seq} ->
          register_relation(location_id, parsed, handle, observe_seq, response, opts)
          {:ok, handle}

        {:ok, _handle, response, _seq} ->
          {:error, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Cancel an observation: send Cancel-Observe to the device, tear down the local CoAP
  subscription, and forget the relation.
  """
  @spec cancel_observe(String.t(), pathish(), term(), keyword()) :: result()
  def cancel_observe(location_id, path, handle, opts \\ []) do
    with {:ok, path} <- parse(path) do
      result = send_request(location_id, %Request.CancelObserve{path: path}, opts)

      # Tear the local state down regardless of what the device said: if it did not answer,
      # continuing to hold the relation would only produce notifications we cannot correlate.
      _ = WickCoap.Endpoint.cancel_observation(endpoint(opts), handle)
      :ok = Observations.forget(observations(opts), handle)

      result
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  defp register_relation(location_id, paths, handle, observe_seq, response, opts) do
    observation =
      Observation.new(location_id, paths,
        token: nil,
        content_format: response.content_format,
        attributes: Keyword.get(opts, :attributes, %Attributes{})
      )

    # Seed the sequence number from the Observe response so the first real Notification is
    # compared against it rather than against "nothing seen yet".
    observation =
      case observe_seq do
        nil -> observation
        seq -> %{observation | last_seq: seq}
      end

    Observations.put(observations(opts), handle, observation)
  end

  defp send_request(location_id, request, opts) do
    with {:ok, peer} <- peer_for(location_id) do
      wire = Request.to_wire(request)

      case Coap.request(endpoint(opts), peer, wire, timeout: timeout(opts)) do
        {:ok, response} ->
          Logger.info("#{label(request)} id=#{location_id} → #{response.status}")
          publish_request(location_id, request, response.status)
          {:ok, response}

        {:error, reason} ->
          Logger.warning(
            "#{label(request)} id=#{location_id} transport error: #{inspect(reason)}"
          )

          publish_request(location_id, request, :timeout)
          {:error, reason}
      end
    end
  end

  # Outbound operations are published too, so the UI's event log shows both directions rather
  # than only what devices sent us.
  defp publish_request(location_id, request, status) do
    Events.publish(:request,
      registration_id: location_id,
      operation: label(request),
      path: request_path(request),
      status: status
    )
  end

  defp request_path(%{path: %Path{} = path}), do: Path.format(path)
  defp request_path(%{paths: paths}), do: Enum.map_join(paths, ", ", &Path.format/1)
  defp request_path(_request), do: "/"

  defp peer_for(location_id) do
    case Enum.find(Store.list(), &(&1.location_id == location_id)) do
      nil -> {:error, :unknown_registration}
      %{peer: nil} -> {:error, :no_peer_address}
      %{peer: peer} -> {:ok, peer}
    end
  end

  defp parse(%Path{} = path), do: {:ok, path}
  defp parse(path) when is_binary(path), do: Path.parse(path)

  defp parse_all(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case parse(path) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # Names in a Write body are relative to the request URI. A Write targeting a single Resource
  # therefore carries an *empty* name — the URI already says which Resource (RFC 8428 §4.5.1).
  # A Write targeting an Object Instance names the Resource within it.
  defp encode_value(%Path{resource_id: nil}, _value) do
    {:error,
     Wick.Error.new(
       :invalid_path,
       "write/4 targets a Resource; use write_composite/3 for several at once"
     )}
  end

  defp encode_value(%Path{} = _path, value), do: encode_pack([{"", value}])

  defp encode_resources(resources) do
    resources
    |> Enum.sort()
    |> Enum.map(fn {resource_id, value} -> {Integer.to_string(resource_id), value} end)
    |> encode_pack()
  end

  defp encode_absolute(values) do
    values
    |> Enum.sort()
    |> encode_pack()
  end

  defp encode_pack(named_values) do
    records = Enum.map(named_values, fn {name, value} -> record(name, value) end)

    case SenmlCbor.encode(Pack.new(records), []) do
      {:ok, encoded} -> {:ok, IO.iodata_to_binary(encoded)}
      {:error, error} -> {:error, error}
    end
  end

  # `{type, value}` to a SenML record. The mirror image of `Wick.Object.Tree.to_pack/2`, which
  # cannot be reused here because these names are request-relative rather than absolute paths.
  defp record(name, {:string, value}), do: %Record{name: name, string_value: value}
  defp record(name, {:core_link, value}), do: %Record{name: name, string_value: value}
  defp record(name, {:boolean, value}), do: %Record{name: name, boolean_value: value}
  defp record(name, {:opaque, value}), do: %Record{name: name, opaque_value: value}
  defp record(name, {:integer, value}), do: %Record{name: name, number_value: value}
  defp record(name, {:unsigned_integer, value}), do: %Record{name: name, number_value: value}
  defp record(name, {:float, value}), do: %Record{name: name, number_value: value}
  defp record(name, {:time, value}), do: %Record{name: name, number_value: value}

  defp record(name, {:objlnk, {object_id, instance_id}}) do
    %Record{name: name, object_link_value: "#{object_id}:#{instance_id}"}
  end

  defp label(%Request.Read{}), do: "READ"
  defp label(%Request.Write{}), do: "WRITE"
  defp label(%Request.Execute{}), do: "EXECUTE"
  defp label(%Request.Discover{}), do: "DISCOVER"
  defp label(%Request.Create{}), do: "CREATE"
  defp label(%Request.Delete{}), do: "DELETE"
  defp label(%Request.WriteAttributes{}), do: "WRITE-ATTRIBUTES"
  defp label(%Request.ReadComposite{}), do: "READ-COMPOSITE"
  defp label(%Request.WriteComposite{}), do: "WRITE-COMPOSITE"
  # Observe and Observe-Composite are absent on purpose: they go out through `Coap.observe/4`
  # rather than `send_request/3`, because establishing a relation is not a plain request.
  defp label(%Request.CancelObserve{}), do: "CANCEL-OBSERVE"

  defp endpoint(opts), do: Keyword.get_lazy(opts, :endpoint, &Endpoint.pid/0)
  defp observations(opts), do: Keyword.get(opts, :observations, Observations)
  defp timeout(opts), do: Keyword.get(opts, :timeout, 5_000)
end

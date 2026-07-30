defmodule WickDemoServer.Web.Router do
  @moduledoc """
  HTTP surface for the demo UI — the analogue of Leshan's `ClientServlet` and `EventServlet`.

  Every route is a thin wrapper over `WickDemoServer.Client`, which does the actual LwM2M work.
  Nothing protocol-shaped happens here: the router parses params, calls a function, and
  serialises the result via `WickDemoServer.Web.Api`.

  ## Routes

      GET  /                                  the UI (single self-contained page)
      GET  /api/registrations                 registered clients
      GET  /api/registrations/:id             one client, with its advertised Object tree
      GET  /api/observations                  live Observe relations
      GET  /api/readings                      Notifications and Sends received
      GET  /api/events                        Server-Sent Events stream (live)

      POST /api/registrations/:id/read        %{"path" => "/3/0/0", "accept" => 0}
      POST /api/registrations/:id/write       %{"path" =>, "value" => %{type:, value:}, "mode" =>}
      POST /api/registrations/:id/execute     %{"path" =>, "arguments" => "…"}
      POST /api/registrations/:id/discover    %{"path" =>}
      POST /api/registrations/:id/create      %{"path" =>, "resources" => %{"5700" => …}}
      POST /api/registrations/:id/delete      %{"path" =>}
      POST /api/registrations/:id/attributes  %{"path" =>, "attributes" => %{"pmin" => 10}}
      POST /api/registrations/:id/observe     %{"path" =>}  |  %{"paths" => [...]}
      POST /api/registrations/:id/cancel      %{"path" =>, "handle" => "…"}

  ## Errors

  A `4xx` means the request was wrong — unknown registration, unparseable path, bad value. A
  `2xx` means the *operation* was carried out, and the LwM2M status is in the body; a device
  answering `4.04 Not Found` is a successful exchange with an error result, and conflating the
  two would make the UI unable to tell "I asked badly" from "the device said no".
  """

  use Plug.Router

  require Logger

  alias Wick.Observation
  alias Wick.Path
  alias WickDemoServer.Client
  alias WickDemoServer.Events
  alias WickDemoServer.Observations
  alias WickDemoServer.Store
  alias WickDemoServer.Web.Api
  alias WickDemoServer.Web.Ui

  # How long an idle SSE connection is held open before the browser is asked to reconnect.
  @sse_keepalive_ms 20_000

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  # ── UI ─────────────────────────────────────────────────────────────────────

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, Ui.page())
  end

  # ── Reads ──────────────────────────────────────────────────────────────────

  get "/api/registrations" do
    json(conn, 200, %{registrations: Enum.map(Store.list(), &Api.registration/1)})
  end

  get "/api/registrations/:id" do
    case find_registration(id) do
      nil ->
        json(conn, 404, %{error: "unknown registration #{id}"})

      record ->
        json(conn, 200, %{
          registration: Api.registration(record),
          tree: Api.advertised_tree(record),
          observations: observations_for(id)
        })
    end
  end

  get "/api/observations" do
    json(conn, 200, %{observations: all_observations()})
  end

  get "/api/readings" do
    json(conn, 200, %{readings: Enum.map(Observations.readings(), &Api.event/1)})
  end

  get "/api/summary" do
    json(conn, 200, %{
      port: WickDemoServer.port(),
      registrations: length(Store.list()),
      observations: length(Observations.list()),
      readings: length(Observations.readings()),
      subscribers: Events.subscriber_count()
    })
  end

  # ── Server-Sent Events ─────────────────────────────────────────────────────

  # SSE rather than WebSockets: the traffic is one-directional (server pushes protocol events,
  # the browser never sends anything back over it), and SSE reconnects on its own. A WebSocket
  # would mean a heartbeat and reconnect logic in the page for no benefit.
  get "/api/events" do
    :ok = Events.subscribe()

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      # Without this, a proxy that buffers responses holds events until the connection closes,
      # which for a stream that never closes means forever.
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    stream_events(conn)
  end

  # ── Operations ─────────────────────────────────────────────────────────────

  post "/api/registrations/:id/read" do
    with_path(conn, id, fn path ->
      Client.read(id, path, accept: conn.body_params["accept"])
    end)
  end

  post "/api/registrations/:id/write" do
    with {:ok, path} <- fetch_path(conn.body_params),
         {:ok, value} <- Api.parse_value(conn.body_params["value"] || %{}),
         {:ok, mode} <- fetch_mode(conn.body_params) do
      respond(conn, id, Client.write(id, path, value, mode: mode))
    else
      {:error, message} -> json(conn, 400, %{error: message})
    end
  end

  post "/api/registrations/:id/execute" do
    with_path(conn, id, fn path ->
      Client.execute(id, path, conn.body_params["arguments"])
    end)
  end

  post "/api/registrations/:id/discover" do
    with_path(conn, id, fn path -> Client.discover(id, path) end)
  end

  post "/api/registrations/:id/delete" do
    with_path(conn, id, fn path -> Client.delete(id, path) end)
  end

  post "/api/registrations/:id/create" do
    with {:ok, path} <- fetch_path(conn.body_params),
         {:ok, resources} <- parse_resources(conn.body_params["resources"] || %{}) do
      respond(conn, id, Client.create(id, path, resources))
    else
      {:error, message} -> json(conn, 400, %{error: message})
    end
  end

  post "/api/registrations/:id/attributes" do
    with {:ok, path} <- fetch_path(conn.body_params),
         {:ok, attributes} <- Api.parse_attributes(conn.body_params["attributes"] || %{}) do
      respond(conn, id, Client.write_attributes(id, path, attributes))
    else
      {:error, message} -> json(conn, 400, %{error: message})
    end
  end

  post "/api/registrations/:id/read_composite" do
    case fetch_paths(conn.body_params) do
      {:ok, paths} -> respond(conn, id, Client.read_composite(id, paths))
      {:error, message} -> json(conn, 400, %{error: message})
    end
  end

  post "/api/registrations/:id/observe" do
    result =
      case conn.body_params do
        %{"paths" => paths} when is_list(paths) and length(paths) > 1 ->
          with {:ok, parsed} <- parse_all(paths), do: Client.observe_composite(id, parsed)

        params ->
          with {:ok, path} <- fetch_path(params), do: Client.observe(id, path)
      end

    case result do
      {:ok, handle} ->
        publish_observe(id, handle)
        json(conn, 200, %{handle: Api.handle_key(handle), observations: observations_for(id)})

      {:error, message} when is_binary(message) ->
        json(conn, 400, %{error: message})

      {:error, %Wick.Error{} = error} ->
        json(conn, 400, %{error: error.message})

      {:error, %Wick.Response{} = response} ->
        json(conn, 200, %{response: Api.response(response)})

      {:error, reason} ->
        json(conn, 502, %{error: "transport error: #{inspect(reason)}"})
    end
  end

  post "/api/registrations/:id/cancel" do
    with {:ok, path} <- fetch_path(conn.body_params),
         {:ok, handle} <- find_handle(conn.body_params["handle"]) do
      result = Client.cancel_observe(id, path, handle)
      Events.publish(:cancel, registration_id: id, paths: [Path.format(path)])

      case result do
        {:ok, response} ->
          json(conn, 200, %{
            response: Api.response(response),
            observations: observations_for(id)
          })

        {:error, reason} ->
          # The relation is dropped locally regardless — see Client.cancel_observe/4 — so the
          # UI should refresh even when the device never answered.
          json(conn, 200, %{
            error: "device did not answer: #{inspect(reason)}",
            observations: observations_for(id)
          })
      end
    else
      {:error, message} -> json(conn, 400, %{error: message})
    end
  end

  match _ do
    json(conn, 404, %{error: "no route for #{conn.method} #{conn.request_path}"})
  end

  # ── SSE loop ───────────────────────────────────────────────────────────────

  defp stream_events(conn) do
    receive do
      {:wick_demo_event, event} ->
        case chunk(conn, encode_sse(event)) do
          {:ok, conn} -> stream_events(conn)
          {:error, _closed} -> conn
        end
    after
      @sse_keepalive_ms ->
        # A comment line is a valid SSE no-op. It keeps the connection from being reaped by an
        # intermediary that times out idle responses.
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_events(conn)
          {:error, _closed} -> conn
        end
    end
  end

  defp encode_sse(event) do
    "event: #{event.event}\ndata: #{Jason.encode!(Api.event(event))}\n\n"
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp with_path(conn, id, operation) do
    case fetch_path(conn.body_params) do
      {:ok, path} -> respond(conn, id, operation.(path))
      {:error, message} -> json(conn, 400, %{error: message})
    end
  end

  defp respond(conn, _id, {:ok, response}) do
    json(conn, 200, %{response: Api.response(response)})
  end

  defp respond(conn, _id, {:error, :unknown_registration}) do
    json(conn, 404, %{error: "unknown registration"})
  end

  defp respond(conn, _id, {:error, :no_peer_address}) do
    json(conn, 409, %{error: "the registration has no peer address to reach the device at"})
  end

  defp respond(conn, _id, {:error, %Wick.Error{} = error}) do
    json(conn, 400, %{error: error.message})
  end

  defp respond(conn, _id, {:error, reason}) do
    json(conn, 502, %{error: "transport error: #{inspect(reason)}"})
  end

  defp fetch_path(%{"path" => path}) when is_binary(path) do
    case Path.parse(path) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, error} -> {:error, error.message}
    end
  end

  defp fetch_path(_params), do: {:error, ~s|a "path" is required, e.g. "/3/0/0"|}

  defp fetch_paths(%{"paths" => paths}) when is_list(paths), do: parse_all(paths)
  defp fetch_paths(_params), do: {:error, ~s|a "paths" array is required|}

  defp parse_all(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn raw, {:ok, acc} ->
      case Path.parse(raw) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, error} -> {:halt, {:error, error.message}}
      end
    end)
  end

  defp fetch_mode(%{"mode" => "partial_update"}), do: {:ok, :partial_update}
  defp fetch_mode(%{"mode" => "replace"}), do: {:ok, :replace}
  defp fetch_mode(%{"mode" => other}), do: {:error, "unknown write mode #{inspect(other)}"}
  defp fetch_mode(_params), do: {:ok, :replace}

  defp parse_resources(resources) when is_map(resources) do
    Enum.reduce_while(resources, {:ok, %{}}, fn {raw_id, raw_value}, {:ok, acc} ->
      with {resource_id, ""} <- Integer.parse(to_string(raw_id)),
           {:ok, value} <- Api.parse_value(raw_value) do
        {:cont, {:ok, Map.put(acc, resource_id, value)}}
      else
        {:error, message} -> {:halt, {:error, message}}
        _malformed -> {:halt, {:error, "resource ids must be integers, got #{inspect(raw_id)}"}}
      end
    end)
  end

  defp parse_resources(_other), do: {:error, ~s|"resources" must be an object|}

  # Handles are opaque tuples the browser cannot hold, so it sends back the derived key and we
  # find the matching relation.
  defp find_handle(nil), do: {:error, ~s|a "handle" is required to cancel an observation|}

  defp find_handle(key) when is_binary(key) do
    Observations.list()
    |> Enum.zip(handles())
    |> Enum.find_value(fn {_observation, handle} ->
      if Api.handle_key(handle) == key, do: {:ok, handle}
    end)
    |> case do
      nil -> {:error, "no observation matches handle #{key}"}
      found -> found
    end
  end

  defp handles do
    Store.list()
    |> Enum.flat_map(&Observations.handles_for_registration(Observations, &1.location_id))
  end

  defp all_observations do
    for handle <- handles(), {:ok, observation} <- [Observations.fetch(Observations, handle)] do
      Api.observation(handle, observation)
    end
  end

  defp observations_for(registration_id) do
    Enum.filter(all_observations(), &(&1.registration_id == registration_id))
  end

  defp publish_observe(registration_id, handle) do
    case Observations.fetch(Observations, handle) do
      {:ok, %Observation{} = observation} ->
        Events.publish(:observe,
          registration_id: registration_id,
          paths: Enum.map(observation.paths, &Path.format/1)
        )

      :error ->
        :ok
    end
  end

  defp find_registration(id), do: Enum.find(Store.list(), &(&1.location_id == id))

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end

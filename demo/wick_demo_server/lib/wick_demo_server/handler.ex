defmodule WickDemoServer.Handler do
  @moduledoc """
  `WickCoap.Handler` implementation for the demo server.

  Handles the two things a device sends *to* a server:

  * **`/rd*`** — the Registration interface, dispatched through `WickDemoServer.Store` to
    `Wick.Registration.Server.handle/2`.
  * **`/dp`** — a `Wick.Uplink.Send`, the client-initiated push that needs no prior Observe.
    Decoded via `Wick.Uplink.from_wire/1` and recorded in `WickDemoServer.Observations`.

  Notifications do **not** arrive here. A Notify is a CoAP *response* in the Observe exchange
  the server itself opened, so `WickCoap.Endpoint` matches it by token and delivers it to the
  process that registered the observation — `WickDemoServer.Observations`. Handlers only ever
  see requests.

  Anything else is answered with `4.04 Not Found`.
  """

  @behaviour WickCoap.Handler

  require Logger

  alias Wick.Registration.Server
  alias Wick.Uplink
  alias WickCoap.Handler
  alias WickCoap.Message
  alias WickCoap.Option
  alias WickDemoServer.Coap
  alias WickDemoServer.Observations
  alias WickDemoServer.Store

  @impl WickCoap.Handler
  def handle_request(%Message{code: :post, options: options} = request, peer, state) do
    if Handler.uri_path(options) == Uplink.data_path() do
      handle_uplink(request, peer, state)
    else
      handle_registration(request, peer)
    end
  end

  def handle_request(%Message{} = request, peer, _state) do
    handle_registration(request, peer)
  end

  # ── Send (POST /dp) ────────────────────────────────────────────────────────

  defp handle_uplink(%Message{} = request, peer, state) do
    observations = Map.get(state, :observations, Observations)

    code =
      with {:ok, wire} <- Coap.to_request_wire(request),
           {:ok, %Uplink.Send{} = send} <- Uplink.from_wire(wire) do
        :ok = Observations.record_send(observations, send, peer)
        :changed
      else
        {:error, error} ->
          Logger.warning("SEND from #{Coap.format_peer(peer)} rejected: #{error.message}")
          :bad_request
      end

    {:reply,
     %Message{
       type: :ack,
       code: code,
       message_id: request.message_id,
       token: request.token,
       options: [],
       payload: ""
     }}
  end

  # ── Registration (/rd*) ────────────────────────────────────────────────────

  defp handle_registration(%Message{} = request, peer) do
    parsed = %{
      method: coap_method(request.code),
      path: Handler.uri_path(request.options),
      query: parse_query(request.options),
      payload: request.payload || "",
      peer: peer,
      now: System.monotonic_time(:millisecond)
    }

    response = Store.handle_request(parsed)
    log_event(parsed, response, peer)
    {:reply, to_coap(response, request)}
  end

  defp coap_method(:get), do: :get
  defp coap_method(:post), do: :post
  defp coap_method(:put), do: :put
  defp coap_method(:delete), do: :delete
  defp coap_method(other), do: other

  defp parse_query(options) do
    options
    |> Enum.filter(&(&1.number == 15))
    |> Enum.map(fn %Option{value: raw} ->
      case String.split(raw, "=", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, nil}
      end
    end)
  end

  defp to_coap(%Server.Response{} = response, %Message{} = request) do
    %Message{
      type: :ack,
      code: response.code,
      message_id: request.message_id,
      token: request.token,
      options: location_options(response.location_path),
      payload: response.diagnostic || ""
    }
  end

  defp location_options(nil), do: []

  defp location_options(segments) when is_list(segments) do
    Enum.map(segments, &Option.new(8, &1))
  end

  # ── Logging ────────────────────────────────────────────────────────────────

  defp log_event(%{method: :post, path: ["rd"]} = parsed, response, peer) do
    case response.code do
      :created ->
        [_rd, id] = response.location_path

        ep = query_get(parsed.query, "ep")
        lt = query_get(parsed.query, "lt") || "default"

        Logger.info("REGISTER ep=#{ep} id=#{id} lifetime=#{lt}s from=#{format_peer(peer)}")

      :bad_request ->
        Logger.warning("REGISTER rejected from=#{format_peer(peer)}: #{response.diagnostic}")

      other ->
        Logger.warning("REGISTER unexpected response=#{other} from=#{format_peer(peer)}")
    end
  end

  defp log_event(%{method: :post, path: ["rd", id]} = parsed, response, peer) do
    case response.code do
      :changed ->
        lt = query_get(parsed.query, "lt") || "unchanged"
        Logger.info("UPDATE id=#{id} lifetime=#{lt} from=#{format_peer(peer)}")

      :not_found ->
        Logger.warning("UPDATE id=#{id} unknown — from=#{format_peer(peer)}")

      other ->
        Logger.warning("UPDATE id=#{id} response=#{other} from=#{format_peer(peer)}")
    end
  end

  defp log_event(%{method: :delete, path: ["rd", id]}, response, peer) do
    case response.code do
      :deleted -> Logger.info("DEREGISTER id=#{id} from=#{format_peer(peer)}")
      :not_found -> Logger.warning("DEREGISTER id=#{id} unknown from=#{format_peer(peer)}")
      other -> Logger.warning("DEREGISTER id=#{id} response=#{other} from=#{format_peer(peer)}")
    end
  end

  defp log_event(parsed, response, peer) do
    Logger.debug(
      "#{String.upcase(to_string(parsed.method))} /#{Enum.join(parsed.path, "/")} → " <>
        "#{response.code} from=#{format_peer(peer)}"
    )
  end

  defp query_get(query, key) do
    case List.keyfind(query, key, 0) do
      {^key, value} -> value
      _ -> nil
    end
  end

  defp format_peer({{a, b, c, d}, port}), do: "#{a}.#{b}.#{c}.#{d}:#{port}"
  defp format_peer({ip, port}), do: "#{inspect(ip)}:#{port}"
  defp format_peer(other), do: inspect(other)
end

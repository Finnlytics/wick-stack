defmodule WickDemoClient.Handler do
  @moduledoc """
  `WickCoap.Handler` for inbound server-initiated traffic.

  Until Device Management landed, the demo client answered every inbound request with an RST —
  it was purely the initiating side. Now it is answerable, and this is the door.

  The module is intentionally three lines of real work: turn the CoAP message into a
  `Wick.Wire`, hand it to `WickDemoClient.Device`, turn the `Wick.Response` back into CoAP.
  Everything protocol-shaped is in Wick; everything device-shaped is in `Device`; the only
  thing here is transport.

  Observe needs no code at all. `WickCoap.Endpoint` sees the Observe option, registers the
  relation, and grafts the sequence number onto whatever response comes back — so an Observe
  arrives here looking like a Read and leaves looking like a Read.
  """

  @behaviour WickCoap.Handler

  require Logger

  alias Wick.Response
  alias WickCoap.Message
  alias WickDemoClient.Coap
  alias WickDemoClient.Device

  @impl WickCoap.Handler
  def handle_request(%Message{} = message, peer, state) do
    device = Map.get(state, :device, Device)

    response =
      case Coap.to_request_wire(message) do
        {:ok, wire} ->
          Device.handle_wire(device, wire)

        {:error, error} ->
          Logger.warning(
            "inbound request from #{format_peer(peer)} not understood: #{error.message}"
          )

          Response.error(:bad_request, error.message)
      end

    {:reply, Coap.reply(response, message)}
  end

  defp format_peer({ip, port}), do: "#{:inet.ntoa(ip)}:#{port}"
  defp format_peer(other), do: inspect(other)
end

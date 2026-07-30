defmodule WickDemoClient.Uplink do
  @moduledoc """
  Client-initiated Send (LwM2M 1.2 §6.4.13) — `POST /dp`.

  Send is the counterpart to Observe, and the difference is who decides. With Observe the
  server asks and the client obeys; with Send the client decides what is worth reporting and
  the server takes it or leaves it. For a battery-powered device that wakes, reports, and
  sleeps, Send is the cheaper shape: no relation to maintain across a sleep cycle, no
  registration for the server to have forgotten.

  There is no state here, so no process: build the payload from the tree, post it, done.
  """

  require Logger

  alias Wick.Path
  alias Wick.Response
  alias Wick.Uplink
  alias WickDemoClient.Coap
  alias WickDemoClient.Device
  alias WickDemoClient.Objects

  @doc """
  Push the values at `paths` to the server.

  Defaults to the temperature Resource, which is the one thing on this device that changes.
  Pass any list of `Wick.Path`s to report more.

  ## Options

  * `:endpoint` — the `WickCoap.Endpoint` to send from. Defaults to the app's own.
  * `:device` — the `WickDemoClient.Device` to read from. Defaults to the app's own.
  * `:peer` — `{ip, port}` of the server. Defaults to the configured server.
  * `:timeout` — milliseconds. Default 5000.
  """
  @spec send_values([Path.t()], keyword()) :: {:ok, Response.t()} | {:error, term()}
  def send_values(paths \\ [Objects.temperature_path()], opts \\ []) do
    device = Keyword.get(opts, :device, Device)
    endpoint = Keyword.get_lazy(opts, :endpoint, &default_endpoint/0)
    peer = Keyword.get_lazy(opts, :peer, &default_peer/0)

    {content_format, payload} = Device.encode_paths(device, paths)
    wire = Uplink.to_wire(%Uplink.Send{content_format: content_format, payload: payload})

    case Coap.request(endpoint, peer, wire, Keyword.take(opts, [:timeout])) do
      {:ok, response} ->
        Logger.info("SEND #{Enum.map_join(paths, ", ", &Path.format/1)} → #{response.status}")

        {:ok, response}

      {:error, reason} ->
        Logger.warning("SEND transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp default_endpoint, do: WickDemoClient.Endpoint.pid()

  defp default_peer do
    {Application.get_env(:wick_demo_client, :server_host, {127, 0, 0, 1}),
     Application.get_env(:wick_demo_client, :server_port, 5683)}
  end
end

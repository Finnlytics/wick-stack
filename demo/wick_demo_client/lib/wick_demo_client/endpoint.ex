defmodule WickDemoClient.Endpoint do
  @moduledoc """
  Owns the client's `WickCoap.Endpoint`. The client doesn't need to listen on a
  well-known port — an ephemeral UDP socket is enough since LwM2M servers reply on
  the same flow they receive from. The bound port is logged at boot.

  `WickDemoClient.Handler` is installed, so the client answers server-initiated Device
  Management, Information Reporting, and Bootstrap traffic on the same socket it registers
  from. That single socket is not incidental: a device behind NAT is only reachable on the
  flow it opened itself, which is why LwM2M servers must reply on the source address of the
  Register rather than dialling the device.
  """

  use GenServer

  require Logger

  alias WickCoap.Endpoint, as: CoapEndpoint
  alias WickDemoClient.Handler

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec pid() :: pid()
  def pid, do: GenServer.call(@name, :endpoint_pid)

  @spec port() :: :inet.port_number()
  def port, do: GenServer.call(@name, :port)

  @impl GenServer
  def init(opts) do
    device = Keyword.get(opts, :device, WickDemoClient.Device)

    {:ok, endpoint} =
      CoapEndpoint.start_link(handler: Handler, handler_state: %{device: device})

    bound = CoapEndpoint.port(endpoint)
    Logger.info("WickDemoClient.Endpoint bound on UDP/#{bound} (handler=#{inspect(Handler)})")
    {:ok, %{endpoint: endpoint, port: bound}}
  end

  @impl GenServer
  def handle_call(:endpoint_pid, _from, state), do: {:reply, state.endpoint, state}
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state[:endpoint] && Process.alive?(state.endpoint), do: CoapEndpoint.stop(state.endpoint)
    :ok
  end
end

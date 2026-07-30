defmodule WickDemoClient.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    # `:rest_for_one` and the order matter. Device holds the Object tree and must exist before
    # the Endpoint starts serving inbound requests against it; the Registrar reads the tree to
    # build its Register payload; the Sensor pushes notifications through the Endpoint. If any
    # one restarts, everything downstream of it restarts too.
    children = [
      WickDemoClient.Device,
      WickDemoClient.Endpoint,
      WickDemoClient.Registrar,
      WickDemoClient.Sensor
    ]

    opts = [strategy: :rest_for_one, name: WickDemoClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

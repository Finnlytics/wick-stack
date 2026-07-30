defmodule WickDemoServer.Application do
  @moduledoc false

  use Application

  require Logger

  @impl Application
  def start(_type, _args) do
    # Order matters. Events must exist before anything publishes; Observations must exist before
    # the CoAP Endpoint starts accepting traffic, since it is the process notifications are
    # delivered to. The web server comes last — it only reads state the others own.
    children =
      [
        WickDemoServer.Events,
        WickDemoServer.Store,
        WickDemoServer.Observations,
        WickDemoServer.Endpoint
      ] ++ web_children()

    opts = [strategy: :one_for_one, name: WickDemoServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The UI is opt-out via `config :wick_demo_server, http_port: nil`, which the test env uses:
  # a fixed port would collide across concurrent runs, and the tests drive the API directly.
  defp web_children do
    # The fallback matches config/config.exs. 8683 echoes the CoAP port and stays clear of 8080,
    # which is usually already taken locally.
    case Application.get_env(:wick_demo_server, :http_port, 8683) do
      nil ->
        []

      port ->
        ip = Application.get_env(:wick_demo_server, :http_ip, {127, 0, 0, 1})
        Logger.info("WickDemoServer web UI on http://#{:inet.ntoa(ip)}:#{port}")

        [
          {
            Bandit,
            # Loopback by default, and this is not cosmetic: the UI has no authentication and can
            # Write and Execute against every registered device — including Executable Resources
            # like Firmware Update. Binding to all interfaces would put a remote-control panel for
            # the fleet on the network. Eclipse's leshan-demo-server has no auth either; the
            # difference is that this one declines to listen beyond the machine it runs on.
            #
            # Override with `config :wick_demo_server, http_ip: {0, 0, 0, 0}` if you genuinely
            # want it reachable, and put something in front of it that does authenticate.
            plug: WickDemoServer.Web.Router,
            scheme: :http,
            ip: ip,
            port: port,
            startup_log: false,
            http_options: [log_protocol_errors: false]
          }
        ]
    end
  end
end

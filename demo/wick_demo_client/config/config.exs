import Config

config :wick_demo_client,
  # IP+port of the LwM2M server to register with. `127.0.0.1:5683` matches the demo
  # server's default; override in dev/test/prod files or via runtime env.
  server_host: {127, 0, 0, 1},
  server_port: 5683,
  # Endpoint name registered with the server. Must be unique within a deployment.
  endpoint_name: "wick-demo-client",
  # Lifetime in seconds. Update messages refresh the registration; we send them at
  # `lifetime * 0.8` to leave headroom against jitter.
  lifetime: 60,
  # Auto-start the registration loop on application boot. Tests set this to false so
  # they can drive registration explicitly.
  autostart: true,
  # Transport mode for the client → server socket. :udp only for now.
  transport: :udp,
  # IP+port of the Bootstrap Server, used only when `WickDemoClient.bootstrap/1` is called
  # explicitly. The demo client is pre-provisioned with a Server Object, so it never needs
  # to bootstrap on boot.
  bootstrap_server_host: {127, 0, 0, 1},
  bootstrap_server_port: 5783,
  # How often the synthetic temperature sensor takes a reading. Each reading may or may not
  # produce a Notification — that depends on the notification attributes a server has
  # written. Set to `nil` to keep the sensor idle and drive it by hand with
  # `WickDemoClient.tick/0`.
  sensor_interval_ms: 10_000

import_config "#{config_env()}.exs"

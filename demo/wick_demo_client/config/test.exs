import Config

# Test wires server + client together inside the same VM; the server binds an
# ephemeral port and the test patches the client's runtime config before starting it.
# `autostart: false` keeps the Registrar idle until the test calls into it.
config :wick_demo_client,
  autostart: false,
  endpoint_name: "wick-demo-client-test",
  lifetime: 60,
  # The sensor stays idle so readings are driven explicitly by the tests rather than by
  # wall-clock time — a background timer firing mid-assertion is the classic way for a
  # notification test to become flaky.
  sensor_interval_ms: nil

config :wick_demo_server,
  port: 0,
  transport: :udp,
  reaper_interval_ms: 200,
  # The client's tests boot the demo server as a dependency; it needs no web UI here, and a
  # fixed TCP port would collide with a real `iex -S mix` session running alongside.
  http_port: nil

config :logger, level: :warning

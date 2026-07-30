import Config

# Bind ephemeral so tests can run in parallel without port clashes; the test reads the
# actual port back from the running endpoint.
config :wick_demo_server,
  port: 0,
  transport: :udp,
  reaper_interval_ms: 100,
  # No web server under test: a fixed TCP port would collide between concurrent runs, and the
  # router is exercised directly through `Plug.Test` rather than over a socket.
  http_port: nil

config :logger, level: :warning

import Config

config :wick_demo_server,
  # CoAP/UDP listening port. LwM2M default is 5683 for unencrypted, 5684 for DTLS.
  # Set to 0 to bind an ephemeral port (useful for tests).
  port: 5683,
  # :udp or :dtls. DTLS requires a populated :psk_db map.
  transport: :udp,
  # Map of PSK identity (binary) to pre-shared secret (binary). Only consulted when
  # transport is :dtls. Devices outside this map are rejected during handshake.
  psk_db: %{},
  # Reaper sweep interval (ms). Registrations whose `lifetime` has elapsed without an
  # Update are deleted on the next sweep. 1s gives sub-second pruning latency without
  # wasting CPU.
  reaper_interval_ms: 1_000,
  # TCP port for the web UI — the browser interface that lists registered clients and drives
  # Read / Write / Execute / Observe against them. Set to `nil` to run headless.
  #
  # 8683 rather than 8080 on purpose: it echoes the CoAP port above, and 8080 is the single most
  # contended port on a development machine.
  http_port: 8683,
  # Loopback only. The UI has no authentication and can Write and Execute against every
  # registered device, so it deliberately does not listen beyond this machine. Set
  # `{0, 0, 0, 0}` to expose it — and put an authenticating proxy in front if you do.
  http_ip: {127, 0, 0, 1}

import_config "#{config_env()}.exs"

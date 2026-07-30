defmodule WickDemoServer.Endpoint do
  @moduledoc """
  Thin convenience wrapper that starts `WickCoap.Endpoint` with the demo server's
  handler and translates app config into the right options.

  Two transport modes:

  * `:udp` — plain CoAP/UDP on the configured port. No authentication.
  * `:dtls` — DTLS PSK. Requires `:psk_db` map of `identity (binary) => secret (binary)`.
    Devices presenting an identity not in the map are rejected during handshake.

  ## Configuration

      config :wick_demo_server,
        port: 5683,
        transport: :udp,
        psk_db: %{"device-1" => "0123456789abcdef"}

  Bound port (especially relevant when `port: 0`) is logged on startup.
  """

  use GenServer

  require Logger

  alias WickCoap.Endpoint

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec port() :: :inet.port_number()
  def port, do: GenServer.call(@name, :port)

  @doc """
  The underlying `WickCoap.Endpoint` pid.

  `WickDemoServer.Client` needs it: issuing Device Management requests means *sending* from
  the same socket devices registered on, which is the only address a NATed device is reachable
  at.
  """
  @spec pid() :: pid()
  def pid, do: GenServer.call(@name, :endpoint_pid)

  @impl GenServer
  def init(opts) do
    port = Keyword.get(opts, :port) || Application.get_env(:wick_demo_server, :port, 5683)

    transport =
      Keyword.get(opts, :transport) ||
        Application.get_env(:wick_demo_server, :transport, :udp)

    {:ok, endpoint} =
      Endpoint.start_link(
        port: port,
        handler: WickDemoServer.Handler,
        handler_state: %{},
        transport: transport,
        dtls_opts: dtls_opts(transport)
      )

    bound = Endpoint.port(endpoint)

    Logger.info(
      "WickDemoServer.Endpoint listening on #{transport}:#{bound} " <>
        "(handler=WickDemoServer.Handler)"
    )

    {:ok, %{endpoint: endpoint, port: bound, transport: transport}}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:endpoint_pid, _from, state), do: {:reply, state.endpoint, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state[:endpoint] && Process.alive?(state.endpoint) do
      Endpoint.stop(state.endpoint)
    end

    :ok
  end

  # ── DTLS config ────────────────────────────────────────────────────────────

  defp dtls_opts(:udp), do: []

  defp dtls_opts(:dtls) do
    db = Application.get_env(:wick_demo_server, :psk_db, %{})

    [
      ciphers: [
        %{mac: :aead, cipher: :aes_128_ccm_8, key_exchange: :psk, prf: :default_prf}
      ],
      user_lookup_fun: {&__MODULE__.psk_lookup/3, db},
      versions: [:"dtlsv1.2"],
      verify: :verify_none
    ]
  end

  @doc """
  Callback handed to OTP `:ssl` as `user_lookup_fun`. Returns `{:ok, secret}` when the
  identity is recognised; an explicit `{:error, _}` if not — OTP rejects the handshake
  in that case. Identities arrive as binaries; the demo `psk_db` is keyed by binary
  too.
  """
  def psk_lookup(:psk, identity, db) when is_map(db) do
    identity_bin = if is_binary(identity), do: identity, else: to_string(identity)

    case Map.fetch(db, identity_bin) do
      {:ok, secret} ->
        {:ok, secret}

      :error ->
        Logger.warning(
          "PSK lookup miss for identity=#{inspect(identity_bin)} — rejecting handshake"
        )

        {:error, :unknown_psk_identity}
    end
  end
end

defmodule WickCoap.DtlsAcceptor do
  @moduledoc """
  Accept loop for a DTLS listening socket.

  Runs as a dedicated process spawned by `WickCoap.Endpoint` in server mode. The loop is
  blocking — `:ssl.transport_accept/1` waits for an inbound ClientHello, then
  `:ssl.handshake/2` finishes the handshake. On success the acceptor:

  1. Resolves the peer's `{ip, port}` via `:ssl.peername/1`.
  2. Spawns a `WickCoap.DtlsDemux` to own the new socket and forward inbound bytes.
  3. Notifies the endpoint with `{:wick_coap_dtls_accept, peer, ssl_socket, demux_pid}`.

  Handshake failures are logged and the loop continues — one bad peer must not stop the
  endpoint accepting others.
  """

  require Logger

  @handshake_timeout 10_000

  @spec start_link(pid(), :ssl.sslsocket()) :: {:ok, pid()}
  def start_link(endpoint, listener) do
    pid = spawn_link(fn -> loop(endpoint, listener) end)
    {:ok, pid}
  end

  defp loop(endpoint, listener) do
    case :ssl.transport_accept(listener) do
      {:ok, transport_socket} ->
        handle_accept(endpoint, transport_socket)
        loop(endpoint, listener)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("WickCoap.DtlsAcceptor: transport_accept failed: #{inspect(reason)}")
        loop(endpoint, listener)
    end
  end

  defp handle_accept(endpoint, transport_socket) do
    case :ssl.handshake(transport_socket, @handshake_timeout) do
      {:ok, ssl_socket} ->
        finalise(endpoint, ssl_socket)

      {:error, reason} ->
        Logger.info("WickCoap.DtlsAcceptor: handshake failed: #{inspect(reason)}")
        _ = :ssl.close(transport_socket)
        :ok
    end
  end

  defp finalise(endpoint, ssl_socket) do
    case :ssl.peername(ssl_socket) do
      {:ok, peer} ->
        case WickCoap.DtlsDemux.start(endpoint, peer, ssl_socket) do
          {:ok, demux} ->
            send(endpoint, {:wick_coap_dtls_accept, peer, ssl_socket, demux})

          {:error, reason} ->
            Logger.warning("WickCoap.DtlsAcceptor: demux start failed: #{inspect(reason)}")
            _ = :ssl.close(ssl_socket)
        end

      {:error, reason} ->
        Logger.warning("WickCoap.DtlsAcceptor: peername failed: #{inspect(reason)}")
        _ = :ssl.close(ssl_socket)
    end
  end
end

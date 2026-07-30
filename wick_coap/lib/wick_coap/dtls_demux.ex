defmodule WickCoap.DtlsDemux do
  @moduledoc """
  Per-connection process that owns a DTLS `:ssl` socket and forwards inbound datagrams
  back to the controlling `WickCoap.Endpoint`.

  One demux exists per (peer, dtls-socket) pair. It receives `{:ssl, socket, data}` in
  active mode and re-emits the data to the endpoint as `{:wick_coap_packet, peer, data}`
  — the same shape inbound UDP datagrams take, so the Endpoint dispatch is uniform.

  On `{:ssl_closed, _}` or `{:ssl_error, _, _}`, the demux notifies the endpoint with
  `{:wick_coap_dtls_closed, peer}` and exits normally.

  ## Ownership

  The caller of `start_link/3` must currently own the socket. `start_link/3` spawns the
  demux, transfers ownership via `:ssl.controlling_process/2`, then synchronously asks
  the demux to switch the socket to active mode. By the time `start_link/3` returns,
  inbound packets are flowing to the demux.
  """

  use GenServer

  @type peer :: {:inet.ip_address(), :inet.port_number()}

  @doc """
  Spawn a demux and hand it the socket. The caller must currently own the socket.

  Returns once the demux owns the socket and is in active mode. The demux is *not*
  linked to the caller — it stays alive until `:ssl_closed` arrives or the controlling
  endpoint shuts it down.
  """
  @spec start(pid(), peer(), :ssl.sslsocket()) :: {:ok, pid()} | {:error, term()}
  def start(endpoint, peer, ssl_socket) do
    case GenServer.start(__MODULE__, {endpoint, peer, ssl_socket}) do
      {:ok, pid} ->
        case :ssl.controlling_process(ssl_socket, pid) do
          :ok ->
            :ok = GenServer.call(pid, :activate)
            {:ok, pid}

          {:error, reason} ->
            GenServer.stop(pid)
            {:error, {:controlling_process_failed, reason}}
        end

      other ->
        other
    end
  end

  @impl GenServer
  def init({endpoint, peer, ssl_socket}) do
    {:ok, %{endpoint: endpoint, peer: peer, socket: ssl_socket}}
  end

  @impl GenServer
  def handle_call(:activate, _from, state) do
    :ok = :ssl.setopts(state.socket, [{:active, true}])
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:ssl, _socket, data}, state) do
    send(state.endpoint, {:wick_coap_packet, state.peer, IO.iodata_to_binary(data)})
    {:noreply, state}
  end

  def handle_info({:ssl_closed, _socket}, state) do
    send(state.endpoint, {:wick_coap_dtls_closed, state.peer})
    {:stop, :normal, state}
  end

  def handle_info({:ssl_error, _socket, reason}, state) do
    send(state.endpoint, {:wick_coap_dtls_closed, state.peer})
    {:stop, {:ssl_error, reason}, state}
  end

  @impl GenServer
  def terminate(_reason, %{socket: socket}) do
    _ = :ssl.close(socket)
    :ok
  end
end

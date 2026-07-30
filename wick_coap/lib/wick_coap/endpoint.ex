defmodule WickCoap.Endpoint do
  @moduledoc """
  CoAP endpoint runtime — a GenServer that owns a UDP socket and ties together every
  pure-state module in this library.

  Responsibilities:

  * Open and own a `:gen_udp` socket.
  * Parse inbound datagrams into `WickCoap.Message`s and dispatch:
    * **Requests** (method codes 0.xx) → `c:WickCoap.Handler.handle_request/3` on the
      configured handler module.
    * **Responses** (2.xx / 4.xx / 5.xx) → match against in-flight outbound exchanges by
      Token, reply to the awaiting caller.
  * Retransmit unacknowledged CON requests per `WickCoap.Retransmit` (RFC 7252 §4.8).
  * Deduplicate inbound CONs per `WickCoap.Dedup` (RFC 7252 §4.5) and re-emit the
    cached response if available.
  * Allocate Message IDs and Tokens on outbound traffic.

  ## Block-wise transfer (RFC 7959)

  Block2 transfers are handled transparently to both the caller and the handler.

  **As a client** (calling `request/4`): when a response carries a Block2 option with
  `M=1`, the Endpoint observes the chunk via `WickCoap.BlockReceiver`, re-issues the
  original request with `Block2.num` set to the next index, and repeats until the final
  block arrives. The caller sees one logical request/response pair regardless of how many
  UDP datagrams flew over the wire.

  **As a server** (with a `WickCoap.Handler`): when the handler returns a response whose
  payload exceeds the configured block size (`:block_szx`), the Endpoint splits via
  `WickCoap.BlockSender`, caches the in-flight transfer keyed by
  `{peer, uri_path_segments}`, and serves successive blocks as the client requests them.
  The handler stays oblivious — it returns one response, the Endpoint takes it from there.

  ## DTLS (RFC 6347)

  Pass `transport: :dtls` and a `dtls_opts` keyword list of `:ssl` options to listen on
  DTLS instead of plain UDP. Both PSK and X.509 authentication are supported — they're
  just OTP `:ssl` options forwarded through. Outbound DTLS connections are made
  explicitly via `connect/3` before calling `request/4`.

      {:ok, endpoint} = WickCoap.Endpoint.start_link(
        port: 5684,
        transport: :dtls,
        dtls_opts: [
          ciphers: [%{mac: :aead, cipher: :aes_128_ccm_8, key_exchange: :psk, prf: :default_prf}],
          user_lookup_fun: {&MyPsk.lookup/3, []}
        ]
      )

  ### OTP `:ssl` gaps

  Two DTLS features useful for constrained devices are *not* available because OTP
  `:ssl` does not implement them:

  * **RFC 9146 — DTLS Connection ID.** Lets a session survive a peer's IP/port change.
    Without it, NAT rebinding breaks the underlying DTLS connection; recovery must
    happen at the application layer (re-handshake, or re-register with a fresh peer
    address — see LwM2M Update).
  * **RFC 7250 — Raw Public Keys.** `ssl_handshake.hrl` explicitly marks the extension
    as `Not supported`. LwM2M's "Security Mode 3" (RPK) therefore cannot be offered;
    use PSK (mode 0) or X.509 (mode 2) instead.

  See `ping/3` for an application-layer NAT keepalive that works with both UDP and DTLS.

  ## Observe (RFC 7641)

  Server-side relations are keyed by `{peer, uri_path_segments}`. That is the natural key for
  CoAP, where a resource *is* its path, and it is what lets `notify_observers/3` take a path.

  It has one consequence worth knowing if you are layering LwM2M on top. LwM2M's Composite
  operations (Read-Composite, Observe-Composite) target the **root** and carry their paths in
  the request *body*, so every Observe-Composite from one peer has the same key —
  `{peer, []}` — and a second one replaces the first rather than coexisting with it. Single-path
  Observe is unaffected, and so is the client side (`observe/4`), which keys subscriptions by
  `{peer, token}`.

  Fixing it properly means keying server-side relations by token too, which changes
  `notify_observers/3`'s contract. Deferred rather than done: a consumer needing several
  concurrent Composite observations per device can track relations itself (see
  `Wick.Observation.Store`) and push notifications with `send_async/3`.

  Out of scope for this round (defer to later milestones):

  * Multicast
  * Token-keyed server-side Observe relations (see above)

  ## Starting an endpoint

      {:ok, endpoint} = WickCoap.Endpoint.start_link(
        port: 5683,
        handler: MyHandler,
        handler_state: %{...}
      )

  ## Sending a request

      peer = {{127, 0, 0, 1}, 5683}
      request = %WickCoap.Message{type: :con, code: :get, message_id: 0, token: <<>>,
                                  options: [WickCoap.Option.new(11, "hello")]}
      {:ok, response} = WickCoap.Endpoint.request(endpoint, peer, request)

  The `message_id` and `token` on the request are populated by the Endpoint — set them to
  `0` / `<<>>` in the request and let the Endpoint allocate.
  """

  use GenServer

  alias WickCoap.Block
  alias WickCoap.BlockReceiver
  alias WickCoap.BlockSender
  alias WickCoap.Code
  alias WickCoap.Dedup
  alias WickCoap.Exchange
  alias WickCoap.Message
  alias WickCoap.MessageId
  alias WickCoap.Observe
  alias WickCoap.ObserveRelation
  alias WickCoap.Option
  alias WickCoap.Retransmit
  alias WickCoap.Token

  @default_token_length 8
  @default_block_szx 6

  @typedoc "A peer address — `{ip, port}` for UDP CoAP."
  @type peer :: {:inet.ip_address(), :inet.port_number()}

  # ── Internal state ─────────────────────────────────────────────────────────

  defmodule State do
    @moduledoc false

    @enforce_keys [:socket, :port]
    defstruct [
      :socket,
      :port,
      :handler,
      transport: :udp,
      # DTLS-specific options (ciphers, user_lookup_fun, etc.) passed straight to :ssl
      dtls_opts: [],
      # Per-peer DTLS connection map: peer => %{socket: ssl_socket, demux: pid}
      dtls_peers: %{},
      # The DTLS accept-loop process (server mode only)
      acceptor: nil,
      handler_state: %{},
      block_szx: 6,
      peer_mids: %{},
      peer_dedups: %{},
      outbound: %{},
      awaiting: %{},
      retransmit_refs: %{},
      cached_responses: %{},
      # Block2 *reception* state, keyed by {peer, token}: holds a `WickCoap.BlockReceiver`
      # while a multi-block response transfer is in progress (we are the *client*).
      block_receivers: %{},
      # Block2 *send* state, keyed by {peer, uri_path_segments}: holds a `BlockSender`
      # plus the response template while a multi-block response transfer is in flight
      # (we are the *server*).
      block_responses: %{},
      # Block1 *send* state, keyed by {peer, token}: holds the `BlockSender` and the
      # original request message while a large outbound request is being chunked.
      block_request_senders: %{},
      # Block1 *receive* state, keyed by {peer, uri_path_segments}: holds a
      # `BlockReceiver` while a large inbound request body is being assembled.
      block_request_receivers: %{},
      # Server-side Observe relations, keyed by {peer, uri_path_segments}: each entry is
      # a `WickCoap.ObserveRelation`. Populated when an inbound GET carries `Observe: 0`.
      observers: %{},
      # Client-side Observe subscriptions, keyed by {peer, token}: each entry holds the
      # notification destination process, the last-seen Observe sequence number for the
      # RFC 7641 §3.4 reordering filter, and the original request used to build the
      # deregistration request later.
      subscriptions: %{},
      # Outstanding CoAP Pings (RFC 7252 §4.3), keyed by {peer, message_id}. Each entry
      # holds the GenServer caller waiting on the pong, plus a timer ref so the entry is
      # GC'd if no RST/ACK ever arrives.
      pings: %{}
    ]
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Start a CoAP endpoint.

  ## Options

  * `:port` — UDP port to bind to. `0` means "any available port" (use `port/1` after
    `start_link/1` to discover the actual port). Default `0`.
  * `:handler` — module implementing `WickCoap.Handler`. Optional; without a handler,
    inbound requests are answered with RST.
  * `:handler_state` — opaque state passed to every `handle_request/3` call. Default `%{}`.
  * `:block_szx` — block size exponent for outbound Block2 fragmentation (`0..6`, block
    size = `2^(szx + 4)`). Default `6` (1024 bytes). Outbound responses larger than this
    block size are auto-fragmented via Block2.
  * `:name` — optional GenServer name (atom).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc "Returns the UDP port the endpoint is listening on."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(endpoint), do: GenServer.call(endpoint, :port)

  @doc """
  Send a request and synchronously wait for the response.

  The Endpoint allocates a fresh Message ID and Token, sends the message, and (for CON
  requests) retransmits per RFC 7252 until an ACK or response arrives — or `MAX_RETRANSMIT`
  is reached, in which case `{:error, :timeout}` is returned.

  ## Options

  * `:timeout` — overall caller-side timeout in milliseconds. Default 30 000.
  """
  @spec request(GenServer.server(), peer(), Message.t(), keyword()) ::
          {:ok, Message.t()} | {:error, atom()}
  def request(endpoint, peer, %Message{} = message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(endpoint, {:request, peer, message}, timeout)
  end

  @doc """
  Send a message without waiting for any response. Suitable for NON messages and for
  fire-and-forget CON (no retransmission tracking — use `request/4` if you want
  retransmission).
  """
  @spec send_async(GenServer.server(), peer(), Message.t()) :: :ok
  def send_async(endpoint, peer, %Message{} = message) do
    GenServer.cast(endpoint, {:send, peer, message})
  end

  @doc """
  Subscribe to a remote resource via Observe (RFC 7641).

  The Endpoint sends `request` with the `Observe: 0` option grafted on, awaits the
  initial response, and converts the exchange into a long-lived subscription. From then
  on every inbound notification carrying the matching Token is dispatched to the
  notification destination as `{:wick_coap_notification, handle, response_message}`.

  Returns `{:ok, handle, initial_response}` where `handle` is opaque (currently
  `{peer, token}`) and used for `cancel_observation/2`.

  ## Options

  * `:notify` — `pid()` to receive notification messages. Default `self()`.
  * `:timeout` — overall caller-side timeout (ms) for the initial response. Default 30000.

  ## Reordering

  Notifications whose Observe sequence number is *not newer* than the last-accepted one
  (per RFC 7641 §3.4) are silently dropped. The caller never sees them.
  """
  @spec observe(GenServer.server(), peer(), Message.t(), keyword()) ::
          {:ok, term(), Message.t()} | {:error, term()}
  def observe(endpoint, peer, %Message{} = request, opts \\ []) do
    notify_pid = Keyword.get(opts, :notify, self())
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(endpoint, {:observe, peer, request, notify_pid}, timeout)
  end

  @doc """
  Tear down a subscription previously returned by `observe/4`.

  Sends a GET to the original peer with `Observe: 1` (deregister), then removes the
  subscription locally. The server's response (if any) is dropped — there's nothing
  meaningful to do with it on this side.
  """
  @spec cancel_observation(GenServer.server(), term()) :: :ok | {:error, term()}
  def cancel_observation(endpoint, handle),
    do: GenServer.call(endpoint, {:cancel_observation, handle})

  @doc """
  List the subscriptions currently held by this endpoint, returned as a list of handles.
  """
  @spec subscriptions(GenServer.server()) :: [term()]
  def subscriptions(endpoint), do: GenServer.call(endpoint, :subscriptions)

  @doc """
  Push a notification to every observer registered against `path`.

  Iterates the Endpoint's server-side Observe relations, allocates the next sequence
  number per relation, and emits a notification carrying the relation's stored Token
  plus the bytes you provide.

  The `template` is a `WickCoap.Message` with the desired code, options, and payload.
  The Endpoint overrides `:type` (per the relation's preference, default `:non`),
  `:message_id` (fresh per peer), `:token` (echoed from the registration), and merges
  the Observe option into `:options`.

  Returns the number of notifications dispatched.

  ## Examples

      WickCoap.Endpoint.notify_observers(endpoint, ["counter"], %WickCoap.Message{
        type: :non,
        code: :content,
        message_id: 0,
        token: <<>>,
        options: [WickCoap.Option.from_uint(12, 0)],
        payload: "42"
      })
  """
  @spec notify_observers(GenServer.server(), [binary()], Message.t()) :: non_neg_integer()
  def notify_observers(endpoint, path, %Message{} = template) when is_list(path) do
    GenServer.call(endpoint, {:notify_observers, path, template})
  end

  @doc """
  List the paths currently being observed on this endpoint. Useful for tests and for
  application code that wants to skip work when no one's listening.
  """
  @spec observed_paths(GenServer.server()) :: [{peer(), [binary()]}]
  def observed_paths(endpoint), do: GenServer.call(endpoint, :observed_paths)

  @doc "Stop the endpoint and close its socket."
  @spec stop(GenServer.server()) :: :ok
  def stop(endpoint), do: GenServer.stop(endpoint)

  @doc """
  Send a CoAP Ping (RFC 7252 §4.3) to `peer` and wait for the response.

  An empty Confirmable message is sent; the peer should reply with a Reset (or an empty
  Acknowledgement) carrying the same Message ID. Useful as an application-level liveness
  probe and to keep NAT bindings warm for long-lived DTLS sessions, since OTP `:ssl` does
  not implement RFC 9146 Connection ID.

  Returns `:pong` on reply, or `{:error, :timeout}` if no reply arrives within `:timeout`
  (default `2_000` ms). The Ping is not retransmitted — call again if you need retries.
  """
  @spec ping(GenServer.server(), peer(), keyword()) :: :pong | {:error, term()}
  def ping(endpoint, peer, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2_000)

    try do
      GenServer.call(endpoint, {:ping, peer, timeout}, timeout + 500)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc """
  Establish an outbound DTLS connection to `peer`.

  Only valid for endpoints started with `transport: :dtls`. The handshake runs in the
  calling process — once it completes successfully, ownership of the resulting socket
  is transferred to a dedicated demux process that forwards inbound packets to the
  endpoint, and the connection is registered in the endpoint's peer map.

  ## Options

  * `:psk_identity` — PSK identity (charlist) the client should present. Required for
    PSK cipher suites.
  * `:timeout` — handshake timeout in ms (default `10_000`).

  Any further options are passed straight to `:ssl.connect/4`, merged on top of the
  endpoint's `:dtls_opts`.
  """
  @spec connect(GenServer.server(), peer(), keyword()) :: :ok | {:error, term()}
  def connect(endpoint, peer, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 10_000)
    GenServer.call(endpoint, {:dtls_get_config, peer, opts}, 5_000) |> do_connect(timeout)
  end

  defp do_connect({:error, _} = err, _timeout), do: err

  defp do_connect({:ok, endpoint, peer, ssl_opts}, timeout) do
    {ip, port} = peer

    case :ssl.connect(ip, port, ssl_opts, timeout) do
      {:ok, ssl_socket} ->
        case WickCoap.DtlsDemux.start(endpoint, peer, ssl_socket) do
          {:ok, demux} ->
            GenServer.call(endpoint, {:register_dtls_peer, peer, ssl_socket, demux})

          {:error, reason} ->
            _ = :ssl.close(ssl_socket)
            {:error, {:demux_start_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:dtls_connect_failed, reason}}
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    port = Keyword.get(opts, :port, 0)
    handler = Keyword.get(opts, :handler)
    handler_state = Keyword.get(opts, :handler_state, %{})
    block_szx = Keyword.get(opts, :block_szx, @default_block_szx)
    transport = Keyword.get(opts, :transport, :udp)
    dtls_opts = Keyword.get(opts, :dtls_opts, [])

    case open_transport(transport, port, dtls_opts) do
      {:ok, socket, bound_port, acceptor} ->
        {:ok,
         %State{
           socket: socket,
           port: bound_port,
           handler: handler,
           handler_state: handler_state,
           block_szx: block_szx,
           transport: transport,
           dtls_opts: dtls_opts,
           acceptor: acceptor
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp open_transport(:udp, port, _dtls_opts) do
    case :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}]) do
      {:ok, socket} ->
        {:ok, bound_port} = :inet.port(socket)
        {:ok, socket, bound_port, nil}

      {:error, reason} ->
        {:error, {:udp_open_failed, reason}}
    end
  end

  defp open_transport(:dtls, port, dtls_opts) do
    _ = :ssl.start()
    listen_opts = dtls_listen_opts(port, dtls_opts)

    case :ssl.listen(port, listen_opts) do
      {:ok, listener} ->
        bound_port = dtls_bound_port(listener, port)
        {:ok, acceptor} = WickCoap.DtlsAcceptor.start_link(self(), listener)
        {:ok, listener, bound_port, acceptor}

      {:error, reason} ->
        {:error, {:dtls_listen_failed, reason}}
    end
  end

  defp dtls_listen_opts(_port, dtls_opts) do
    base = [
      :binary,
      {:protocol, :dtls},
      {:active, false},
      {:reuseaddr, true},
      {:versions, [:"dtlsv1.2"]}
    ]

    base ++ Keyword.drop(dtls_opts, [:psk_identity])
  end

  defp dtls_bound_port(listener, requested_port) do
    case :ssl.sockname(listener) do
      {:ok, {_ip, p}} -> p
      _ -> requested_port
    end
  end

  defp build_client_dtls_opts(endpoint_opts, peer_opts) do
    # Per-peer opts win over endpoint-level opts. Bare atoms like `:binary` are valid
    # entries in :ssl options lists but break Keyword.merge/2, so we concatenate and
    # rely on `:ssl` resolving duplicates (it takes the first occurrence).
    peer_opts ++
      Keyword.drop(endpoint_opts, [:reuseaddr]) ++
      [
        :binary,
        {:protocol, :dtls},
        {:active, false},
        {:versions, [:"dtlsv1.2"]},
        {:verify, :verify_none}
      ]
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:dtls_get_config, _peer, _opts}, _from, %State{transport: :udp} = state) do
    {:reply, {:error, :not_dtls}, state}
  end

  def handle_call({:dtls_get_config, peer, peer_opts}, _from, %State{transport: :dtls} = state) do
    ssl_opts = build_client_dtls_opts(state.dtls_opts, peer_opts)
    {:reply, {:ok, self(), peer, ssl_opts}, state}
  end

  def handle_call({:register_dtls_peer, peer, ssl_socket, demux}, _from, state) do
    ref = Process.monitor(demux)

    dtls_peers =
      Map.put(state.dtls_peers, peer, %{socket: ssl_socket, demux: demux, monitor: ref})

    {:reply, :ok, %{state | dtls_peers: dtls_peers}}
  end

  def handle_call({:ping, peer, timeout}, from, state) do
    state = ensure_peer_state(peer, state)
    {mid, mid_alloc} = MessageId.next(state.peer_mids[peer])

    ping = %Message{
      type: :con,
      code: :empty,
      message_id: mid,
      token: <<>>,
      options: [],
      payload: ""
    }

    state = %{state | peer_mids: Map.put(state.peer_mids, peer, mid_alloc)}

    case send_bytes(ping, peer, state) do
      :ok ->
        key = {peer, mid}
        timer = Process.send_after(self(), {:ping_timeout, key}, timeout)
        pings = Map.put(state.pings, key, %{from: from, timer: timer})
        {:noreply, %{state | pings: pings}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:observed_paths, _from, state) do
    {:reply, Map.keys(state.observers), state}
  end

  def handle_call(:subscriptions, _from, state) do
    {:reply, Map.keys(state.subscriptions), state}
  end

  def handle_call({:observe, peer, request, notify_pid}, from, state) do
    options =
      request.options
      |> Enum.reject(&(&1.number == Observe.option_number()))
      |> Kernel.++([Observe.option(0)])

    request = %{request | options: options}
    {request, state} = prepare_outbound(request, peer, state)

    case send_bytes(request, peer, state) do
      :ok ->
        exchange = Exchange.start_outbound(peer: peer, message: request, now: monotonic_ms())
        key = {peer, request.token}

        state =
          state
          |> put_outbound(key, exchange)
          |> Map.update!(:awaiting, &Map.put(&1, key, {:observe, from, notify_pid, request}))
          |> maybe_schedule_retransmit(key, exchange)

        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel_observation, {peer, _token} = key}, _from, state) do
    case Map.fetch(state.subscriptions, key) do
      :error ->
        {:reply, {:error, :unknown_subscription}, state}

      {:ok, %{original_request: original}} ->
        cancel_options =
          original.options
          |> Enum.reject(&(&1.number == Observe.option_number()))
          |> Kernel.++([Observe.option(1)])

        cancel_request = %{original | options: cancel_options, message_id: 0}
        {cancel_request, state} = prepare_outbound(cancel_request, peer, state)
        _ = send_bytes(cancel_request, peer, state)
        state = %{state | subscriptions: Map.delete(state.subscriptions, key)}
        {:reply, :ok, state}
    end
  end

  def handle_call({:notify_observers, path, template}, _from, state) do
    {count, state} =
      Enum.reduce(state.observers, {0, state}, fn
        {{_peer, ^path} = key, _relation}, {n, st} ->
          {n + 1, emit_notification(key, template, st)}

        _other, acc ->
          acc
      end)

    {:reply, count, state}
  end

  def handle_call({:request, peer, message}, from, state) do
    {message, state} = prepare_outbound(message, peer, state)

    if Code.method?(message.code) and byte_size(message.payload) > Block.size(state.block_szx) do
      start_block1_request(message, peer, from, state)
    else
      send_request(message, peer, from, state)
    end
  end

  defp send_request(message, peer, from, state) do
    case send_bytes(message, peer, state) do
      :ok ->
        exchange =
          Exchange.start_outbound(
            peer: peer,
            message: message,
            now: monotonic_ms()
          )

        key = {peer, message.token}

        state =
          state
          |> put_outbound(key, exchange)
          |> put_awaiting(key, from)
          |> maybe_schedule_retransmit(key, exchange)

        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp start_block1_request(message, peer, from, state) do
    sender = BlockSender.new(message.payload, szx: state.block_szx)
    block_message = block1_request_for(message, sender)

    state = %{
      state
      | block_request_senders:
          Map.put(state.block_request_senders, {peer, message.token}, %{
            sender: sender,
            original: message
          })
    }

    send_request(block_message, peer, from, state)
  end

  # Build the outbound CON for the current block of an in-flight Block1 transfer.
  defp block1_request_for(message, %BlockSender{} = sender) do
    {chunk, block, _} = BlockSender.current(sender)

    options =
      message.options
      |> Enum.reject(&(&1.number == Block.block1()))
      |> Kernel.++([Option.new(Block.block1(), Block.encode(block))])

    %{message | payload: chunk, options: options, message_id: 0}
  end

  @impl GenServer
  def handle_cast({:send, peer, message}, state) do
    {message, state} = prepare_outbound(message, peer, state)
    _ = send_bytes(message, peer, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:udp, _socket, ip, port, data}, state) do
    peer = {ip, port}
    {:noreply, decode_and_dispatch(data, peer, state)}
  end

  def handle_info({:wick_coap_packet, peer, data}, state) do
    {:noreply, decode_and_dispatch(data, peer, state)}
  end

  def handle_info({:wick_coap_dtls_accept, peer, ssl_socket, demux}, state) do
    ref = Process.monitor(demux)

    dtls_peers =
      Map.put(state.dtls_peers, peer, %{socket: ssl_socket, demux: demux, monitor: ref})

    {:noreply, %{state | dtls_peers: dtls_peers}}
  end

  def handle_info({:wick_coap_dtls_closed, peer}, state) do
    {:noreply, forget_dtls_peer(peer, state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    peer =
      Enum.find_value(state.dtls_peers, fn
        {peer, %{demux: ^pid}} -> peer
        _ -> nil
      end)

    if peer, do: {:noreply, forget_dtls_peer(peer, state)}, else: {:noreply, state}
  end

  def handle_info({:ping_timeout, key}, state) do
    case Map.pop(state.pings, key) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from}, pings} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pings: pings}}
    end
  end

  def handle_info({:retransmit, key}, state) do
    case Map.fetch(state.outbound, key) do
      :error ->
        {:noreply, state}

      {:ok, exchange} ->
        {:noreply, retransmit_tick(exchange, key, state)}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    close_transport(state)
    :ok
  end

  defp close_transport(%State{transport: :udp, socket: socket}) do
    if is_port(socket), do: :gen_udp.close(socket)
  end

  defp close_transport(%State{transport: :dtls} = state) do
    for {_peer, %{demux: demux}} <- state.dtls_peers, Process.alive?(demux) do
      GenServer.stop(demux, :normal, 1_000)
    end

    _ = :ssl.close(state.socket)
    :ok
  end

  defp decode_and_dispatch(data, peer, state) do
    case Message.decode(data) do
      {:ok, message, _rest} -> dispatch_inbound(message, peer, state)
      {:error, _} -> state
    end
  end

  defp forget_dtls_peer(peer, state) do
    case Map.fetch(state.dtls_peers, peer) do
      {:ok, %{monitor: ref}} ->
        Process.demonitor(ref, [:flush])
        %{state | dtls_peers: Map.delete(state.dtls_peers, peer)}

      :error ->
        state
    end
  end

  # ── Outbound — preparing and sending ───────────────────────────────────────

  defp prepare_outbound(%Message{} = message, peer, %State{} = state) do
    state = ensure_peer_state(peer, state)

    {mid, mid_alloc} =
      if message.message_id == 0 do
        MessageId.next(state.peer_mids[peer])
      else
        {message.message_id, state.peer_mids[peer]}
      end

    token =
      if message.token == <<>> and Code.method?(message.code) do
        Token.new(@default_token_length)
      else
        message.token
      end

    message = %{message | message_id: mid, token: token}
    state = %{state | peer_mids: Map.put(state.peer_mids, peer, mid_alloc)}

    {message, state}
  end

  defp send_bytes(message, peer, state) do
    case Message.encode(message) do
      {:ok, bytes} -> send_raw(bytes, peer, state)
      {:error, _} = err -> err
    end
  end

  defp send_raw(bytes, peer, %State{transport: :udp} = state) do
    :gen_udp.send(state.socket, ip(peer), port_of(peer), bytes)
  end

  defp send_raw(bytes, peer, %State{transport: :dtls} = state) do
    case Map.fetch(state.dtls_peers, peer) do
      {:ok, %{socket: ssl_socket}} ->
        :ssl.send(ssl_socket, bytes)

      :error ->
        {:error, :not_connected}
    end
  end

  defp maybe_schedule_retransmit(state, _key, %Exchange{retransmit: nil}), do: state

  defp maybe_schedule_retransmit(state, key, %Exchange{retransmit: rt}) do
    delay = max(rt.next_at - monotonic_ms(), 0)
    ref = Process.send_after(self(), {:retransmit, key}, delay)
    %{state | retransmit_refs: Map.put(state.retransmit_refs, key, ref)}
  end

  defp retransmit_tick(%Exchange{retransmit: nil}, _key, state), do: state

  defp retransmit_tick(%Exchange{retransmit: rt} = exchange, key, state) do
    case Retransmit.next_step(rt, monotonic_ms()) do
      :wait ->
        delay = max(rt.next_at - monotonic_ms(), 1)
        ref = Process.send_after(self(), {:retransmit, key}, delay)
        %{state | retransmit_refs: Map.put(state.retransmit_refs, key, ref)}

      {:retransmit, rt2} ->
        _ = send_bytes(exchange.message, exchange.peer, state)
        exchange = %Exchange{exchange | retransmit: rt2}
        delay = max(rt2.next_at - monotonic_ms(), 1)
        ref = Process.send_after(self(), {:retransmit, key}, delay)

        state
        |> put_outbound(key, exchange)
        |> Map.update!(:retransmit_refs, &Map.put(&1, key, ref))

      {:expire, _} ->
        complete_outbound(key, {:error, :timeout}, state)
    end
  end

  # ── Inbound — dispatch ─────────────────────────────────────────────────────

  defp dispatch_inbound(%Message{} = message, peer, state) do
    cond do
      Code.method?(message.code) ->
        handle_inbound_request(message, peer, state)

      message.code != :empty ->
        handle_inbound_response(message, peer, state)

      message.type == :con ->
        # RFC 7252 §4.2/§4.3: an empty Confirmable is a CoAP Ping. Echo an RST with the
        # same Message ID so the sender's `ping/3` resolves.
        send_empty_rst(message, peer, state)

      true ->
        # Empty ACK or RST: maybe it's the pong for one of our outgoing pings.
        resolve_ping(message, peer, state)
    end
  end

  defp send_empty_rst(message, peer, state) do
    rst = %Message{
      type: :rst,
      code: :empty,
      message_id: message.message_id,
      token: <<>>,
      options: [],
      payload: ""
    }

    _ =
      case Message.encode(rst) do
        {:ok, bytes} -> send_raw(bytes, peer, state)
        _ -> :ok
      end

    state
  end

  defp resolve_ping(message, peer, state) do
    key = {peer, message.message_id}

    case Map.pop(state.pings, key) do
      {nil, _} ->
        state

      {%{from: from, timer: timer}, pings} ->
        _ = Process.cancel_timer(timer)
        GenServer.reply(from, :pong)
        %{state | pings: pings}
    end
  end

  defp handle_inbound_request(message, peer, state) do
    state = ensure_peer_state(peer, state)

    {result, dedup} =
      Dedup.observe(state.peer_dedups[peer], message.message_id, monotonic_ms())

    state = %{state | peer_dedups: Map.put(state.peer_dedups, peer, dedup)}

    case result do
      :duplicate ->
        re_emit_cached(message, peer, state)

      :fresh ->
        dispatch_to_handler(message, peer, state)
    end
  end

  defp re_emit_cached(message, peer, state) do
    case Map.get(state.cached_responses, {peer, message.message_id}) do
      nil ->
        state

      bytes ->
        _ = send_raw(bytes, peer, state)
        state
    end
  end

  defp dispatch_to_handler(message, peer, %State{handler: nil} = state) do
    send_reset(message, peer, state)
  end

  defp dispatch_to_handler(message, peer, state) do
    case incoming_block1(message) do
      %Block{} = block1 ->
        handle_block1_inbound(block1, message, peer, state)

      nil ->
        dispatch_block2_or_handler(message, peer, state)
    end
  end

  defp dispatch_block2_or_handler(message, peer, state) do
    case incoming_block2(message) do
      {:continuation, %Block{num: num} = block} when num > 0 ->
        path_key = {peer, uri_path_segments(message)}

        case Map.fetch(state.block_responses, path_key) do
          {:ok, transfer} -> emit_block2_response(transfer, block, message, peer, path_key, state)
          :error -> run_handler(message, peer, state)
        end

      _ ->
        run_handler(message, peer, state)
    end
  end

  defp handle_block1_inbound(%Block{} = block, message, peer, state) do
    path_key = {peer, uri_path_segments(message)}
    receiver = Map.get(state.block_request_receivers, path_key, BlockReceiver.new())

    case BlockReceiver.observe(receiver, block, message.payload) do
      {:more, receiver} ->
        # Acknowledge with 2.31 Continue echoing the Block1 option.
        state = %{
          state
          | block_request_receivers: Map.put(state.block_request_receivers, path_key, receiver)
        }

        send_block1_continue(block, message, peer, state)

      {:complete, payload} ->
        state = %{
          state
          | block_request_receivers: Map.delete(state.block_request_receivers, path_key)
        }

        # Replace the request payload with the assembled body and dispatch to the
        # handler. The handler's reply will be wrapped to echo the final Block1 option.
        full_request = %{message | payload: payload}

        outcome = state.handler.handle_request(full_request, peer, state.handler_state)
        apply_block1_final_outcome(outcome, block, message, peer, state)

      {:error, _err} ->
        # Inconsistent block size or similar. Send 4.13 Request Entity Incomplete.
        send_block1_error(message, peer, state)
    end
  end

  defp send_block1_continue(%Block{} = block, request, peer, state) do
    response = %Message{
      type: :ack,
      code: :continue,
      message_id: request.message_id,
      token: request.token,
      options: [Option.new(Block.block1(), Block.encode(block))]
    }

    send_and_cache(response, peer, request.message_id, state)
  end

  defp send_block1_error(request, peer, state) do
    response = %Message{
      type: :ack,
      code: :request_entity_incomplete,
      message_id: request.message_id,
      token: request.token
    }

    send_and_cache(response, peer, request.message_id, state)
  end

  # The handler returned an outcome on the assembled inbound payload. Echo the final
  # Block1 option (NUM=last, M=0) back on the response so the client knows the transfer
  # completed.
  defp apply_block1_final_outcome({:reply, response}, %Block{} = block, request, peer, state) do
    response = build_response(response, request)

    options =
      response.options
      |> Enum.reject(&(&1.number == Block.block1()))
      |> Kernel.++([Option.new(Block.block1(), Block.encode(block))])

    response = %{response | options: options}

    if byte_size(response.payload) > Block.size(state.block_szx) do
      # Block1 in, Block2 out. The handler's response is also large; stack the two.
      start_block2_transfer(response, request, peer, state)
    else
      send_and_cache(response, peer, request.message_id, state)
    end
  end

  defp apply_block1_final_outcome(:ack, _block, request, peer, state) do
    apply_outcome(:ack, request, peer, state)
  end

  defp apply_block1_final_outcome(:ignore, _block, _request, _peer, state), do: state

  defp incoming_block1(%Message{} = message) do
    case Enum.find(message.options, &(&1.number == Block.block1())) do
      nil ->
        nil

      %Option{value: value} ->
        case Block.decode(value) do
          {:ok, block} -> block
          {:error, _} -> nil
        end
    end
  end

  defp run_handler(message, peer, state) do
    outcome = state.handler.handle_request(message, peer, state.handler_state)
    {outcome, state} = maybe_register_observer(outcome, message, peer, state)
    apply_outcome(outcome, message, peer, state)
  end

  # Inspect the inbound request for an Observe option:
  #
  #   * `Observe: 0` (register) — store a relation keyed by `{peer, uri_path}` and graft
  #     a fresh sequence-number Observe option onto the handler's response.
  #   * `Observe: 1` (deregister) — drop any existing relation; pass the response through.
  #   * No Observe option — pass through.
  #
  # The handler is unaware of any of this — it just returns its response and the Endpoint
  # handles the relation bookkeeping.
  defp maybe_register_observer({:reply, response} = outcome, request, peer, state) do
    case Observe.extract(request) do
      {:ok, value} ->
        case Observe.action(value) do
          :register -> register_observer(response, request, peer, state)
          :deregister -> deregister_observer(outcome, request, peer, state)
          nil -> {outcome, state}
        end

      :not_present ->
        {outcome, state}
    end
  end

  defp maybe_register_observer(outcome, _request, _peer, state), do: {outcome, state}

  defp register_observer(response, request, peer, state) do
    path = uri_path_segments(request)
    key = {peer, path}

    relation =
      Map.get_lazy(state.observers, key, fn ->
        %ObserveRelation{
          peer: peer,
          token: request.token,
          path: path,
          registered_at: monotonic_ms()
        }
      end)

    # Refresh token in case the same peer re-registered with a new token.
    relation = %{relation | token: request.token}

    {seq, relation} = ObserveRelation.take_sequence(relation)
    state = %{state | observers: Map.put(state.observers, key, relation)}

    options =
      response.options
      |> Enum.reject(&(&1.number == Observe.option_number()))
      |> Kernel.++([Observe.option(seq)])

    {{:reply, %{response | options: options}}, state}
  end

  defp deregister_observer(outcome, request, peer, state) do
    key = {peer, uri_path_segments(request)}
    {outcome, %{state | observers: Map.delete(state.observers, key)}}
  end

  defp emit_notification(key, template, state) do
    relation = Map.fetch!(state.observers, key)
    {seq, relation} = ObserveRelation.take_sequence(relation)
    state = %{state | observers: Map.put(state.observers, key, relation)}

    options =
      template.options
      |> Enum.reject(&(&1.number == Observe.option_number()))
      |> Kernel.++([Observe.option(seq)])

    notification =
      %{
        template
        | type: relation.type,
          token: relation.token,
          message_id: 0,
          options: options
      }

    {notification, state} = prepare_outbound(notification, relation.peer, state)
    _ = send_bytes(notification, relation.peer, state)
    state
  end

  defp apply_outcome(:ignore, _request, _peer, state), do: state

  defp apply_outcome(:ack, request, peer, state) do
    case request.type do
      :con ->
        ack = %Message{type: :ack, code: :empty, message_id: request.message_id, token: <<>>}
        send_and_cache(ack, peer, request.message_id, state)

      _ ->
        state
    end
  end

  defp apply_outcome({:reply, response}, request, peer, state) do
    response = build_response(response, request)

    if byte_size(response.payload) > Block.size(state.block_szx) do
      start_block2_transfer(response, request, peer, state)
    else
      send_and_cache(response, peer, request.message_id, state)
    end
  end

  defp start_block2_transfer(response, request, peer, state) do
    sender = BlockSender.new(response.payload, szx: state.block_szx)
    path_key = {peer, uri_path_segments(request)}
    transfer = %{sender: sender, response_template: response}

    state = %{
      state
      | block_responses: Map.put(state.block_responses, path_key, transfer)
    }

    {_chunk, block, _} = BlockSender.current(sender)
    emit_block2_response(transfer, block, request, peer, path_key, state)
  end

  defp emit_block2_response(
         %{sender: %BlockSender{} = sender, response_template: template},
         block,
         request,
         peer,
         path_key,
         state
       ) do
    sender = %{sender | num: block.num}
    {chunk, this_block, _} = BlockSender.current(sender)

    options =
      template.options
      |> Enum.reject(&(&1.number == Block.block2()))
      |> Kernel.++([Option.new(Block.block2(), Block.encode(this_block))])

    block_response = %{
      template
      | options: options,
        payload: chunk,
        message_id: request.message_id,
        token: request.token,
        type: response_type_for(request.type)
    }

    state =
      case this_block.more do
        true ->
          %{
            state
            | block_responses:
                Map.put(state.block_responses, path_key, %{
                  sender: sender,
                  response_template: template
                })
          }

        false ->
          %{state | block_responses: Map.delete(state.block_responses, path_key)}
      end

    send_and_cache(block_response, peer, request.message_id, state)
  end

  defp response_type_for(:con), do: :ack
  defp response_type_for(_), do: :non

  defp incoming_block2(%Message{} = message) do
    case Enum.find(message.options, &(&1.number == Block.block2())) do
      nil ->
        :no_block2

      %Option{value: value} ->
        case Block.decode(value) do
          {:ok, block} -> {:continuation, block}
          {:error, _} -> :no_block2
        end
    end
  end

  defp uri_path_segments(%Message{options: options}) do
    options
    |> Enum.filter(&(&1.number == 11))
    |> Enum.map(& &1.value)
  end

  defp build_response(%Message{} = response, %Message{type: :con} = request) do
    %{response | type: :ack, message_id: request.message_id, token: request.token}
  end

  defp build_response(%Message{} = response, %Message{type: :non} = request) do
    %{response | type: :non, message_id: request.message_id, token: request.token}
  end

  defp send_and_cache(message, peer, request_mid, state) do
    case Message.encode(message) do
      {:ok, bytes} ->
        _ = send_raw(bytes, peer, state)
        cached = Map.put(state.cached_responses, {peer, request_mid}, bytes)
        %{state | cached_responses: cached}

      {:error, _} ->
        state
    end
  end

  defp send_reset(request, peer, state) do
    rst = %Message{type: :rst, code: :empty, message_id: request.message_id, token: <<>>}
    {:ok, bytes} = Message.encode(rst)
    _ = send_raw(bytes, peer, state)
    state
  end

  defp handle_inbound_response(message, peer, state) do
    key = {peer, message.token}

    cond do
      Map.has_key?(state.outbound, key) ->
        exchange = Map.fetch!(state.outbound, key)

        if Map.has_key?(state.block_request_senders, key) do
          handle_block1_continue(message, exchange, peer, state)
        else
          case extract_block2(message) do
            :no_block2 -> complete_outbound(key, {:ok, message}, state)
            {:ok, block} -> handle_block2_response(message, block, exchange, peer, state)
          end
        end

      Map.has_key?(state.subscriptions, key) ->
        handle_notification(message, key, state)

      true ->
        state
    end
  end

  defp handle_notification(message, key, state) do
    sub = Map.fetch!(state.subscriptions, key)

    case Observe.extract(message) do
      {:ok, seq} ->
        if Observe.newer?(seq, sub.last_seq) do
          send(sub.notify_pid, {:wick_coap_notification, key, message})
          %{state | subscriptions: Map.put(state.subscriptions, key, %{sub | last_seq: seq})}
        else
          state
        end

      :not_present ->
        # No Observe option on the response — server has ended the relation. Deliver
        # the final message to the subscriber, then drop the subscription.
        send(sub.notify_pid, {:wick_coap_notification, key, message})
        %{state | subscriptions: Map.delete(state.subscriptions, key)}
    end
  end

  defp handle_block1_continue(response, exchange, peer, state) do
    key = {peer, exchange.message.token}
    %{sender: sender, original: original} = Map.fetch!(state.block_request_senders, key)

    if response.code == :continue and BlockSender.more?(sender) do
      # Server confirmed receipt of this block; advance and send the next.
      {:ok, next_sender} = BlockSender.advance(sender)
      next_message = block1_request_for(original, next_sender)
      {next_message, state} = prepare_outbound(next_message, peer, state)

      case send_bytes(next_message, peer, state) do
        :ok ->
          new_exchange =
            Exchange.start_outbound(
              peer: peer,
              message: next_message,
              now: monotonic_ms()
            )

          state = cancel_retransmit(key, state)
          state = put_outbound(state, key, new_exchange)
          state = maybe_schedule_retransmit(state, key, new_exchange)

          %{
            state
            | block_request_senders:
                Map.put(state.block_request_senders, key, %{
                  sender: next_sender,
                  original: original
                })
          }

        {:error, _} ->
          state = drop_block1_sender(key, state)
          complete_outbound(key, {:error, :send_failed}, state)
      end
    else
      # Final response of the Block1 transfer. The server's response may itself be
      # large enough to require Block2 — in which case we hand off to the Block2
      # reception path rather than completing the exchange immediately.
      state = drop_block1_sender(key, state)

      case extract_block2(response) do
        {:ok, block} ->
          # Strip the Block1 option from the exchange template so subsequent Block2
          # sub-requests don't echo it (which would confuse the server into starting a
          # fresh Block1 transfer).
          updated_message = %{
            exchange.message
            | options: Enum.reject(exchange.message.options, &(&1.number == Block.block1())),
              # Also clear the now-irrelevant request payload — Block2 requests don't
              # carry one.
              payload: <<>>
          }

          updated_exchange = %{exchange | message: updated_message}
          state = put_outbound(state, key, updated_exchange)
          handle_block2_response(response, block, updated_exchange, peer, state)

        :no_block2 ->
          complete_outbound(key, {:ok, response}, state)
      end
    end
  end

  defp drop_block1_sender(key, state) do
    %{state | block_request_senders: Map.delete(state.block_request_senders, key)}
  end

  defp extract_block2(%Message{options: options}) do
    case Enum.find(options, &(&1.number == Block.block2())) do
      nil ->
        :no_block2

      %Option{value: value} ->
        case Block.decode(value) do
          {:ok, block} -> {:ok, block}
          {:error, _} -> :no_block2
        end
    end
  end

  defp handle_block2_response(response, %Block{} = block, exchange, peer, state) do
    key = {peer, exchange.message.token}
    receiver = Map.get(state.block_receivers, key, BlockReceiver.new())

    case BlockReceiver.observe(receiver, block, response.payload) do
      {:more, receiver} ->
        state = %{state | block_receivers: Map.put(state.block_receivers, key, receiver)}
        request_next_block(exchange, block, peer, state)

      {:complete, payload} ->
        state = %{state | block_receivers: Map.delete(state.block_receivers, key)}
        assembled = strip_block2(%{response | payload: payload})
        complete_outbound(key, {:ok, assembled}, state)

      {:error, _err} ->
        # Block-wise reassembly failed (e.g., SZX changed mid-transfer). Surface what we
        # got to the caller without assembly so they can decide what to do.
        state = %{state | block_receivers: Map.delete(state.block_receivers, key)}
        complete_outbound(key, {:ok, response}, state)
    end
  end

  defp request_next_block(%Exchange{} = exchange, %Block{} = block, peer, state) do
    next_block = %Block{num: block.num + 1, more: false, szx: block.szx}
    next_option = Option.new(Block.block2(), Block.encode(next_block))

    options =
      exchange.message.options
      |> Enum.reject(&(&1.number == Block.block2()))
      |> Kernel.++([next_option])

    # Same token, fresh MID — that's how the Endpoint correlates the next block fetch
    # back to the same logical exchange.
    next_request = %{exchange.message | options: options, message_id: 0}
    {next_request, state} = prepare_outbound(next_request, peer, state)

    case send_bytes(next_request, peer, state) do
      :ok ->
        # Cancel the previous retransmit timer (the response we just received completes
        # *that* CON), then schedule retransmits for the new block-fetch CON.
        key = {peer, next_request.token}

        new_exchange =
          Exchange.start_outbound(
            peer: peer,
            message: next_request,
            now: monotonic_ms()
          )

        state = cancel_retransmit(key, state)
        state = put_outbound(state, key, new_exchange)
        maybe_schedule_retransmit(state, key, new_exchange)

      {:error, _} ->
        complete_outbound({peer, exchange.message.token}, {:error, :send_failed}, state)
    end
  end

  # Strip the Block2 option from a fully-assembled response — callers don't need it,
  # they get the assembled payload directly.
  defp strip_block2(%Message{options: options} = message) do
    %{message | options: Enum.reject(options, &(&1.number == Block.block2()))}
  end

  # ── State helpers ──────────────────────────────────────────────────────────

  defp ensure_peer_state(peer, state) do
    state =
      if Map.has_key?(state.peer_mids, peer) do
        state
      else
        %{state | peer_mids: Map.put(state.peer_mids, peer, MessageId.new())}
      end

    if Map.has_key?(state.peer_dedups, peer) do
      state
    else
      %{state | peer_dedups: Map.put(state.peer_dedups, peer, Dedup.new())}
    end
  end

  defp put_outbound(state, key, exchange) do
    %{state | outbound: Map.put(state.outbound, key, exchange)}
  end

  defp put_awaiting(state, key, from) do
    %{state | awaiting: Map.put(state.awaiting, key, from)}
  end

  defp complete_outbound(key, reply, state) do
    state = cancel_retransmit(key, state)

    case Map.pop(state.awaiting, key) do
      {nil, _} ->
        %{state | outbound: Map.delete(state.outbound, key)}

      {{:observe, from, notify_pid, original}, awaiting} ->
        ctx = %{from: from, notify_pid: notify_pid, original: original, awaiting: awaiting}
        complete_observe_registration(key, reply, ctx, state)

      {from, awaiting} ->
        GenServer.reply(from, reply)

        %{
          state
          | outbound: Map.delete(state.outbound, key),
            awaiting: awaiting
        }
    end
  end

  defp complete_observe_registration(key, {:ok, response}, ctx, state) do
    last_seq =
      case Observe.extract(response) do
        {:ok, seq} -> seq
        :not_present -> nil
      end

    subscription = %{
      notify_pid: ctx.notify_pid,
      last_seq: last_seq,
      original_request: ctx.original
    }

    GenServer.reply(ctx.from, {:ok, key, response})

    %{
      state
      | outbound: Map.delete(state.outbound, key),
        awaiting: ctx.awaiting,
        subscriptions: Map.put(state.subscriptions, key, subscription)
    }
  end

  defp complete_observe_registration(key, {:error, _} = err, ctx, state) do
    GenServer.reply(ctx.from, err)

    %{
      state
      | outbound: Map.delete(state.outbound, key),
        awaiting: ctx.awaiting
    }
  end

  defp cancel_retransmit(key, state) do
    case Map.pop(state.retransmit_refs, key) do
      {nil, _} ->
        state

      {ref, refs} ->
        _ = Process.cancel_timer(ref)
        %{state | retransmit_refs: refs}
    end
  end

  # ── Utilities ──────────────────────────────────────────────────────────────

  defp ip({ip, _port}), do: ip
  defp port_of({_ip, port}), do: port

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end

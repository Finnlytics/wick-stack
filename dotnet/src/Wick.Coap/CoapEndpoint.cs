using System.Net;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Wick.Coap.Transport;

namespace Wick.Coap;

/// <summary>
/// A CoAP endpoint that acts as client and server at once over one
/// <see cref="IDatagramTransport"/>. It implements the RFC 7252 messaging layer
/// (confirmable retransmission, acknowledgements, resets, deduplication with cached replies,
/// separate responses, NSTART), block-wise transfer in both directions (RFC 7959), and
/// Observe as client and server (RFC 7641).
/// </summary>
/// <remarks>
/// All state is held under one lock and every collection is bounded or expires: message ids
/// are remembered for EXCHANGE_LIFETIME, block transfers expire, and per-peer counts are
/// capped by <see cref="CoapEndpointOptions"/>. Timers come from the supplied
/// <see cref="TimeProvider"/>, which lets tests run the protocol without real waiting.
/// </remarks>
public sealed partial class CoapEndpoint : IDatagramReceiver, IAsyncDisposable
{
    private readonly Lock _gate = new();
    private readonly IDatagramTransport _transport;
    private readonly bool _ownsTransport;
    private readonly CoapEndpointOptions _options;
    private readonly TimeProvider _time;
    private readonly ILogger _logger;
    private readonly Random _random;
    private readonly CancellationTokenSource _stopping = new();
    private readonly Deduplicator<(ICoapPeer Peer, ushort MessageId)> _dedup;
    private readonly Dictionary<ICoapPeer, PeerState> _peers = [];
    private readonly Dictionary<(ICoapPeer Peer, ushort MessageId), OutboundExchange> _awaitingAck = [];
    private readonly Dictionary<(ICoapPeer Peer, TokenKey Token), OutboundExchange> _awaitingResponse = [];
    private readonly Dictionary<(ICoapPeer Peer, ushort MessageId), ServerExchange> _inProgress = [];
    private readonly Dictionary<(ICoapPeer Peer, TokenKey Token), CoapObservation> _clientObservations = [];
    private readonly Dictionary<(ICoapPeer Peer, TokenKey Token), ServerObservation> _serverObservations = [];
    private readonly Dictionary<(ICoapPeer Peer, ushort MessageId), ServerObservation> _nonNotifications = [];
    private readonly Dictionary<(ICoapPeer Peer, string RequestKey), Block1Transfer> _block1In = [];
    private readonly Dictionary<(ICoapPeer Peer, string RequestKey), Block2Transfer> _block2Out = [];
    private ITimer? _housekeeping;
    private bool _started;
    private bool _disposed;

    /// <summary>Creates an endpoint. Call <see cref="StartAsync"/> to begin receiving.</summary>
    /// <param name="transport">The transport to run over.</param>
    /// <param name="options">Settings, or null for the defaults.</param>
    /// <param name="handler">The handler for inbound requests, or null to answer every request with 4.04.</param>
    /// <param name="timeProvider">The clock and timer source, or null for the system clock.</param>
    /// <param name="logger">An optional logger.</param>
    /// <param name="ownsTransport">True to dispose the transport with the endpoint.</param>
    public CoapEndpoint(
        IDatagramTransport transport,
        CoapEndpointOptions? options = null,
        ICoapRequestHandler? handler = null,
        TimeProvider? timeProvider = null,
        ILogger<CoapEndpoint>? logger = null,
        bool ownsTransport = true)
    {
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _options = options ?? new CoapEndpointOptions();
        _options.Validate();
        _time = timeProvider ?? TimeProvider.System;
        _logger = (ILogger?)logger ?? NullLogger.Instance;
        _ownsTransport = ownsTransport;
        _random = new Random();
        _dedup = new Deduplicator<(ICoapPeer, ushort)>(_options.Transmission.ExchangeLifetime, _options.DeduplicationCapacity);
        Handler = handler;
    }

    /// <summary>The handler for inbound requests. May be replaced at any time.</summary>
    public ICoapRequestHandler? Handler { get; set; }

    /// <summary>The transport this endpoint runs over.</summary>
    public IDatagramTransport Transport => _transport;

    /// <summary>The endpoint's settings.</summary>
    public CoapEndpointOptions Options => _options;

    /// <summary>The bound local address of the transport.</summary>
    public EndPoint LocalEndPoint => _transport.LocalEndPoint;

    /// <summary>Raised, on the thread pool, when a server-side observation ends for any reason.</summary>
    public event Action<ServerObservation>? ServerObservationEnded;

    /// <summary>Raised, on the thread pool, when a peer's session closes and its state has been released.</summary>
    public event Action<ICoapPeer>? PeerClosed;

    /// <summary>Starts the transport and the housekeeping timer.</summary>
    /// <param name="cancellationToken">Cancels start-up.</param>
    /// <returns>A task that completes when the endpoint is receiving.</returns>
    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_started) throw new InvalidOperationException("The endpoint is already started.");
            _started = true;
            _housekeeping = _time.CreateTimer(_ => Housekeep(), null, _options.HousekeepingInterval, _options.HousekeepingInterval);
        }
        await _transport.StartAsync(this, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Finds the peer at an address on the underlying transport.</summary>
    /// <param name="remoteEndPoint">The address.</param>
    /// <returns>The peer.</returns>
    /// <exception cref="InvalidOperationException">The transport has no peer at that address, for example no DTLS session.</exception>
    public ICoapPeer GetPeer(EndPoint remoteEndPoint) =>
        _transport.TryGetPeer(remoteEndPoint, out var peer)
            ? peer
            : throw new InvalidOperationException($"The transport has no peer at {remoteEndPoint}.");

    /// <summary>Stops the endpoint, fails anything outstanding and, if it owns it, disposes the transport.</summary>
    /// <returns>A task that completes when shut down.</returns>
    public async ValueTask DisposeAsync()
    {
        List<Action> completions = [];
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _housekeeping?.Dispose();
            foreach (var exchange in _awaitingResponse.Values.Concat(_awaitingAck.Values).Distinct().ToList())
                FailLocked(exchange, new ObjectDisposedException(nameof(CoapEndpoint)));
            foreach (var exchange in _inProgress.Values) exchange.AckTimer?.Dispose();
            foreach (var observation in _clientObservations.Values) completions.Add(() => observation.End());
            _clientObservations.Clear();
            foreach (var state in _peers.Values) state.FailWaiters(new ObjectDisposedException(nameof(CoapEndpoint)));
        }
        foreach (var complete in completions) complete();
        _stopping.Cancel();
        if (_ownsTransport) await _transport.DisposeAsync().ConfigureAwait(false);
        _stopping.Dispose();
    }

    /// <inheritdoc />
    void IDatagramReceiver.OnDatagram(ICoapPeer peer, ReadOnlyMemory<byte> datagram)
    {
        if (!CoapMessageCodec.TryDecode(datagram.Span, out var message, out var error))
        {
            // RFC 7252 section 4.2 and 4.3: reject a malformed confirmable message with a Reset;
            // anything else malformed is silently ignored.
            if (error != CoapDecodeError.UnsupportedVersion &&
                CoapMessageCodec.TryReadHeader(datagram.Span, out var type, out var messageId) &&
                type == CoapMessageType.Confirmable)
            {
                lock (_gate) SendResetLocked(peer, messageId);
            }
            _logger.LogDebug("Dropped malformed datagram from {Peer}: {Error}", peer, error);
            return;
        }

        lock (_gate)
        {
            if (_disposed) return;
            Touch(peer);
        }

        var code = message.Code;
        if (code.IsEmpty)
        {
            OnEmpty(peer, message);
        }
        else if (code.IsRequest)
        {
            if (message.Type is CoapMessageType.Confirmable or CoapMessageType.NonConfirmable)
                OnRequest(peer, message);
        }
        else if (code.IsResponse)
        {
            if (message.Type != CoapMessageType.Reset)
                OnResponse(peer, message);
        }
        else if (message.Type == CoapMessageType.Confirmable)
        {
            // Reserved classes 1, 3, 6 and 7 are a format error.
            lock (_gate) SendResetLocked(peer, message.MessageId);
        }
    }

    /// <inheritdoc />
    void IDatagramReceiver.OnPeerClosed(ICoapPeer peer)
    {
        List<Action> after = [];
        lock (_gate)
        {
            if (_disposed) return;
            var closed = new CoapPeerClosedException($"The session with {peer} closed.");
            foreach (var exchange in _awaitingResponse.Values.Concat(_awaitingAck.Values).Where(e => e.Peer.Equals(peer)).Distinct().ToList())
                FailLocked(exchange, closed);
            foreach (var key in _clientObservations.Keys.Where(k => k.Peer.Equals(peer)).ToList())
            {
                var observation = _clientObservations[key];
                _clientObservations.Remove(key);
                observation.Active = false;
                after.Add(() => observation.End());
            }
            foreach (var key in _serverObservations.Keys.Where(k => k.Peer.Equals(peer)).ToList())
                RemoveServerObservationLocked(key);
            foreach (var key in _block1In.Keys.Where(k => k.Peer.Equals(peer)).ToList()) _block1In.Remove(key);
            foreach (var key in _block2Out.Keys.Where(k => k.Peer.Equals(peer)).ToList()) _block2Out.Remove(key);
            _dedup.RemoveWhere(k => k.Peer.Equals(peer));
            if (_peers.Remove(peer, out var state))
            {
                state.FailWaiters(closed);
                state.Abort();
            }
        }
        foreach (var action in after) action();
        Raise(PeerClosed, peer);
    }

    private void OnEmpty(ICoapPeer peer, CoapMessage message)
    {
        lock (_gate)
        {
            switch (message.Type)
            {
                case CoapMessageType.Confirmable:
                    // CoAP ping (RFC 7252 section 4.3): answer with a Reset.
                    SendResetLocked(peer, message.MessageId);
                    break;
                case CoapMessageType.Acknowledgement:
                    OnEmptyAckLocked(peer, message.MessageId);
                    break;
                case CoapMessageType.Reset:
                    OnResetLocked(peer, message.MessageId);
                    break;
            }
        }
    }

    private void OnEmptyAckLocked(ICoapPeer peer, ushort messageId)
    {
        if (!_awaitingAck.Remove((peer, messageId), out var exchange)) return;
        exchange.Acknowledged = true;
        switch (exchange.Kind)
        {
            case OutboundKind.Request:
                // The response will follow separately (RFC 7252 section 5.2.2).
                exchange.Timer?.Change(_options.EffectiveResponseTimeout, Timeout.InfiniteTimeSpan);
                break;
            case OutboundKind.Ping:
                CompleteLocked(exchange, new CoapMessage { Type = CoapMessageType.Acknowledgement, MessageId = messageId });
                break;
            default:
                FinishLocked(exchange);
                if (exchange.Observation is { } observation && ReferenceEquals(observation.InFlight, exchange))
                    observation.InFlight = null;
                break;
        }
    }

    private void OnResetLocked(ICoapPeer peer, ushort messageId)
    {
        if (_awaitingAck.Remove((peer, messageId), out var exchange))
        {
            switch (exchange.Kind)
            {
                case OutboundKind.Request:
                    FailLocked(exchange, new CoapResetException($"{peer} reset the request with message id {messageId}."));
                    break;
                case OutboundKind.Ping:
                    CompleteLocked(exchange, new CoapMessage { Type = CoapMessageType.Reset, MessageId = messageId });
                    break;
                case OutboundKind.Notification:
                    FinishLocked(exchange);
                    if (exchange.Observation is { } observation)
                        RemoveServerObservationLocked((peer, TokenKey.From(observation.Token)));
                    break;
                default:
                    FinishLocked(exchange);
                    break;
            }
            return;
        }

        // RFC 7641 section 3.6: a Reset in reply to a non-confirmable notification ends the observation.
        if (_nonNotifications.Remove((peer, messageId), out var relation))
            RemoveServerObservationLocked((peer, TokenKey.From(relation.Token)));
    }

    private void Touch(ICoapPeer peer) => PeerLocked(peer).LastActivity = _time.GetUtcNow();

    private PeerState PeerLocked(ICoapPeer peer)
    {
        if (!_peers.TryGetValue(peer, out var state))
        {
            state = new PeerState(_time.GetUtcNow());
            _peers.Add(peer, state);
        }
        return state;
    }

    private void Housekeep()
    {
        lock (_gate)
        {
            if (_disposed) return;
            var now = _time.GetUtcNow();
            _dedup.Purge(now);
            foreach (var key in _block1In.Where(e => e.Value.ExpiresAt <= now).Select(e => e.Key).ToList())
            {
                _block1In.Remove(key);
                UntrackTransferLocked(key.Peer, Block1Kind, key.RequestKey);
            }
            foreach (var key in _block2Out.Where(e => e.Value.ExpiresAt <= now).Select(e => e.Key).ToList())
            {
                _block2Out.Remove(key);
                UntrackTransferLocked(key.Peer, Block2Kind, key.RequestKey);
            }

            var idleBefore = now - _options.Transmission.ExchangeLifetime;
            foreach (var (peer, state) in _peers.Where(p => p.Value.IsIdle && p.Value.LastActivity < idleBefore).ToList())
            {
                if (HasStateFor(peer)) continue;
                _peers.Remove(peer);
                state.Abort();
            }
        }
    }

    /// <summary>Sizes of the internal tables, for tests and diagnostics.</summary>
    internal (int Deduplication, int Peers, int AwaitingAck, int AwaitingResponse, int InProgress, int Block1, int Block2, int ServerObservations, int ClientObservations) DiagnosticCounts()
    {
        lock (_gate)
        {
            return (_dedup.Count, _peers.Count, _awaitingAck.Count, _awaitingResponse.Count, _inProgress.Count,
                _block1In.Count, _block2Out.Count, _serverObservations.Count, _clientObservations.Count);
        }
    }

    private bool HasStateFor(ICoapPeer peer) =>
        _serverObservations.Keys.Any(k => k.Peer.Equals(peer)) ||
        _clientObservations.Keys.Any(k => k.Peer.Equals(peer)) ||
        _awaitingResponse.Keys.Any(k => k.Peer.Equals(peer)) ||
        _awaitingAck.Keys.Any(k => k.Peer.Equals(peer));

    // ---- Sending ----

    private bool SendLocked(ICoapPeer peer, byte[] bytes)
    {
        try
        {
            var pending = _transport.SendAsync(peer, bytes, CancellationToken.None);
            if (!pending.IsCompletedSuccessfully) _ = ObserveSendAsync(pending, peer);
            return true;
        }
        catch (Exception e)
        {
            _logger.LogWarning(e, "Send to {Peer} failed", peer);
            return false;
        }
    }

    private async Task ObserveSendAsync(ValueTask pending, ICoapPeer peer)
    {
        try { await pending.ConfigureAwait(false); }
        catch (Exception e) { _logger.LogWarning(e, "Send to {Peer} failed", peer); }
    }

    private void SendResetLocked(ICoapPeer peer, ushort messageId)
    {
        var reset = new CoapMessage { Type = CoapMessageType.Reset, Code = CoapCode.Empty, MessageId = messageId };
        SendLocked(peer, reset.Encode());
    }

    private byte[] SendEmptyAckLocked(ICoapPeer peer, ushort messageId)
    {
        var ack = new CoapMessage { Type = CoapMessageType.Acknowledgement, Code = CoapCode.Empty, MessageId = messageId }.Encode();
        SendLocked(peer, ack);
        return ack;
    }

    /// <summary>Starts tracking an outbound confirmable or non-confirmable message and sends it.</summary>
    private OutboundExchange StartOutboundLocked(
        OutboundKind kind,
        ICoapPeer peer,
        CoapMessage message,
        RetransmissionState? continueFrom = null,
        TaskCompletionSource<CoapMessage>? completion = null,
        ServerObservation? observation = null)
    {
        var state = PeerLocked(peer);
        message.MessageId = state.MessageIds.Next();
        var bytes = message.Encode();
        if (bytes.Length > _transport.MaxMessageSize)
            throw new CoapException($"Message of {bytes.Length} bytes exceeds the transport limit of {_transport.MaxMessageSize}.");

        var exchange = new OutboundExchange(kind, peer, message, bytes) { Completion = completion, Observation = observation };
        var now = _time.GetUtcNow();
        if (message.Type == CoapMessageType.Confirmable)
        {
            exchange.Retransmission = continueFrom ?? new RetransmissionState(_options.Transmission, now, _random);
            _awaitingAck[(peer, message.MessageId)] = exchange;
            exchange.Timer = _time.CreateTimer(OnExchangeTimer, exchange, Max(exchange.Retransmission.NextDeadline - now, TimeSpan.Zero), Timeout.InfiniteTimeSpan);
        }
        else if (kind == OutboundKind.Request)
        {
            _awaitingAck[(peer, message.MessageId)] = exchange;
            exchange.Timer = _time.CreateTimer(OnExchangeTimer, exchange, _options.EffectiveResponseTimeout, Timeout.InfiniteTimeSpan);
        }

        if (kind == OutboundKind.Request)
            _awaitingResponse[(peer, TokenKey.From(message.Token))] = exchange;

        if (!SendLocked(peer, bytes))
        {
            FailLocked(exchange, new CoapException($"Could not send to {peer}."));
        }
        return exchange;
    }

    private void OnExchangeTimer(object? state)
    {
        var exchange = (OutboundExchange)state!;
        lock (_gate)
        {
            if (exchange.Done || _disposed) return;
            var now = _time.GetUtcNow();
            if (exchange.Acknowledged || exchange.Retransmission is null)
            {
                FailLocked(exchange, new CoapTimeoutException($"No response from {exchange.Peer} within {_options.EffectiveResponseTimeout}."));
                return;
            }

            switch (exchange.Retransmission.Next(now))
            {
                case RetransmissionAction.Wait:
                    exchange.Timer?.Change(Max(exchange.Retransmission.NextDeadline - now, TimeSpan.Zero), Timeout.InfiniteTimeSpan);
                    break;
                case RetransmissionAction.Retransmit:
                    SendLocked(exchange.Peer, exchange.Bytes);
                    exchange.Timer?.Change(exchange.Retransmission.Interval, Timeout.InfiniteTimeSpan);
                    break;
                case RetransmissionAction.GiveUp:
                    var observation = exchange.Observation;
                    FailLocked(exchange, new CoapTimeoutException(
                        $"{exchange.Peer} did not acknowledge message id {exchange.Message.MessageId} after {exchange.Retransmission.Transmissions} transmissions."));
                    if (exchange.Kind == OutboundKind.Notification && observation is not null)
                    {
                        // RFC 7641 section 4.5: an unacknowledged confirmable notification removes the observer.
                        RemoveServerObservationLocked((exchange.Peer, TokenKey.From(observation.Token)));
                    }
                    break;
            }
        }
    }

    private void FinishLocked(OutboundExchange exchange)
    {
        if (exchange.Done) return;
        exchange.Done = true;
        exchange.Timer?.Dispose();
        exchange.Cancellation.Unregister();
        var ackKey = (exchange.Peer, exchange.Message.MessageId);
        if (_awaitingAck.TryGetValue(ackKey, out var a) && ReferenceEquals(a, exchange)) _awaitingAck.Remove(ackKey);
        if (exchange.Kind == OutboundKind.Request)
        {
            var tokenKey = (exchange.Peer, TokenKey.From(exchange.Message.Token));
            if (_awaitingResponse.TryGetValue(tokenKey, out var r) && ReferenceEquals(r, exchange)) _awaitingResponse.Remove(tokenKey);
        }
    }

    private void CompleteLocked(OutboundExchange exchange, CoapMessage response)
    {
        FinishLocked(exchange);
        exchange.Completion?.TrySetResult(response);
    }

    private void FailLocked(OutboundExchange exchange, Exception error)
    {
        FinishLocked(exchange);
        if (exchange.Observation is { } observation && ReferenceEquals(observation.InFlight, exchange))
            observation.InFlight = null;
        exchange.Completion?.TrySetException(error);
    }

    private static TimeSpan Max(TimeSpan a, TimeSpan b) => a > b ? a : b;

    private static void Raise<T>(Action<T>? handler, T argument)
    {
        if (handler is null) return;
        ThreadPool.QueueUserWorkItem(static state =>
        {
            var (h, arg) = ((Action<T>, T))state!;
            h(arg);
        }, (handler, argument));
    }

    /// <summary>Picks the largest block size exponent, up to the preferred one, at which <paramref name="message"/> plus one block fits the transport.</summary>
    private int FitSizeExponent(CoapMessage message, int preferred)
    {
        var probe = message.Clone();
        probe.Payload = ReadOnlyMemory<byte>.Empty;
        probe.Token = new byte[8];
        probe.Block1 = new BlockOption(BlockOption.MaxNumber, true, 6);
        probe.Block2 = new BlockOption(BlockOption.MaxNumber, true, 6);
        probe.Size1 = uint.MaxValue;
        probe.Size2 = uint.MaxValue;
        probe.Observe = ObserveSequence.Modulus - 1;
        int overhead = probe.Encode().Length + 1;
        int szx = preferred;
        while (szx > 0 && overhead + BlockOption.SizeOf(szx) > _transport.MaxMessageSize) szx--;
        return szx;
    }

    private int PreferredExponent => BlockOption.ExponentOf(_options.PreferredBlockSize);

    // ---- Internal state types ----

    internal enum OutboundKind
    {
        Request,
        Ping,
        SeparateResponse,
        Notification,
    }

    internal sealed class OutboundExchange(OutboundKind kind, ICoapPeer peer, CoapMessage message, byte[] bytes)
    {
        public OutboundKind Kind { get; } = kind;
        public ICoapPeer Peer { get; } = peer;
        public CoapMessage Message { get; } = message;
        public byte[] Bytes { get; } = bytes;
        public RetransmissionState? Retransmission { get; set; }
        public ITimer? Timer { get; set; }
        public TaskCompletionSource<CoapMessage>? Completion { get; set; }
        public CancellationTokenRegistration Cancellation { get; set; }
        public ServerObservation? Observation { get; set; }
        public bool Acknowledged { get; set; }
        public bool Done { get; set; }
    }

    private sealed class PeerState(DateTimeOffset now)
    {
        private CancellationTokenSource? _aborted;

        public MessageIdAllocator MessageIds { get; } = new();
        public DateTimeOffset LastActivity { get; set; } = now;
        public int ActiveInteractions { get; set; }
        public LinkedList<TaskCompletionSource> Waiters { get; } = new();
        public int HandlersRunning { get; set; }
        public int Observations { get; set; }
        public LinkedList<(int Kind, string Key)> BlockTransfers { get; } = new();

        public bool IsIdle => ActiveInteractions == 0 && Waiters.Count == 0 && HandlersRunning == 0 && Observations == 0;

        public CancellationToken AbortToken(CancellationToken stopping) =>
            (_aborted ??= CancellationTokenSource.CreateLinkedTokenSource(stopping)).Token;

        public void Abort()
        {
            _aborted?.Cancel();
            _aborted?.Dispose();
            _aborted = null;
        }

        public void FailWaiters(Exception error)
        {
            foreach (var waiter in Waiters) waiter.TrySetException(error);
            Waiters.Clear();
        }
    }

    private sealed class ServerExchange(ICoapPeer peer, CoapMessage request, CoapMessage dispatched, ObserveAction observe)
    {
        public ICoapPeer Peer { get; } = peer;
        public CoapMessage Request { get; } = request;
        public CoapMessage Dispatched { get; } = dispatched;
        public ObserveAction Observe { get; } = observe;
        public BlockOption? FinalBlock1 { get; set; }
        public ITimer? AckTimer { get; set; }
        public bool AckSent { get; set; }
        public bool Done { get; set; }
    }

    private sealed class Block1Transfer(BlockReceiver receiver, DateTimeOffset expiresAt)
    {
        public BlockReceiver Receiver { get; } = receiver;
        public DateTimeOffset ExpiresAt { get; set; } = expiresAt;
    }

    private sealed class Block2Transfer(CoapMessage response, DateTimeOffset expiresAt)
    {
        public CoapMessage Response { get; } = response;
        public DateTimeOffset ExpiresAt { get; set; } = expiresAt;
    }
}

/// <summary>A token packed into a value for use as a dictionary key.</summary>
internal readonly record struct TokenKey(ulong Bits, int Length)
{
    public static TokenKey From(ReadOnlySpan<byte> token)
    {
        ulong bits = 0;
        foreach (var b in token) bits = (bits << 8) | b;
        return new TokenKey(bits, token.Length);
    }
}

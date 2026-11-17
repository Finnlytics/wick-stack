using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;
using Wick.Coap.Transport;

namespace Wick.Coap.Dtls;

/// <summary>
/// CoAP over DTLS 1.2 (RFC 6347), server side, with pre-shared keys (RFC 4279) and optional
/// Connection ID (RFC 9146). One UDP socket carries every session. Datagrams are routed to a
/// session by connection id when the record carries one and by source address otherwise;
/// unknown peers must first complete the stateless cookie exchange (RFC 6347 section 4.2.1).
/// </summary>
/// <remarks>
/// Each handshake runs on a dedicated thread because BouncyCastle's handshake is blocking;
/// <see cref="DtlsServerOptions.MaxConcurrentHandshakes"/> bounds how many. An established
/// session holds no thread. Sessions are dropped after
/// <see cref="DtlsServerOptions.SessionIdleTimeout"/> of silence, and the least recently active
/// one is dropped when <see cref="DtlsServerOptions.MaxSessions"/> is reached.
/// </remarks>
public sealed class DtlsServerTransport : IDatagramTransport
{
    private const byte ContentTypeHandshake = 22;
    private const byte ContentTypeTls12Cid = 25;
    private const byte HandshakeTypeClientHello = 1;
    private const int RecordHeaderLength = 13;
    private const int CidOffset = 11;

    private readonly IPskStore _pskStore;
    private readonly BcTlsCrypto _crypto = new(new SecureRandom());
    private readonly DtlsVerifier _verifier;
    private readonly ConcurrentDictionary<IPEndPoint, DtlsSession> _byAddress = new();
    private readonly ConcurrentDictionary<UInt128, DtlsSession> _byCid = new();
    private readonly SemaphoreSlim _handshakeSlots;
    private readonly CancellationTokenSource _stopping = new();
    private Socket? _socket;
    private IDatagramReceiver? _receiver;
    private Task? _receiveLoop;
    private Timer? _housekeeping;

    /// <summary>Creates the transport. It binds when started.</summary>
    /// <param name="options">Settings.</param>
    /// <param name="pskStore">Where pre-shared keys come from.</param>
    /// <param name="logger">An optional logger.</param>
    public DtlsServerTransport(DtlsServerOptions options, IPskStore pskStore, ILogger<DtlsServerTransport>? logger = null)
    {
        Options = options ?? throw new ArgumentNullException(nameof(options));
        Options.Validate();
        _pskStore = pskStore ?? throw new ArgumentNullException(nameof(pskStore));
        Logger = (ILogger?)logger ?? NullLogger.Instance;
        _verifier = new DtlsVerifier(_crypto);
        _handshakeSlots = new SemaphoreSlim(Options.MaxConcurrentHandshakes, Options.MaxConcurrentHandshakes);
    }

    /// <summary>The transport's settings.</summary>
    public DtlsServerOptions Options { get; }

    /// <inheritdoc />
    public string Scheme => "coaps";

    /// <inheritdoc />
    public EndPoint LocalEndPoint => _socket?.LocalEndPoint ?? Options.LocalEndPoint;

    /// <summary>
    /// The largest CoAP message that fits one record within <see cref="DtlsServerOptions.MaxDatagramSize"/>,
    /// allowing for the record header, the connection id and the worst-case cipher overhead.
    /// </summary>
    public int MaxMessageSize => Options.MaxDatagramSize - RecordHeaderLength - Options.ConnectionIdLength - 1 - 64;

    /// <summary>The number of sessions, handshaking or established.</summary>
    public int SessionCount => _byAddress.Values.Concat(_byCid.Values).Distinct().Count();

    /// <summary>Raised, on the thread pool, when a handshake completes.</summary>
    public event Action<DtlsSession>? SessionEstablished;

    /// <summary>Raised, on the thread pool, when a peer's address changes on an authenticated record carrying the connection id.</summary>
    public event Action<DtlsSession, IPEndPoint, IPEndPoint>? PeerAddressChanged;

    internal ILogger Logger { get; }

    internal int ReceiveLimit => 65507;

    /// <summary>Returns a snapshot of the sessions.</summary>
    /// <returns>The sessions.</returns>
    public IReadOnlyList<DtlsSession> GetSessions() => [.. _byAddress.Values.Concat(_byCid.Values).Distinct()];

    /// <inheritdoc />
    public Task StartAsync(IDatagramReceiver receiver, CancellationToken cancellationToken = default)
    {
        _receiver = receiver ?? throw new ArgumentNullException(nameof(receiver));
        if (_socket is not null) throw new InvalidOperationException("The transport is already started.");
        var bind = Options.LocalEndPoint;
        var socket = new Socket(bind.AddressFamily, SocketType.Dgram, ProtocolType.Udp);
        if (bind.AddressFamily == AddressFamily.InterNetworkV6 && bind.Address.Equals(IPAddress.IPv6Any)) socket.DualMode = true;
        socket.Bind(bind);
        _socket = socket;
        _receiveLoop = Task.Run(() => ReceiveLoopAsync(socket, _stopping.Token), CancellationToken.None);
        _housekeeping = new Timer(_ => Housekeep(), null, Options.HousekeepingInterval, Options.HousekeepingInterval);
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public ValueTask SendAsync(ICoapPeer peer, ReadOnlyMemory<byte> datagram, CancellationToken cancellationToken = default)
    {
        if (peer is not DtlsSession session) throw new ArgumentException("The peer is not a session of this transport.", nameof(peer));
        session.Send(datagram.Span);
        return ValueTask.CompletedTask;
    }

    /// <inheritdoc />
    public bool TryGetPeer(EndPoint remoteEndPoint, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out ICoapPeer? peer)
    {
        if (remoteEndPoint is IPEndPoint address && _byAddress.TryGetValue(address, out var session) && session.State == DtlsSessionState.Established)
        {
            peer = session;
            return true;
        }
        peer = null;
        return false;
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        _stopping.Cancel();
        _housekeeping?.Dispose();
        _socket?.Dispose();
        foreach (var session in GetSessions()) Close(session, notify: false);
        if (_receiveLoop is not null)
        {
            try { await _receiveLoop.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        _stopping.Dispose();
    }

    private async Task ReceiveLoopAsync(Socket socket, CancellationToken stopping)
    {
        var buffer = new byte[ReceiveLimit];
        EndPoint any = socket.AddressFamily == AddressFamily.InterNetworkV6 ? new IPEndPoint(IPAddress.IPv6Any, 0) : new IPEndPoint(IPAddress.Any, 0);
        while (!stopping.IsCancellationRequested)
        {
            SocketReceiveFromResult result;
            try
            {
                result = await socket.ReceiveFromAsync(buffer, SocketFlags.None, any, stopping).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException e)
            {
                if (stopping.IsCancellationRequested) break;
                if (e.SocketErrorCode is not (SocketError.ConnectionReset or SocketError.MessageSize))
                    Logger.LogWarning(e, "DTLS socket receive failed");
                continue;
            }

            try
            {
                Route(buffer.AsSpan(0, result.ReceivedBytes).ToArray(), (IPEndPoint)result.RemoteEndPoint);
            }
            catch (Exception e)
            {
                Logger.LogError(e, "Failed to process a datagram from {Remote}", result.RemoteEndPoint);
            }
        }
    }

    private void Route(byte[] data, IPEndPoint source)
    {
        if (data.Length < RecordHeaderLength) return;
        int cidLength = Options.ConnectionIdLength;

        if (data[0] == ContentTypeTls12Cid)
        {
            // RFC 9146: the connection id follows the sequence number. Unknown ids are dropped.
            if (cidLength > 0 && data.Length >= CidOffset + cidLength &&
                _byCid.TryGetValue(CidKey(data.AsSpan(CidOffset, cidLength)), out var byCid))
            {
                byCid.OnDatagram(data, source);
            }
            return;
        }

        bool isClientHello = data[0] == ContentTypeHandshake && data[3] == 0 && data[4] == 0 &&
                             data.Length > RecordHeaderLength && data[RecordHeaderLength] == HandshakeTypeClientHello;

        if (_byAddress.TryGetValue(source, out var session))
        {
            // A fresh ClientHello at an established session's address means the peer lost its
            // state (RFC 6347 section 4.2.8); anything else belongs to that session.
            if (!(isClientHello && session.State == DtlsSessionState.Established))
            {
                session.OnDatagram(data, source);
                return;
            }
        }

        if (isClientHello) Accept(data, source);
    }

    private void Accept(byte[] data, IPEndPoint source)
    {
        var socket = _socket;
        if (socket is null) return;
        byte[] clientId = [.. source.Address.GetAddressBytes(), (byte)(source.Port >> 8), (byte)source.Port];
        var request = _verifier.VerifyRequest(clientId, data, 0, data.Length, new CookieReplySender(this, source));
        if (request is null) return; // HelloVerifyRequest sent, or the ClientHello was invalid.

        if (!_handshakeSlots.Wait(0))
        {
            Logger.LogWarning("Dropping a ClientHello from {Remote}: {Limit} handshakes already in progress", source, Options.MaxConcurrentHandshakes);
            return;
        }

        try
        {
            MakeRoomForSession();
            var session = new DtlsSession(this, source, Options.HandshakeQueueLength);
            if (_byAddress.TryGetValue(source, out var previous)) session.Replaces = previous;
            _byAddress[source] = session;
            var server = new WickPskTlsServer(_crypto, new StorePskIdentityManager(_pskStore, Options, session), this, session);
            var thread = new Thread(() =>
            {
                try { session.RunHandshake(request, server); }
                finally { _handshakeSlots.Release(); }
            }, 256 * 1024)
            {
                IsBackground = true,
                Name = "dtls-handshake",
            };
            thread.Start();
        }
        catch
        {
            _handshakeSlots.Release();
            throw;
        }
    }

    internal byte[] AllocateConnectionId(DtlsSession session)
    {
        var cid = new byte[Options.ConnectionIdLength];
        while (true)
        {
            _crypto.SecureRandom.NextBytes(cid);
            if (_byCid.TryAdd(CidKey(cid), session))
            {
                session.ConnectionId = (byte[])cid.Clone();
                return cid;
            }
        }
    }

    internal void OnEstablished(DtlsSession session)
    {
        if (session.Replaces is { } previous && !ReferenceEquals(previous, session))
        {
            session.Replaces = null;
            Close(previous, notify: true);
        }
        Logger.LogInformation("DTLS session established with {Remote}, identity {Identity}, suite 0x{Suite:X4}, connection id {Cid}",
            session.Remote, session.PskIdentity, session.Security?.CipherSuite, session.ConnectionId is null ? "none" : Convert.ToHexString(session.ConnectionId));
        Raise(() => SessionEstablished?.Invoke(session));
    }

    internal void OnHandshakeFailed(DtlsSession session)
    {
        Close(session, notify: false);
        // A failed attempt must not orphan the session it would have replaced.
        if (session.Replaces is { State: DtlsSessionState.Established } previous)
            _byAddress.TryAdd(previous.Remote, previous);
        session.Replaces = null;
    }

    internal void OnAddressChanged(DtlsSession session, IPEndPoint previous, IPEndPoint current)
    {
        _byAddress.TryRemove(new KeyValuePair<IPEndPoint, DtlsSession>(previous, session));
        if (_byAddress.TryGetValue(current, out var occupant) && !ReferenceEquals(occupant, session) && occupant.State != DtlsSessionState.Handshaking)
        {
            // Another session claimed this address earlier; the authenticated record shows it is stale.
            _byAddress[current] = session;
            Close(occupant, notify: true);
        }
        else
        {
            _byAddress[current] = session;
        }
        Logger.LogInformation("DTLS peer {Identity} moved from {Previous} to {Current}", session.PskIdentity, previous, current);
        Raise(() => PeerAddressChanged?.Invoke(session, previous, current));
    }

    internal void Deliver(DtlsSession session, byte[] plaintext)
    {
        try
        {
            _receiver?.OnDatagram(session, plaintext);
        }
        catch (Exception e)
        {
            Logger.LogError(e, "Receiver failed on a datagram from {Remote}", session.Remote);
        }
    }

    internal void Close(DtlsSession session, bool notify)
    {
        bool wasEstablished = session.State == DtlsSessionState.Established;
        if (!session.MarkClosed()) return;
        _byAddress.TryRemove(new KeyValuePair<IPEndPoint, DtlsSession>(session.Remote, session));
        if (session.ConnectionId is { } cid) _byCid.TryRemove(new KeyValuePair<UInt128, DtlsSession>(CidKey(cid), session));
        if (notify && wasEstablished)
        {
            try { _receiver?.OnPeerClosed(session); }
            catch (Exception e) { Logger.LogError(e, "Receiver failed on the close of {Remote}", session.Remote); }
        }
    }

    internal void SendRaw(ReadOnlySpan<byte> datagram, IPEndPoint to)
    {
        var socket = _socket ?? throw new IOException("The transport is not started.");
        socket.SendTo(datagram, SocketFlags.None, to);
    }

    private void MakeRoomForSession()
    {
        var sessions = GetSessions();
        if (sessions.Count < Options.MaxSessions) return;
        var oldest = sessions.Where(s => s.State == DtlsSessionState.Established).MinBy(s => s.LastActivity);
        if (oldest is not null) Close(oldest, notify: true);
    }

    private void Housekeep()
    {
        var cutoff = DateTimeOffset.UtcNow - Options.SessionIdleTimeout;
        foreach (var session in GetSessions())
        {
            if (session.State == DtlsSessionState.Established && session.LastActivity < cutoff)
            {
                Logger.LogInformation("Dropping DTLS session with {Remote} after {Idle} idle", session.Remote, Options.SessionIdleTimeout);
                Close(session, notify: true);
            }
        }
    }

    private static UInt128 CidKey(ReadOnlySpan<byte> cid)
    {
        UInt128 key = (UInt128)cid.Length << 120;
        for (int i = 0; i < cid.Length; i++) key |= (UInt128)cid[i] << (8 * i);
        return key;
    }

    private static void Raise(Action action) => ThreadPool.QueueUserWorkItem(static a => ((Action)a!)(), action);

    private sealed class CookieReplySender(DtlsServerTransport owner, IPEndPoint to) : DatagramSender
    {
        public int GetSendLimit() => owner.Options.MaxDatagramSize;

        public void Send(byte[] buf, int off, int len) => owner.SendRaw(buf.AsSpan(off, len), to);

        public void Send(ReadOnlySpan<byte> buffer) => owner.SendRaw(buffer, to);
    }
}

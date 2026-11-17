using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Microsoft.Extensions.Logging;
using Org.BouncyCastle.Tls;
using Wick.Coap.Transport;

namespace Wick.Coap.Dtls;

/// <summary>The lifecycle of a <see cref="DtlsSession"/>.</summary>
public enum DtlsSessionState
{
    /// <summary>The handshake is running.</summary>
    Handshaking,

    /// <summary>The handshake completed; application data flows.</summary>
    Established,

    /// <summary>The session has ended.</summary>
    Closed,
}

/// <summary>
/// One DTLS 1.2 session on a <see cref="DtlsServerTransport"/>, and the CoAP peer it carries.
/// The session object is the peer's identity: it stays the same when a peer using a
/// connection id (RFC 9146) moves to a new address, so state the endpoint keys by it survives.
/// </summary>
/// <remarks>
/// The handshake runs on a dedicated thread, because BouncyCastle's handshake is blocking.
/// Once established, the session holds no thread: each inbound datagram is decrypted on the
/// transport's receive path and each send is encrypted on the caller's.
/// </remarks>
public sealed class DtlsSession : ICoapPeer
{
    private readonly DtlsServerTransport _owner;
    private readonly Lock _lock = new();
    private readonly BlockingCollection<(byte[] Data, IPEndPoint Source)> _handshakeInbox;
    private readonly SessionDatagramTransport _datagrams;
    private volatile IPEndPoint _remote;
    private DtlsTransport? _dtls;
    private byte[]? _pskIdentity;
    private long _lastActivityTicks;

    internal DtlsSession(DtlsServerTransport owner, IPEndPoint remote, int queueLength)
    {
        _owner = owner;
        _remote = remote;
        _handshakeInbox = new BlockingCollection<(byte[], IPEndPoint)>(queueLength);
        _datagrams = new SessionDatagramTransport(this);
        StartedAt = DateTimeOffset.UtcNow;
        Touch();
    }

    /// <summary>The address records to this peer are sent to. Moves only after a newer authenticated record carrying the connection id arrives from a new address.</summary>
    public EndPoint RemoteEndPoint => _remote;

    /// <summary>Security details, available once established.</summary>
    public CoapPeerSecurity? Security { get; private set; }

    /// <summary>The session's state.</summary>
    public DtlsSessionState State { get; private set; } = DtlsSessionState.Handshaking;

    /// <summary>The PSK identity the peer authenticated with, once established.</summary>
    public string? PskIdentity => Security?.PskIdentity;

    /// <summary>The connection id this server issued, which the peer puts on its records, or null when none.</summary>
    public byte[]? ConnectionId { get; internal set; }

    /// <summary>When the handshake started.</summary>
    public DateTimeOffset StartedAt { get; }

    /// <summary>When the handshake completed, or null.</summary>
    public DateTimeOffset? EstablishedAt { get; private set; }

    /// <summary>When the last datagram arrived for this session.</summary>
    public DateTimeOffset LastActivity => new(Interlocked.Read(ref _lastActivityTicks), TimeSpan.Zero);

    internal DtlsSession? Replaces { get; set; }

    internal IPEndPoint Remote => _remote;

    /// <summary>Formats the session for diagnostics.</summary>
    /// <returns>Address, identity and state.</returns>
    public override string ToString() => $"dtls {_remote} identity={PskIdentity ?? "?"} {State}";

    internal void Touch() => Interlocked.Exchange(ref _lastActivityTicks, DateTimeOffset.UtcNow.UtcTicks);

    internal void RunHandshake(DtlsRequest request, WickPskTlsServer server)
    {
        List<(byte[] Data, IPEndPoint Source)> backlog = [];
        try
        {
            var dtls = new DtlsServerProtocol().Accept(server, _datagrams, request);
            lock (_lock)
            {
                if (State == DtlsSessionState.Closed) return;
                _dtls = dtls;
                var parameters = server.CompletedParameters!;
                Security = new CoapPeerSecurity(
                    "DTLS 1.2",
                    _pskIdentity is null ? null : Encoding.UTF8.GetString(_pskIdentity),
                    _pskIdentity,
                    parameters.CipherSuite,
                    parameters.IsExtendedMasterSecret,
                    parameters.ConnectionIDPeer is { Length: > 0 } cid ? cid : null);
                EstablishedAt = DateTimeOffset.UtcNow;
                State = DtlsSessionState.Established;
                while (_handshakeInbox.TryTake(out var item)) backlog.Add(item);
            }
        }
        catch (Exception e)
        {
            _owner.Logger.LogInformation("DTLS handshake with {Remote} failed: {Error}", _remote, e.Message);
            _owner.OnHandshakeFailed(this);
            return;
        }

        _owner.OnEstablished(this);
        foreach (var (data, source) in backlog) OnEstablishedDatagram(data, source);
    }

    internal void SetPskIdentity(byte[] identity) => _pskIdentity = identity;

    internal void OnDatagram(byte[] data, IPEndPoint source)
    {
        Touch();
        lock (_lock)
        {
            if (State == DtlsSessionState.Handshaking)
            {
                // The handshake thread consumes these; a full queue means the peer is flooding, so drop.
                _handshakeInbox.TryAdd((data, source));
                return;
            }
            if (State == DtlsSessionState.Closed) return;
        }
        OnEstablishedDatagram(data, source);
    }

    private void OnEstablishedDatagram(byte[] data, IPEndPoint source)
    {
        List<byte[]> plaintexts = [];
        bool failed = false;
        lock (_lock)
        {
            if (State != DtlsSessionState.Established || _dtls is null) return;
            _datagrams.Current = data;
            _datagrams.CurrentSource = source;
            try
            {
                var buffer = new byte[_dtls.GetReceiveLimit()];
                // A wait of 1 ms: the datagram is already queued, and zero would mean wait forever.
                int received = _dtls.Receive(buffer, 0, buffer.Length, 1, OnRecord);
                while (received >= 0)
                {
                    if (received > 0) plaintexts.Add(buffer.AsSpan(0, received).ToArray());
                    received = _dtls.ReceivePending(buffer, 0, buffer.Length, OnRecord);
                }
            }
            catch (Exception e) when (e is IOException or TlsException or SocketException or InvalidOperationException)
            {
                _owner.Logger.LogInformation("DTLS session with {Remote} ended: {Error}", _remote, e.Message);
                failed = true;
            }
            finally
            {
                _datagrams.Current = null;
            }
            if (_datagrams.Closed) failed = true;
        }

        foreach (var plaintext in plaintexts) _owner.Deliver(this, plaintext);
        if (failed) _owner.Close(this, notify: true);
    }

    /// <summary>
    /// Called by BouncyCastle for each record that passed authentication. RFC 9146 section 6:
    /// move the peer address only for a record that carries the connection id and is newer than
    /// any seen so far.
    /// </summary>
    private void OnRecord(DtlsRecordFlags flags)
    {
        var source = _datagrams.CurrentSource;
        if (source is null) return;
        if ((flags & DtlsRecordFlags.IsNewest) == 0 || (flags & DtlsRecordFlags.UsesConnectionID) == 0) return;
        if (source.Equals(_remote)) return;
        var previous = _remote;
        _remote = source;
        _owner.OnAddressChanged(this, previous, source);
    }

    internal void Send(ReadOnlySpan<byte> datagram)
    {
        bool failed = false;
        lock (_lock)
        {
            if (State != DtlsSessionState.Established || _dtls is null)
                throw new CoapPeerClosedException($"The DTLS session with {_remote} is not established.");
            if (datagram.Length > _dtls.GetSendLimit())
                throw new ArgumentException($"Message of {datagram.Length} bytes exceeds the DTLS send limit of {_dtls.GetSendLimit()}.", nameof(datagram));
            try
            {
                _dtls.Send(datagram);
            }
            catch (Exception e) when (e is IOException or TlsException or SocketException)
            {
                _owner.Logger.LogInformation("DTLS send to {Remote} failed: {Error}", _remote, e.Message);
                failed = true;
            }
        }
        if (failed)
        {
            // The caller may hold the endpoint's lock, so report the closure from another thread.
            ThreadPool.QueueUserWorkItem(static s => s._owner.Close(s, notify: true), this, preferLocal: false);
            throw new CoapPeerClosedException($"The DTLS session with {_remote} failed.");
        }
    }

    /// <summary>Marks the session closed. Returns false when it already was.</summary>
    internal bool MarkClosed()
    {
        lock (_lock)
        {
            if (State == DtlsSessionState.Closed) return false;
            State = DtlsSessionState.Closed;
            _handshakeInbox.CompleteAdding();
            return true;
        }
    }

    /// <summary>
    /// The BouncyCastle side of the session: reads come from the handshake queue while the
    /// handshake runs and from the one datagram being processed afterwards; writes go straight
    /// to the shared socket at the session's current address.
    /// </summary>
    private sealed class SessionDatagramTransport(DtlsSession session) : DatagramTransport
    {
        public byte[]? Current { get; set; }

        public IPEndPoint? CurrentSource { get; set; }

        public bool Closed { get; private set; }

        public int GetReceiveLimit() => session._owner.ReceiveLimit;

        public int GetSendLimit() => session._owner.Options.MaxDatagramSize;

        public int Receive(byte[] buf, int off, int len, int waitMillis) => Receive(buf.AsSpan(off, len), waitMillis);

        public int Receive(Span<byte> buffer, int waitMillis)
        {
            if (session.State == DtlsSessionState.Handshaking)
            {
                (byte[] Data, IPEndPoint Source) item;
                try
                {
                    if (!session._handshakeInbox.TryTake(out item, waitMillis > 0 ? waitMillis : 1000)) return -1;
                }
                catch (ObjectDisposedException) { throw new IOException("The session closed."); }
                catch (InvalidOperationException) { throw new IOException("The session closed."); }
                CurrentSource = item.Source;
                return Copy(item.Data, buffer);
            }

            // Established: hand over the datagram being processed, once, and never wait.
            var data = Current;
            if (data is null) return -1;
            Current = null;
            return Copy(data, buffer);
        }

        public void Send(byte[] buf, int off, int len) => Send(buf.AsSpan(off, len));

        public void Send(ReadOnlySpan<byte> buffer) => session._owner.SendRaw(buffer, session._remote);

        public void Close() => Closed = true;

        private static int Copy(byte[] data, Span<byte> buffer)
        {
            int n = Math.Min(data.Length, buffer.Length);
            data.AsSpan(0, n).CopyTo(buffer);
            return n;
        }
    }
}

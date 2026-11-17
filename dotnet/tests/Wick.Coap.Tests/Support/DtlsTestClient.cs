using System.Net;
using System.Net.Sockets;
using System.Text;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;

namespace Wick.Coap.Tests.Support;

/// <summary>A minimal blocking DTLS 1.2 PSK client for tests, built on BouncyCastle.</summary>
public sealed class DtlsTestClient : IDisposable
{
    private readonly Socket _socket;
    private readonly DtlsTransport _dtls;
    private ushort _nextId = 1000;

    private DtlsTestClient(Socket socket, DtlsTransport dtls, TestPskClient client)
    {
        _socket = socket;
        _dtls = dtls;
        Parameters = client.Completed!;
    }

    public SecurityParameters Parameters { get; }

    public IPEndPoint LocalEndPoint => (IPEndPoint)_socket.LocalEndPoint!;

    public static DtlsTestClient Connect(IPEndPoint server, string identity, byte[] key, int cipherSuite, byte[]? connectionId = null, bool offerExtendedMasterSecret = true)
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        socket.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        socket.Connect(server);
        var client = new TestPskClient(identity, key, cipherSuite, connectionId, offerExtendedMasterSecret);
        try
        {
            var dtls = new DtlsClientProtocol().Connect(client, new ConnectedUdp(socket));
            return new DtlsTestClient(socket, dtls, client);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    public void Send(CoapMessage message)
    {
        var bytes = message.Encode();
        _dtls.Send(bytes, 0, bytes.Length);
    }

    public CoapMessage? Receive(TimeSpan timeout)
    {
        var buffer = new byte[2048];
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            int wait = Math.Max(1, (int)(deadline - DateTime.UtcNow).TotalMilliseconds);
            int n = _dtls.Receive(buffer, 0, buffer.Length, wait);
            if (n > 0) return CoapMessage.Decode(buffer.AsSpan(0, n));
        }
        return null;
    }

    /// <summary>Sends a confirmable request and waits for the piggybacked response, answering any server request that arrives meanwhile.</summary>
    public CoapMessage? Request(CoapMessage request, TimeSpan timeout)
    {
        request.Type = CoapMessageType.Confirmable;
        request.MessageId = _nextId++;
        request.Token = [(byte)(request.MessageId >> 8), (byte)request.MessageId];
        Send(request);
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var message = Receive(deadline - DateTime.UtcNow);
            if (message is null) return null;
            if (message.IsRequest)
            {
                AnswerServerRequest(message);
                continue;
            }
            if (message.Type == CoapMessageType.Acknowledgement && message.MessageId == request.MessageId) return message;
        }
        return null;
    }

    /// <summary>Waits for a request from the server and answers it with 2.05 and the given text.</summary>
    public CoapMessage? ServeOne(string text, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var message = Receive(deadline - DateTime.UtcNow);
            if (message is null) return null;
            if (message.IsRequest)
            {
                AnswerServerRequest(message, text);
                return message;
            }
        }
        return null;
    }

    private void AnswerServerRequest(CoapMessage request, string text = "client")
    {
        var response = new CoapMessage
        {
            Type = request.Type == CoapMessageType.Confirmable ? CoapMessageType.Acknowledgement : CoapMessageType.NonConfirmable,
            Code = CoapCode.Content,
            MessageId = request.MessageId,
            Token = request.Token,
            Payload = Encoding.UTF8.GetBytes(text),
        };
        Send(response);
    }

    public void Close() => _dtls.Close();

    public void Dispose()
    {
        try { _dtls.Close(); } catch (Exception) { }
        _socket.Dispose();
    }

    private sealed class ConnectedUdp(Socket socket) : DatagramTransport
    {
        public int GetReceiveLimit() => 2048;
        public int GetSendLimit() => 1400;
        public int Receive(byte[] buf, int off, int len, int waitMillis) => Receive(buf.AsSpan(off, len), waitMillis);

        public int Receive(Span<byte> buffer, int waitMillis)
        {
            if (!socket.Poll(TimeSpan.FromMilliseconds(Math.Max(1, waitMillis)), SelectMode.SelectRead)) return -1;
            try { return socket.Receive(buffer); }
            catch (SocketException) { return -1; }
        }

        public void Send(byte[] buf, int off, int len) => socket.Send(buf, off, len, SocketFlags.None);
        public void Send(ReadOnlySpan<byte> buffer) => socket.Send(buffer);
        public void Close() { }
    }

    private sealed class TestPskClient(string identity, byte[] key, int cipherSuite, byte[]? connectionId, bool offerExtendedMasterSecret)
        : PskTlsClient(new BcTlsCrypto(new SecureRandom()), new BasicTlsPskIdentity(identity, key))
    {
        public SecurityParameters? Completed { get; private set; }

        protected override ProtocolVersion[] GetSupportedVersions() => ProtocolVersion.DTLSv12.Only();

        protected override int[] GetSupportedCipherSuites() => [cipherSuite];

        public override bool ShouldUseExtendedMasterSecret() => offerExtendedMasterSecret;

        public override int GetHandshakeTimeoutMillis() => 10_000;

        public override IDictionary<int, byte[]> GetClientExtensions()
        {
            var extensions = TlsExtensionsUtilities.EnsureExtensionsInitialised(base.GetClientExtensions());
            if (connectionId is not null) TlsExtensionsUtilities.AddConnectionIDExtension(extensions, connectionId);
            return extensions;
        }

        public override void NotifyHandshakeComplete()
        {
            base.NotifyHandshakeComplete();
            Completed = m_context.SecurityParameters;
        }
    }
}

/// <summary>
/// Forwards datagrams between a client and a server like a NAT. <see cref="Rebind"/> moves the
/// server-facing side to a new source port, which is what a NAT rebinding looks like from the server.
/// </summary>
public sealed class UdpRelay : IDisposable
{
    private readonly Socket _downstream;
    private readonly IPEndPoint _server;
    private readonly CancellationTokenSource _stopping = new();
    private readonly Lock _gate = new();
    private Socket _upstream;
    private IPEndPoint? _client;

    public UdpRelay(IPEndPoint server)
    {
        _server = server;
        _downstream = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        _downstream.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        _upstream = NewUpstream();
        _ = PumpUpAsync();
        _ = PumpDownAsync(_upstream);
    }

    public IPEndPoint ListenEndPoint => (IPEndPoint)_downstream.LocalEndPoint!;

    public IPEndPoint UpstreamEndPoint
    {
        get { lock (_gate) return (IPEndPoint)_upstream.LocalEndPoint!; }
    }

    public void Rebind()
    {
        Socket old;
        var fresh = NewUpstream();
        lock (_gate)
        {
            old = _upstream;
            _upstream = fresh;
        }
        _ = PumpDownAsync(fresh);
        old.Dispose();
    }

    public void Dispose()
    {
        _stopping.Cancel();
        _downstream.Dispose();
        lock (_gate) _upstream.Dispose();
    }

    private static Socket NewUpstream()
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        socket.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        return socket;
    }

    private async Task PumpUpAsync()
    {
        var buffer = new byte[65535];
        while (!_stopping.IsCancellationRequested)
        {
            try
            {
                var result = await _downstream.ReceiveFromAsync(buffer, new IPEndPoint(IPAddress.Any, 0), _stopping.Token);
                Socket upstream;
                lock (_gate)
                {
                    _client = (IPEndPoint)result.RemoteEndPoint;
                    upstream = _upstream;
                }
                await upstream.SendToAsync(buffer.AsMemory(0, result.ReceivedBytes), _server);
            }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { if (_stopping.IsCancellationRequested) return; }
            catch (SocketException) { }
        }
    }

    private async Task PumpDownAsync(Socket upstream)
    {
        var buffer = new byte[65535];
        while (!_stopping.IsCancellationRequested)
        {
            try
            {
                var result = await upstream.ReceiveFromAsync(buffer, new IPEndPoint(IPAddress.Any, 0), _stopping.Token);
                IPEndPoint? client;
                lock (_gate) client = _client;
                if (client is not null) await _downstream.SendToAsync(buffer.AsMemory(0, result.ReceivedBytes), client);
            }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { }
        }
    }
}

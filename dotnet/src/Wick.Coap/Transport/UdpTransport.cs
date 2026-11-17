using System.Net;
using System.Net.Sockets;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Wick.Coap.Transport;

/// <summary>Plain CoAP over UDP (RFC 7252), one socket for every peer.</summary>
public sealed class UdpTransport : IDatagramTransport
{
    private readonly IPEndPoint _bind;
    private readonly ILogger _logger;
    private readonly CancellationTokenSource _stopping = new();
    private Socket? _socket;
    private Task? _receiveLoop;

    /// <summary>Creates a transport that will bind to <paramref name="localEndPoint"/> when started.</summary>
    /// <param name="localEndPoint">The address to bind; port 0 picks a free port.</param>
    /// <param name="logger">An optional logger.</param>
    public UdpTransport(IPEndPoint localEndPoint, ILogger<UdpTransport>? logger = null)
    {
        _bind = localEndPoint ?? throw new ArgumentNullException(nameof(localEndPoint));
        _logger = (ILogger?)logger ?? NullLogger.Instance;
    }

    /// <inheritdoc />
    public string Scheme => "coap";

    /// <inheritdoc />
    public EndPoint LocalEndPoint => _socket?.LocalEndPoint ?? _bind;

    /// <summary>The largest message sent or received: 1152 bytes, as RFC 7252 section 4.6 recommends for an unknown path MTU.</summary>
    public int MaxMessageSize { get; init; } = 1152;

    /// <summary>The largest datagram accepted on receive. Larger ones are truncated by the socket and dropped.</summary>
    public int ReceiveBufferSize { get; init; } = 65507;

    /// <inheritdoc />
    public Task StartAsync(IDatagramReceiver receiver, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(receiver);
        if (_socket is not null) throw new InvalidOperationException("The transport is already started.");
        var socket = new Socket(_bind.AddressFamily, SocketType.Dgram, ProtocolType.Udp);
        if (_bind.AddressFamily == AddressFamily.InterNetworkV6 && _bind.Address.Equals(IPAddress.IPv6Any))
            socket.DualMode = true;
        socket.Bind(_bind);
        _socket = socket;
        _receiveLoop = Task.Run(() => ReceiveLoopAsync(socket, receiver, _stopping.Token), CancellationToken.None);
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public ValueTask SendAsync(ICoapPeer peer, ReadOnlyMemory<byte> datagram, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(peer);
        var socket = _socket ?? throw new InvalidOperationException("The transport is not started.");
        if (datagram.Length > MaxMessageSize)
            throw new ArgumentException($"Message of {datagram.Length} bytes exceeds the transport limit of {MaxMessageSize}.", nameof(datagram));
        var pending = socket.SendToAsync(datagram, SocketFlags.None, peer.RemoteEndPoint, cancellationToken);
        return pending.IsCompletedSuccessfully ? ValueTask.CompletedTask : AwaitSend(pending);

        static async ValueTask AwaitSend(ValueTask<int> pending) => await pending.ConfigureAwait(false);
    }

    /// <inheritdoc />
    public bool TryGetPeer(EndPoint remoteEndPoint, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out ICoapPeer? peer)
    {
        peer = new UdpPeer(remoteEndPoint);
        return true;
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        _stopping.Cancel();
        _socket?.Dispose();
        if (_receiveLoop is not null)
        {
            try { await _receiveLoop.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        _stopping.Dispose();
    }

    private async Task ReceiveLoopAsync(Socket socket, IDatagramReceiver receiver, CancellationToken stopping)
    {
        var buffer = new byte[ReceiveBufferSize];
        EndPoint any = socket.AddressFamily == AddressFamily.InterNetworkV6
            ? new IPEndPoint(IPAddress.IPv6Any, 0)
            : new IPEndPoint(IPAddress.Any, 0);

        while (!stopping.IsCancellationRequested)
        {
            SocketReceiveFromResult result;
            try
            {
                result = await socket.ReceiveFromAsync(buffer, SocketFlags.None, any, stopping).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException e) when (e.SocketErrorCode is SocketError.ConnectionReset or SocketError.MessageSize)
            {
                // ICMP port unreachable from an earlier send, or an oversized datagram; neither ends the loop.
                continue;
            }
            catch (SocketException e)
            {
                if (stopping.IsCancellationRequested) break;
                _logger.LogWarning(e, "UDP receive failed on {LocalEndPoint}", socket.LocalEndPoint);
                continue;
            }

            var datagram = buffer.AsSpan(0, result.ReceivedBytes).ToArray();
            try
            {
                receiver.OnDatagram(new UdpPeer(result.RemoteEndPoint), datagram);
            }
            catch (Exception e)
            {
                _logger.LogError(e, "Receiver failed on a datagram from {Peer}", result.RemoteEndPoint);
            }
        }
    }
}

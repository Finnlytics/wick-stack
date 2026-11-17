using System.Net;

namespace Wick.Coap.Transport;

/// <summary>
/// A datagram transport a <see cref="CoapEndpoint"/> runs over: plain UDP, DTLS, or an
/// in-memory network for tests.
/// </summary>
/// <remarks>
/// Implementations must not call back into the receiver from inside <see cref="SendAsync"/>,
/// because the endpoint may send while holding its internal lock.
/// </remarks>
public interface IDatagramTransport : IAsyncDisposable
{
    /// <summary>The URI scheme this transport serves, <c>coap</c> or <c>coaps</c>.</summary>
    string Scheme { get; }

    /// <summary>The bound local address. Only meaningful after <see cref="StartAsync"/>.</summary>
    EndPoint LocalEndPoint { get; }

    /// <summary>The largest CoAP message, in bytes, the transport can carry in one datagram.</summary>
    int MaxMessageSize { get; }

    /// <summary>Starts receiving. Inbound datagrams and peer closures are reported to <paramref name="receiver"/>.</summary>
    /// <param name="receiver">The receiver, normally the endpoint.</param>
    /// <param name="cancellationToken">Cancels start-up.</param>
    /// <returns>A task that completes once the transport is receiving.</returns>
    Task StartAsync(IDatagramReceiver receiver, CancellationToken cancellationToken = default);

    /// <summary>Sends one datagram to a peer.</summary>
    /// <param name="peer">The peer.</param>
    /// <param name="datagram">The CoAP message bytes.</param>
    /// <param name="cancellationToken">Cancels the send.</param>
    /// <returns>A task that completes once the datagram has been handed to the network.</returns>
    ValueTask SendAsync(ICoapPeer peer, ReadOnlyMemory<byte> datagram, CancellationToken cancellationToken = default);

    /// <summary>
    /// Finds the peer at an address so a request can be sent to it. A plain UDP transport can
    /// always produce one; a DTLS server transport only has peers that have completed a handshake.
    /// </summary>
    /// <param name="remoteEndPoint">The address.</param>
    /// <param name="peer">The peer when found.</param>
    /// <returns>True when a peer is available.</returns>
    bool TryGetPeer(EndPoint remoteEndPoint, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out ICoapPeer? peer);
}

/// <summary>Receives what a transport reads from the network.</summary>
public interface IDatagramReceiver
{
    /// <summary>
    /// Called for every inbound datagram. Implementations must return quickly and must not
    /// block, since the call is made on the transport's receive path.
    /// </summary>
    /// <param name="peer">The peer it came from.</param>
    /// <param name="datagram">The CoAP message bytes. The receiver owns the memory.</param>
    void OnDatagram(ICoapPeer peer, ReadOnlyMemory<byte> datagram);

    /// <summary>Called when a peer's session ends, so state held for it can be released.</summary>
    /// <param name="peer">The peer.</param>
    void OnPeerClosed(ICoapPeer peer);
}

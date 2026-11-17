using System.Net;

namespace Wick.Coap.Transport;

/// <summary>
/// The far end of a CoAP conversation as a transport sees it. The endpoint keys every piece
/// of per-peer state (message ids, deduplication, exchanges, observations, block transfers)
/// by this object, so implementations must define equality to mean "the same security
/// association": value equality on the address for plain UDP, reference equality for a DTLS
/// session, whose address can change while it stays the same peer.
/// </summary>
public interface ICoapPeer
{
    /// <summary>The address datagrams to this peer are currently sent to.</summary>
    EndPoint RemoteEndPoint { get; }

    /// <summary>Details of the security association, or null for an unsecured transport.</summary>
    CoapPeerSecurity? Security { get; }
}

/// <summary>Details of an authenticated session with a peer.</summary>
/// <param name="Protocol">The security protocol, for example <c>DTLS 1.2</c>.</param>
/// <param name="PskIdentity">The PSK identity the peer authenticated with, decoded as UTF-8, or null when not PSK.</param>
/// <param name="PskIdentityBytes">The raw PSK identity, or null when not PSK.</param>
/// <param name="CipherSuite">The negotiated cipher suite number, as registered with IANA.</param>
/// <param name="ExtendedMasterSecret">True when the extended master secret (RFC 7627) was negotiated.</param>
/// <param name="ConnectionId">The connection id the peer puts on its records (RFC 9146), or null when none was negotiated.</param>
public sealed record CoapPeerSecurity(
    string Protocol,
    string? PskIdentity,
    byte[]? PskIdentityBytes,
    int CipherSuite,
    bool ExtendedMasterSecret,
    byte[]? ConnectionId);

/// <summary>A peer on a plain datagram transport, identified by its address.</summary>
/// <param name="RemoteEndPoint">The peer's address.</param>
public sealed record UdpPeer(EndPoint RemoteEndPoint) : ICoapPeer
{
    /// <summary>Always null: plain UDP is unsecured.</summary>
    public CoapPeerSecurity? Security => null;

    /// <summary>Formats the peer address.</summary>
    /// <returns>The address.</returns>
    public override string ToString() => RemoteEndPoint.ToString() ?? "udp peer";
}

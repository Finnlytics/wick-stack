using System.Net;
using Org.BouncyCastle.Tls;

namespace Wick.Coap.Dtls;

/// <summary>Settings for a <see cref="DtlsServerTransport"/>.</summary>
public sealed record DtlsServerOptions
{
    /// <summary>The address to bind. Default any IPv4 address, port 5684.</summary>
    public IPEndPoint LocalEndPoint { get; init; } = new(IPAddress.Any, 5684);

    /// <summary>
    /// The length of the connection id this server issues (RFC 9146), 1 to 16 bytes, or 0 to
    /// disable Connection ID. With an id, a session survives a change of the peer's address.
    /// Default 6.
    /// </summary>
    public int ConnectionIdLength { get; init; } = 6;

    /// <summary>
    /// The cipher suites offered, in order of preference. Default
    /// TLS_PSK_WITH_AES_128_CCM_8, TLS_PSK_WITH_AES_128_GCM_SHA256 and
    /// TLS_PSK_WITH_AES_128_CBC_SHA256.
    /// </summary>
    public IReadOnlyList<int> CipherSuites { get; init; } =
    [
        CipherSuite.TLS_PSK_WITH_AES_128_CCM_8,
        CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256,
        CipherSuite.TLS_PSK_WITH_AES_128_CBC_SHA256,
    ];

    /// <summary>
    /// Refuse peers that do not offer the extended master secret (RFC 7627). Default false,
    /// because older DTLS stacks never send it; it is negotiated whenever the peer offers it.
    /// </summary>
    public bool RequireExtendedMasterSecret { get; init; }

    /// <summary>
    /// Refuse peers that do not signal secure renegotiation (RFC 5746). Default false, because
    /// older DTLS stacks send neither the extension nor the signalling cipher suite. This server
    /// never renegotiates either way.
    /// </summary>
    public bool RequireSecureRenegotiation { get; init; }

    /// <summary>Handshakes in progress at once. A ClientHello beyond the limit is dropped and the peer retries. Default 64.</summary>
    public int MaxConcurrentHandshakes { get; init; } = 64;

    /// <summary>How long a handshake may take from the verified ClientHello to completion. Default 30 seconds.</summary>
    public TimeSpan HandshakeTimeout { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>How long a PSK lookup may take. Default 10 seconds.</summary>
    public TimeSpan PskLookupTimeout { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>
    /// A session that receives nothing for this long is dropped without a close_notify, so a
    /// sleeping device can still resume it until then. Default 24 hours.
    /// </summary>
    public TimeSpan SessionIdleTimeout { get; init; } = TimeSpan.FromHours(24);

    /// <summary>The most sessions held at once; the least recently active is dropped to make room. Default 100000.</summary>
    public int MaxSessions { get; init; } = 100_000;

    /// <summary>
    /// The largest datagram sent, records included. Handshake messages are fragmented to fit and
    /// the CoAP message limit is derived from it. Default 1400.
    /// </summary>
    public int MaxDatagramSize { get; init; } = 1400;

    /// <summary>Datagrams queued for a session while its handshake runs; more are dropped. Default 32.</summary>
    public int HandshakeQueueLength { get; init; } = 32;

    /// <summary>An optional PSK identity hint sent in the ServerKeyExchange.</summary>
    public byte[]? PskIdentityHint { get; init; }

    /// <summary>How often idle sessions are swept. Default 1 minute.</summary>
    public TimeSpan HousekeepingInterval { get; init; } = TimeSpan.FromMinutes(1);

    internal void Validate()
    {
        if (ConnectionIdLength is < 0 or > 16) throw new ArgumentOutOfRangeException(nameof(ConnectionIdLength), "Connection id length must be 0 to 16.");
        if (CipherSuites.Count == 0) throw new ArgumentException("At least one cipher suite is required.", nameof(CipherSuites));
        if (MaxConcurrentHandshakes < 1) throw new ArgumentOutOfRangeException(nameof(MaxConcurrentHandshakes));
        if (HandshakeTimeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(HandshakeTimeout));
        if (PskLookupTimeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(PskLookupTimeout));
        if (SessionIdleTimeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(SessionIdleTimeout));
        if (MaxSessions < 1) throw new ArgumentOutOfRangeException(nameof(MaxSessions));
        if (MaxDatagramSize is < 256 or > 65507) throw new ArgumentOutOfRangeException(nameof(MaxDatagramSize));
        if (HandshakeQueueLength < 1) throw new ArgumentOutOfRangeException(nameof(HandshakeQueueLength));
        if (HousekeepingInterval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(HousekeepingInterval));
    }
}

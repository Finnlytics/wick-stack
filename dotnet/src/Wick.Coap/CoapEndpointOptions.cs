namespace Wick.Coap;

/// <summary>Settings for a <see cref="CoapEndpoint"/>. Every limit exists so per-peer state stays bounded.</summary>
public sealed record CoapEndpointOptions
{
    /// <summary>Retransmission timing and the lifetimes derived from it (RFC 7252 section 4.8).</summary>
    public CoapTransmissionParameters Transmission { get; init; } = new();

    /// <summary>The block size used for outbound block-wise transfers, 16 to 1024. Default 1024.</summary>
    public int PreferredBlockSize { get; init; } = 1024;

    /// <summary>The largest body reassembled from blocks, in either direction. Default 1 MiB.</summary>
    public int MaxBodySize { get; init; } = 1 << 20;

    /// <summary>Token length for outbound requests, 1 to 8. Default 8.</summary>
    public int TokenLength { get; init; } = 8;

    /// <summary>
    /// How long a handler may take before a confirmable request is acknowledged with an empty
    /// ACK and the response sent separately. Default 1 second, half the default ACK_TIMEOUT,
    /// so the peer does not retransmit.
    /// </summary>
    public TimeSpan SeparateResponseDelay { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>
    /// How long to wait for a response once a request has been acknowledged, or for any
    /// response to a non-confirmable request. Null means EXCHANGE_LIFETIME.
    /// </summary>
    public TimeSpan? ResponseTimeout { get; init; }

    /// <summary>The most message ids remembered for deduplication across all peers. Default 100000.</summary>
    public int DeduplicationCapacity { get; init; } = 100_000;

    /// <summary>Requests that may wait for an NSTART slot per peer before further ones are refused. Default 64.</summary>
    public int MaxQueuedRequestsPerPeer { get; init; } = 64;

    /// <summary>Inbound requests from one peer being handled at once; beyond this the peer receives 5.03. Default 16.</summary>
    public int MaxConcurrentRequestsPerPeer { get; init; } = 16;

    /// <summary>Server-side observations one peer may hold; further registrations are answered without Observe. Default 64.</summary>
    public int MaxObservationsPerPeer { get; init; } = 64;

    /// <summary>Server-side block-wise transfers in progress per peer; the oldest is dropped beyond this. Default 8.</summary>
    public int MaxBlockTransfersPerPeer { get; init; } = 8;

    /// <summary>Notifications buffered per client-side observation before the oldest are dropped. Default 64.</summary>
    public int NotificationBufferSize { get; init; } = 64;

    /// <summary>
    /// The longest a server-side observation goes without a confirmable notification, which
    /// tells the server whether the client is still there (RFC 7641 section 4.5). Default 24 hours.
    /// </summary>
    public TimeSpan ConfirmableNotificationInterval { get; init; } = TimeSpan.FromHours(24);

    /// <summary>How often expired state is swept. Default 10 seconds.</summary>
    public TimeSpan HousekeepingInterval { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>Critical options beyond the registered set that requests may carry without being rejected with 4.02.</summary>
    public IReadOnlySet<int> AdditionalRecognisedOptions { get; init; } = new HashSet<int>();

    internal TimeSpan EffectiveResponseTimeout => ResponseTimeout ?? Transmission.ExchangeLifetime;

    internal void Validate()
    {
        Transmission.Validate();
        _ = BlockOption.ExponentOf(PreferredBlockSize);
        if (TokenLength is < 1 or > 8) throw new ArgumentOutOfRangeException(nameof(TokenLength), "Token length must be 1 to 8.");
        if (MaxBodySize < 0) throw new ArgumentOutOfRangeException(nameof(MaxBodySize));
        if (SeparateResponseDelay < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(SeparateResponseDelay));
        if (HousekeepingInterval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(HousekeepingInterval));
        if (MaxQueuedRequestsPerPeer < 0) throw new ArgumentOutOfRangeException(nameof(MaxQueuedRequestsPerPeer));
        if (MaxConcurrentRequestsPerPeer < 1) throw new ArgumentOutOfRangeException(nameof(MaxConcurrentRequestsPerPeer));
        if (MaxObservationsPerPeer < 0) throw new ArgumentOutOfRangeException(nameof(MaxObservationsPerPeer));
        if (MaxBlockTransfersPerPeer < 1) throw new ArgumentOutOfRangeException(nameof(MaxBlockTransfersPerPeer));
        if (NotificationBufferSize < 1) throw new ArgumentOutOfRangeException(nameof(NotificationBufferSize));
    }
}

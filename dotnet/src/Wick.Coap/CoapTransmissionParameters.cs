namespace Wick.Coap;

/// <summary>
/// The message transmission parameters of RFC 7252 section 4.8 and the time values derived
/// from them in section 4.8.2. The defaults are the RFC defaults.
/// </summary>
public sealed record CoapTransmissionParameters
{
    /// <summary>ACK_TIMEOUT: the initial retransmission timeout before randomisation. Default 2 seconds.</summary>
    public TimeSpan AckTimeout { get; init; } = TimeSpan.FromSeconds(2);

    /// <summary>ACK_RANDOM_FACTOR: the initial timeout is drawn from ACK_TIMEOUT to ACK_TIMEOUT times this. Default 1.5; must be at least 1.</summary>
    public double AckRandomFactor { get; init; } = 1.5;

    /// <summary>MAX_RETRANSMIT: retransmissions after the first transmission. Default 4.</summary>
    public int MaxRetransmit { get; init; } = 4;

    /// <summary>NSTART: outstanding interactions allowed per peer. Default 1.</summary>
    public int NStart { get; init; } = 1;

    /// <summary>MAX_LATENCY: the longest a datagram is expected to take in transit. Default 100 seconds.</summary>
    public TimeSpan MaxLatency { get; init; } = TimeSpan.FromSeconds(100);

    /// <summary>PROCESSING_DELAY: the time a node takes to turn a confirmable message into an acknowledgement. RFC 7252 sets it to ACK_TIMEOUT.</summary>
    public TimeSpan ProcessingDelay => AckTimeout;

    /// <summary>MAX_TRANSMIT_SPAN: from first transmission to last retransmission. 45 seconds by default.</summary>
    public TimeSpan MaxTransmitSpan => AckTimeout * (((1 << MaxRetransmit) - 1) * AckRandomFactor);

    /// <summary>MAX_TRANSMIT_WAIT: from first transmission to giving up. 93 seconds by default.</summary>
    public TimeSpan MaxTransmitWait => AckTimeout * (((1 << (MaxRetransmit + 1)) - 1) * AckRandomFactor);

    /// <summary>MAX_RTT: 2 times MAX_LATENCY plus PROCESSING_DELAY. 202 seconds by default.</summary>
    public TimeSpan MaxRtt => (2 * MaxLatency) + ProcessingDelay;

    /// <summary>EXCHANGE_LIFETIME: how long a confirmable message id stays in use. 247 seconds by default.</summary>
    public TimeSpan ExchangeLifetime => MaxTransmitSpan + (2 * MaxLatency) + ProcessingDelay;

    /// <summary>NON_LIFETIME: how long a non-confirmable message id stays in use. 145 seconds by default.</summary>
    public TimeSpan NonLifetime => MaxTransmitSpan + MaxLatency;

    /// <summary>Throws when a parameter is outside the range RFC 7252 allows.</summary>
    /// <exception cref="ArgumentOutOfRangeException">A parameter is out of range.</exception>
    public void Validate()
    {
        if (AckTimeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(AckTimeout), "ACK_TIMEOUT must be positive.");
        if (AckRandomFactor < 1.0) throw new ArgumentOutOfRangeException(nameof(AckRandomFactor), "ACK_RANDOM_FACTOR must be at least 1.");
        if (MaxRetransmit is < 0 or > 20) throw new ArgumentOutOfRangeException(nameof(MaxRetransmit), "MAX_RETRANSMIT must be 0 to 20.");
        if (NStart < 1) throw new ArgumentOutOfRangeException(nameof(NStart), "NSTART must be at least 1.");
        if (MaxLatency < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(MaxLatency), "MAX_LATENCY cannot be negative.");
    }
}

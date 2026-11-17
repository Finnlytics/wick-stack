namespace Wick.Coap;

/// <summary>What a confirmable sender should do at a point in time.</summary>
public enum RetransmissionAction
{
    /// <summary>The deadline has not been reached.</summary>
    Wait,

    /// <summary>Send the message again.</summary>
    Retransmit,

    /// <summary>MAX_RETRANSMIT retransmissions have gone unanswered; give up.</summary>
    GiveUp,
}

/// <summary>
/// Retransmission state for one confirmable message (RFC 7252 section 4.2). The first
/// timeout is random between ACK_TIMEOUT and ACK_TIMEOUT times ACK_RANDOM_FACTOR and
/// doubles after each retransmission. With MAX_RETRANSMIT 4 the message is sent five times
/// and abandoned one timeout after the last. The type is pure: the caller supplies time.
/// </summary>
public sealed class RetransmissionState
{
    private readonly int _maxRetransmit;

    /// <summary>Creates the state for a message sent at <paramref name="now"/>.</summary>
    /// <param name="parameters">The transmission parameters.</param>
    /// <param name="now">The time of the first transmission.</param>
    /// <param name="random">The source of randomness for the initial timeout.</param>
    public RetransmissionState(CoapTransmissionParameters parameters, DateTimeOffset now, Random random)
    {
        ArgumentNullException.ThrowIfNull(parameters);
        ArgumentNullException.ThrowIfNull(random);
        _maxRetransmit = parameters.MaxRetransmit;
        double factor = 1.0 + ((parameters.AckRandomFactor - 1.0) * random.NextDouble());
        Interval = parameters.AckTimeout * factor;
        Transmissions = 1;
        NextDeadline = now + Interval;
    }

    /// <summary>Transmissions so far, counting the first.</summary>
    public int Transmissions { get; private set; }

    /// <summary>The current timeout.</summary>
    public TimeSpan Interval { get; private set; }

    /// <summary>When the next retransmission, or giving up, is due.</summary>
    public DateTimeOffset NextDeadline { get; private set; }

    /// <summary>Decides what to do at <paramref name="now"/>, advancing the state on a retransmission.</summary>
    /// <param name="now">The current time.</param>
    /// <returns>The action to take.</returns>
    public RetransmissionAction Next(DateTimeOffset now)
    {
        if (now < NextDeadline) return RetransmissionAction.Wait;
        if (Transmissions > _maxRetransmit) return RetransmissionAction.GiveUp;
        Transmissions++;
        Interval *= 2;
        NextDeadline = now + Interval;
        return RetransmissionAction.Retransmit;
    }
}

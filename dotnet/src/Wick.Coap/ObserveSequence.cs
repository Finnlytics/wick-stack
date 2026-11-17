namespace Wick.Coap;

/// <summary>
/// Observe sequence numbers (RFC 7641 sections 3.4 and 4.4): 24-bit values that wrap, and
/// the rule a client uses to decide whether a notification is newer than the last one it
/// accepted.
/// </summary>
public static class ObserveSequence
{
    /// <summary>The Observe value that registers an observation in a request.</summary>
    public const uint Register = 0;

    /// <summary>The Observe value that cancels an observation in a request.</summary>
    public const uint Deregister = 1;

    /// <summary>The modulus of notification sequence numbers, 2^24.</summary>
    public const uint Modulus = 1u << 24;

    /// <summary>
    /// The time after which any notification counts as newer regardless of sequence
    /// number (RFC 7641 section 3.4).
    /// </summary>
    public static readonly TimeSpan FreshnessWindow = TimeSpan.FromSeconds(128);

    private const uint Half = 1u << 23;

    /// <summary>The sequence number after <paramref name="value"/>, wrapping at 2^24.</summary>
    /// <param name="value">The current sequence number.</param>
    /// <returns>The next sequence number.</returns>
    public static uint Next(uint value) => (value + 1) % Modulus;

    /// <summary>
    /// True when a notification with sequence number <paramref name="arrived"/>, received at
    /// <paramref name="arrivedAt"/>, is newer than the last accepted one: <c>V1</c> is newer
    /// than <c>V2</c> if <c>(V1 &lt; V2 and V2 - V1 &gt; 2^23)</c>, or <c>(V1 &gt; V2 and V1 - V2 &lt; 2^23)</c>,
    /// or more than 128 seconds have passed since <c>V2</c> arrived.
    /// </summary>
    /// <param name="arrived">The sequence number of the new notification.</param>
    /// <param name="arrivedAt">When it arrived.</param>
    /// <param name="last">The last accepted sequence number, or null when none has been accepted.</param>
    /// <param name="lastAt">When the last accepted notification arrived.</param>
    /// <returns>True when the new notification should be accepted.</returns>
    public static bool IsNewer(uint arrived, DateTimeOffset arrivedAt, uint? last, DateTimeOffset lastAt)
    {
        if (last is not uint v2) return true;
        uint v1 = arrived % Modulus;
        v2 %= Modulus;
        if (v1 < v2 && v2 - v1 > Half) return true;
        if (v1 > v2 && v1 - v2 < Half) return true;
        return arrivedAt > lastAt + FreshnessWindow;
    }

    /// <summary>The sequence-number part of the comparison alone, without the time rule.</summary>
    /// <param name="arrived">The new sequence number.</param>
    /// <param name="last">The last accepted sequence number, or null.</param>
    /// <returns>True when <paramref name="arrived"/> is newer.</returns>
    public static bool IsNewer(uint arrived, uint? last) =>
        IsNewer(arrived, DateTimeOffset.MinValue, last, DateTimeOffset.MinValue + FreshnessWindow);
}

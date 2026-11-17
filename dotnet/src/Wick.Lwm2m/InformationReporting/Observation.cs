using System.Collections.Immutable;
using Wick.Lwm2m.DeviceManagement;

namespace Wick.Lwm2m.InformationReporting;

/// <summary>
/// One Observe relation, as the server needs to remember it to interpret notifications.
/// </summary>
/// <remarks>
/// <para>
/// A notification carries a token, a sequence number, a Content-Format and a payload. It does not
/// say what it is a notification of: the binding from token to observed paths lives here, and
/// without it a notification cannot be decoded.
/// </para>
/// <para>
/// The record is immutable. <see cref="Accept"/> returns the relation advanced past a notification,
/// or <see langword="null"/> when the notification is older than one already seen.
/// </para>
/// </remarks>
public sealed record Observation
{
    private const uint SequenceSpace = 1u << 24;
    private const uint HalfSequenceSpace = 1u << 23;

    /// <summary>RFC 7641 §3.4: after this long, a notification counts as fresh whatever its sequence number.</summary>
    public static readonly TimeSpan FreshnessWindow = TimeSpan.FromSeconds(128);

    private readonly ImmutableArray<Lwm2mPath> _paths;
    private readonly ReadOnlyMemory<byte> _token;

    /// <summary>Creates a relation.</summary>
    /// <param name="registrationId">The registration the relation belongs to.</param>
    /// <param name="paths">The observed paths. One for a plain Observe.</param>
    /// <param name="token">The CoAP token the relation is keyed by. Copied.</param>
    /// <param name="composite">True when the relation came from Observe-Composite.</param>
    /// <param name="createdAt">When the relation was established.</param>
    public Observation(string registrationId, IEnumerable<Lwm2mPath> paths, ReadOnlyMemory<byte> token, bool composite, DateTimeOffset createdAt)
    {
        ArgumentException.ThrowIfNullOrEmpty(registrationId);
        ArgumentNullException.ThrowIfNull(paths);
        _paths = paths.ToImmutableArray();
        if (_paths.IsEmpty || (!composite && _paths.Length != 1))
        {
            throw new ArgumentException("a relation observes one path, or one or more for Observe-Composite", nameof(paths));
        }

        if (token.Length > 8)
        {
            throw new ArgumentException("a CoAP token is at most 8 bytes", nameof(token));
        }

        RegistrationId = registrationId;
        _token = token.ToArray();
        IsComposite = composite;
        CreatedAt = createdAt;
    }

    /// <summary>The registration the relation belongs to.</summary>
    public string RegistrationId { get; }

    /// <summary>The observed paths.</summary>
    public IReadOnlyList<Lwm2mPath> Paths => _paths;

    /// <summary>The CoAP token the relation is keyed by.</summary>
    public ReadOnlyMemory<byte> Token => _token;

    /// <summary>The token as upper-case hexadecimal, convenient as a dictionary key or in logs.</summary>
    public string TokenHex => Convert.ToHexString(_token.Span);

    /// <summary>True when the relation came from Observe-Composite, so notifications are SenML packs naming their own paths.</summary>
    public bool IsComposite { get; }

    /// <summary>When the relation was established.</summary>
    public DateTimeOffset CreatedAt { get; }

    /// <summary>The Content-Format requested for notifications, or <see langword="null"/>.</summary>
    public int? ContentFormat { get; init; }

    /// <summary>The sequence number of the latest accepted notification, or <see langword="null"/> before the first.</summary>
    public uint? LastSequence { get; init; }

    /// <summary>When the latest accepted notification arrived, or <see langword="null"/> before the first.</summary>
    public DateTimeOffset? LastNotifiedAt { get; init; }

    /// <summary>
    /// Creates the relation for an established Observe, taking the sequence number of the response
    /// that established it as the first one seen.
    /// </summary>
    /// <param name="registrationId">The registration.</param>
    /// <param name="request">The Observe request. Its token must be the one the transport used.</param>
    /// <param name="response">The parsed response, which must have established the relation.</param>
    /// <param name="at">When the response arrived.</param>
    /// <returns>The relation.</returns>
    /// <exception cref="ArgumentException">The response did not establish a relation.</exception>
    public static Observation Establish(string registrationId, ObserveRequest request, ObserveResponse response, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(response);
        if (!response.IsEstablished)
        {
            throw new ArgumentException("the response did not establish an Observe relation", nameof(response));
        }

        return new Observation(registrationId, [request.Path], request.Token, false, at)
        {
            ContentFormat = request.Accept,
            LastSequence = response.Sequence,
            LastNotifiedAt = at,
        };
    }

    /// <summary>Creates the relation for an established Observe-Composite.</summary>
    /// <param name="registrationId">The registration.</param>
    /// <param name="request">The Observe-Composite request.</param>
    /// <param name="response">The parsed response, which must carry the Observe option.</param>
    /// <param name="at">When the response arrived.</param>
    /// <returns>The relation.</returns>
    /// <exception cref="ArgumentException">The response did not establish a relation.</exception>
    public static Observation Establish(string registrationId, ObserveCompositeRequest request, CompositeResponse response, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(response);
        if (!response.IsSuccess || response.Sequence is null)
        {
            throw new ArgumentException("the response did not establish an Observe-Composite relation", nameof(response));
        }

        return new Observation(registrationId, request.Paths, request.Token, true, at)
        {
            ContentFormat = request.Accept,
            LastSequence = response.Sequence,
            LastNotifiedAt = at,
        };
    }

    /// <summary>
    /// Applies the RFC 7641 §3.4 freshness test to a notification: newer when its 24-bit sequence
    /// number is ahead of the last one modulo wrap-around, or when more than 128 seconds have passed.
    /// </summary>
    /// <param name="sequence">The notification's Observe value.</param>
    /// <param name="at">When it arrived.</param>
    /// <returns>Whether it is fresher than the latest accepted notification.</returns>
    public bool IsFresh(uint sequence, DateTimeOffset at)
    {
        if (LastSequence is not { } last || LastNotifiedAt is not { } lastAt)
        {
            return true;
        }

        uint v1 = last % SequenceSpace;
        uint v2 = sequence % SequenceSpace;
        return (v1 < v2 && v2 - v1 < HalfSequenceSpace) ||
               (v1 > v2 && v1 - v2 > HalfSequenceSpace) ||
               at > lastAt + FreshnessWindow;
    }

    /// <summary>Advances the relation past a notification when it is fresh.</summary>
    /// <param name="sequence">The notification's Observe value.</param>
    /// <param name="at">When it arrived.</param>
    /// <returns>The advanced relation, or <see langword="null"/> when the notification is stale and should be discarded.</returns>
    public Observation? Accept(uint sequence, DateTimeOffset at) =>
        IsFresh(sequence, at) ? this with { LastSequence = sequence, LastNotifiedAt = at } : null;

    /// <inheritdoc/>
    public bool Equals(Observation? other) =>
        other is not null && RegistrationId == other.RegistrationId && _paths.SequenceEqual(other._paths) &&
        _token.Span.SequenceEqual(other._token.Span) && IsComposite == other.IsComposite && CreatedAt == other.CreatedAt &&
        ContentFormat == other.ContentFormat && LastSequence == other.LastSequence && LastNotifiedAt == other.LastNotifiedAt;

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(RegistrationId, TokenHex, LastSequence);
}

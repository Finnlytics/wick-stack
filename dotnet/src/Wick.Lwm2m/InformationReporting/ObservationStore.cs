namespace Wick.Lwm2m.InformationReporting;

/// <summary>How a notification relates to the relations a store holds.</summary>
public enum NotificationOrder
{
    /// <summary>The notification is fresher than any seen on the relation; the relation was advanced.</summary>
    Fresh,

    /// <summary>The notification arrived out of order and is older than one already accepted; discard it.</summary>
    Stale,

    /// <summary>No relation has this token; the server should answer with a CoAP Reset so the client stops.</summary>
    Unknown,
}

/// <summary>
/// Somewhere to keep Observe relations, keyed by registration and token.
/// </summary>
/// <remarks>
/// Implementations must be safe to call concurrently. Relations die with their registration (OMA
/// LwM2M 1.2 §6.2), so a server calls <see cref="RemoveByRegistration"/> on Deregister, on expiry,
/// and when a Register replaces an earlier registration of the same endpoint.
/// </remarks>
public interface IObservationStore
{
    /// <summary>Stores a relation, replacing any held under the same registration and token.</summary>
    /// <param name="observation">The relation.</param>
    void Add(Observation observation);

    /// <summary>Looks a relation up by registration and token.</summary>
    /// <param name="registrationId">The registration.</param>
    /// <param name="token">The token.</param>
    /// <returns>The relation, or <see langword="null"/>.</returns>
    Observation? Get(string registrationId, ReadOnlySpan<byte> token);

    /// <summary>The relations of one registration.</summary>
    /// <param name="registrationId">The registration.</param>
    /// <returns>The relations, oldest first.</returns>
    IReadOnlyList<Observation> GetByRegistration(string registrationId);

    /// <summary>Removes one relation.</summary>
    /// <param name="registrationId">The registration.</param>
    /// <param name="token">The token.</param>
    /// <returns>The removed relation, or <see langword="null"/> when there was none.</returns>
    Observation? Remove(string registrationId, ReadOnlySpan<byte> token);

    /// <summary>Removes every relation of one registration.</summary>
    /// <param name="registrationId">The registration.</param>
    /// <returns>The removed relations.</returns>
    IReadOnlyList<Observation> RemoveByRegistration(string registrationId);

    /// <summary>
    /// Applies the RFC 7641 freshness test to an arriving notification and, when it is fresh,
    /// advances the stored relation. The test and the update happen atomically.
    /// </summary>
    /// <param name="registrationId">The registration the notification came from.</param>
    /// <param name="token">The notification's token.</param>
    /// <param name="sequence">The notification's Observe value.</param>
    /// <param name="at">When it arrived.</param>
    /// <param name="observation">The relation: advanced when fresh, as stored when stale, <see langword="null"/> when unknown.</param>
    /// <returns>How the notification relates to the stored relation.</returns>
    NotificationOrder Accept(string registrationId, ReadOnlySpan<byte> token, uint sequence, DateTimeOffset at, out Observation? observation);
}

/// <summary>
/// An in-memory <see cref="IObservationStore"/>, safe for concurrent use. Relations live only as
/// long as the instance; it is not persistent storage.
/// </summary>
public sealed class InMemoryObservationStore : IObservationStore
{
    private readonly object _gate = new();
    private readonly Dictionary<(string RegistrationId, string Token), Observation> _relations = [];
    private readonly Dictionary<string, List<string>> _byRegistration = new(StringComparer.Ordinal);

    /// <summary>The number of relations held.</summary>
    public int Count
    {
        get
        {
            lock (_gate)
            {
                return _relations.Count;
            }
        }
    }

    /// <inheritdoc/>
    public void Add(Observation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        var key = (observation.RegistrationId, observation.TokenHex);
        lock (_gate)
        {
            if (_relations.TryAdd(key, observation))
            {
                if (!_byRegistration.TryGetValue(observation.RegistrationId, out var tokens))
                {
                    tokens = [];
                    _byRegistration[observation.RegistrationId] = tokens;
                }

                tokens.Add(observation.TokenHex);
            }
            else
            {
                _relations[key] = observation;
            }
        }
    }

    /// <inheritdoc/>
    public Observation? Get(string registrationId, ReadOnlySpan<byte> token)
    {
        var key = (registrationId, Convert.ToHexString(token));
        lock (_gate)
        {
            return _relations.GetValueOrDefault(key);
        }
    }

    /// <inheritdoc/>
    public IReadOnlyList<Observation> GetByRegistration(string registrationId)
    {
        lock (_gate)
        {
            return _byRegistration.TryGetValue(registrationId, out var tokens)
                ? tokens.Select(t => _relations[(registrationId, t)]).ToList()
                : [];
        }
    }

    /// <inheritdoc/>
    public Observation? Remove(string registrationId, ReadOnlySpan<byte> token)
    {
        var hex = Convert.ToHexString(token);
        lock (_gate)
        {
            if (!_relations.Remove((registrationId, hex), out var removed))
            {
                return null;
            }

            var tokens = _byRegistration[registrationId];
            tokens.Remove(hex);
            if (tokens.Count == 0)
            {
                _byRegistration.Remove(registrationId);
            }

            return removed;
        }
    }

    /// <inheritdoc/>
    public IReadOnlyList<Observation> RemoveByRegistration(string registrationId)
    {
        lock (_gate)
        {
            if (!_byRegistration.Remove(registrationId, out var tokens))
            {
                return [];
            }

            var removed = new List<Observation>(tokens.Count);
            foreach (var token in tokens)
            {
                if (_relations.Remove((registrationId, token), out var observation))
                {
                    removed.Add(observation);
                }
            }

            return removed;
        }
    }

    /// <inheritdoc/>
    public NotificationOrder Accept(string registrationId, ReadOnlySpan<byte> token, uint sequence, DateTimeOffset at, out Observation? observation)
    {
        var key = (registrationId, Convert.ToHexString(token));
        lock (_gate)
        {
            if (!_relations.TryGetValue(key, out var current))
            {
                observation = null;
                return NotificationOrder.Unknown;
            }

            if (current.Accept(sequence, at) is { } advanced)
            {
                _relations[key] = advanced;
                observation = advanced;
                return NotificationOrder.Fresh;
            }

            observation = current;
            return NotificationOrder.Stale;
        }
    }
}

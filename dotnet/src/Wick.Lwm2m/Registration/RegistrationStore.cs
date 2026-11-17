namespace Wick.Lwm2m.Registration;

/// <summary>
/// Somewhere to keep client registrations.
/// </summary>
/// <remarks>
/// <para>
/// LwM2M allows one active registration per endpoint name: a fresh Register from a known endpoint
/// replaces the old one (OMA LwM2M 1.2 §6.2.1). Implementations enforce that in <see cref="Add"/>.
/// </para>
/// <para>
/// A registration past its expiry is treated as absent by every lookup, whether or not it has been
/// purged yet. <see cref="RemoveExpired"/> purges them and returns them so the caller can drop their
/// observations. Implementations must be safe to call concurrently.
/// </para>
/// </remarks>
public interface IRegistrationStore
{
    /// <summary>Stores a new registration, replacing any held for the same endpoint name.</summary>
    /// <param name="registration">The registration.</param>
    /// <returns>
    /// The registration it replaced, or <see langword="null"/>. An expired registration that had not
    /// been purged is returned too, so the caller can drop its observations.
    /// </returns>
    ClientRegistration? Add(ClientRegistration registration);

    /// <summary>Looks a live registration up by ID.</summary>
    /// <param name="registrationId">The registration ID.</param>
    /// <returns>The registration, or <see langword="null"/> when unknown or expired.</returns>
    ClientRegistration? Get(string registrationId);

    /// <summary>Looks a live registration up by endpoint name.</summary>
    /// <param name="endpointName">The endpoint client name.</param>
    /// <returns>The registration, or <see langword="null"/> when unknown or expired.</returns>
    ClientRegistration? GetByEndpoint(string endpointName);

    /// <summary>Every live registration.</summary>
    /// <returns>The registrations, in no particular order.</returns>
    IReadOnlyList<ClientRegistration> GetAll();

    /// <summary>Replaces a live registration with an updated copy carrying the same ID and endpoint name.</summary>
    /// <param name="updated">The updated registration.</param>
    /// <returns>The registration it replaced, or <see langword="null"/> when there is no live registration with that ID.</returns>
    ClientRegistration? Update(ClientRegistration updated);

    /// <summary>Removes a registration, live or expired.</summary>
    /// <param name="registrationId">The registration ID.</param>
    /// <returns>The removed registration, or <see langword="null"/> when unknown.</returns>
    ClientRegistration? Remove(string registrationId);

    /// <summary>Removes every expired registration.</summary>
    /// <returns>The registrations removed.</returns>
    IReadOnlyList<ClientRegistration> RemoveExpired();
}

/// <summary>
/// An in-memory <see cref="IRegistrationStore"/> that expires registrations by lifetime, reading
/// the time from an injected <see cref="TimeProvider"/>. Safe for concurrent use.
/// </summary>
/// <remarks>
/// This is not persistent storage: registrations live only as long as the instance. A production
/// server with more than one node, or one that must survive a restart, implements
/// <see cref="IRegistrationStore"/> over its own database.
/// </remarks>
public sealed class InMemoryRegistrationStore : IRegistrationStore
{
    private readonly object _gate = new();
    private readonly Dictionary<string, ClientRegistration> _byId = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _byEndpoint = new(StringComparer.Ordinal);
    private readonly TimeProvider _time;
    private readonly TimeSpan _gracePeriod;

    /// <summary>Creates a store.</summary>
    /// <param name="time">The clock used to judge expiry.</param>
    /// <param name="gracePeriod">Extra time allowed past each lifetime before a registration counts as expired. Defaults to none.</param>
    public InMemoryRegistrationStore(TimeProvider time, TimeSpan gracePeriod = default)
    {
        ArgumentNullException.ThrowIfNull(time);
        if (gracePeriod < TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(gracePeriod), "the grace period cannot be negative");
        }

        _time = time;
        _gracePeriod = gracePeriod;
    }

    /// <inheritdoc/>
    public ClientRegistration? Add(ClientRegistration registration)
    {
        ArgumentNullException.ThrowIfNull(registration);
        lock (_gate)
        {
            ClientRegistration? replaced = null;
            if (_byEndpoint.TryGetValue(registration.EndpointName, out var previousId) && _byId.Remove(previousId, out var previous))
            {
                replaced = previous;
            }

            if (_byId.Remove(registration.Id, out var clash))
            {
                _byEndpoint.Remove(clash.EndpointName);
            }

            _byId[registration.Id] = registration;
            _byEndpoint[registration.EndpointName] = registration.Id;
            return replaced;
        }
    }

    /// <inheritdoc/>
    public ClientRegistration? Get(string registrationId)
    {
        lock (_gate)
        {
            return _byId.TryGetValue(registrationId, out var registration) && Live(registration) ? registration : null;
        }
    }

    /// <inheritdoc/>
    public ClientRegistration? GetByEndpoint(string endpointName)
    {
        lock (_gate)
        {
            return _byEndpoint.TryGetValue(endpointName, out var id) && _byId.TryGetValue(id, out var registration) && Live(registration)
                ? registration
                : null;
        }
    }

    /// <inheritdoc/>
    public IReadOnlyList<ClientRegistration> GetAll()
    {
        lock (_gate)
        {
            return _byId.Values.Where(Live).ToList();
        }
    }

    /// <inheritdoc/>
    public ClientRegistration? Update(ClientRegistration updated)
    {
        ArgumentNullException.ThrowIfNull(updated);
        lock (_gate)
        {
            if (!_byId.TryGetValue(updated.Id, out var current) || !Live(current))
            {
                return null;
            }

            if (current.EndpointName != updated.EndpointName)
            {
                throw new ArgumentException("an update cannot change the endpoint name", nameof(updated));
            }

            _byId[updated.Id] = updated;
            return current;
        }
    }

    /// <inheritdoc/>
    public ClientRegistration? Remove(string registrationId)
    {
        lock (_gate)
        {
            if (!_byId.Remove(registrationId, out var removed))
            {
                return null;
            }

            _byEndpoint.Remove(removed.EndpointName);
            return removed;
        }
    }

    /// <inheritdoc/>
    public IReadOnlyList<ClientRegistration> RemoveExpired()
    {
        lock (_gate)
        {
            var expired = _byId.Values.Where(r => !Live(r)).ToList();
            foreach (var registration in expired)
            {
                _byId.Remove(registration.Id);
                _byEndpoint.Remove(registration.EndpointName);
            }

            return expired;
        }
    }

    private bool Live(ClientRegistration registration) => !registration.IsExpired(_time.GetUtcNow(), _gracePeriod);
}

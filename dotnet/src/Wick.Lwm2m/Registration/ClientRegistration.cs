using System.Collections.Immutable;
using System.Globalization;
using Wick.Lwm2m.Links;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.Registration;

/// <summary>
/// Who a request came from, as the transport established it.
/// </summary>
/// <param name="PskIdentity">The PSK identity the DTLS handshake authenticated, or <see langword="null"/> for an unsecured connection.</param>
/// <param name="PeerAddress">
/// The peer's transport address as the adapter renders it (for example <c>203.0.113.7:5684</c>), or
/// <see langword="null"/>. Wick stores it with the registration so the server knows where to send
/// requests, and never interprets it.
/// </param>
public sealed record ClientIdentity(string? PskIdentity, string? PeerAddress = null)
{
    /// <summary>An unsecured peer with no known address.</summary>
    public static ClientIdentity Unsecured { get; } = new(null, null);

    /// <summary>True when the transport authenticated the peer.</summary>
    public bool IsSecure => PskIdentity is not null;
}

/// <summary>
/// One client registration as the server holds it.
/// </summary>
/// <remarks>
/// Immutable. An Update produces a new record with <see cref="LastUpdate"/> moved forward. The
/// registration lapses at <see cref="ExpiresAt"/>, its last update plus its lifetime (OMA LwM2M 1.2
/// §6.2.1), unless refreshed.
/// </remarks>
public sealed record ClientRegistration
{
    private readonly ImmutableArray<Link> _objects;
    private readonly ImmutableArray<QueryParameter> _additional = [];

    /// <summary>Creates a registration.</summary>
    /// <param name="id">The server-assigned registration ID.</param>
    /// <param name="endpointName">The endpoint client name.</param>
    /// <param name="lifetime">The lifetime.</param>
    /// <param name="lwm2mVersion">The LwM2M version in force.</param>
    /// <param name="objects">The Object links from the Register or latest Update.</param>
    /// <param name="registeredAt">When the Register was accepted.</param>
    public ClientRegistration(string id, string endpointName, TimeSpan lifetime, string lwm2mVersion, IEnumerable<Link> objects, DateTimeOffset registeredAt)
    {
        ArgumentException.ThrowIfNullOrEmpty(id);
        ArgumentException.ThrowIfNullOrEmpty(endpointName);
        ArgumentException.ThrowIfNullOrEmpty(lwm2mVersion);
        ArgumentNullException.ThrowIfNull(objects);
        if (lifetime <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(lifetime), "a lifetime must be positive");
        }

        Id = id;
        EndpointName = endpointName;
        Lifetime = lifetime;
        Lwm2mVersion = lwm2mVersion;
        _objects = objects.ToImmutableArray();
        RegisteredAt = registeredAt;
        LastUpdate = registeredAt;
    }

    /// <summary>The server-assigned registration ID, the last segment of the Register response's Location-Path.</summary>
    public string Id { get; }

    /// <summary>The endpoint client name.</summary>
    public string EndpointName { get; }

    /// <summary>The lifetime.</summary>
    public TimeSpan Lifetime { get; init; }

    /// <summary>The LwM2M version in force.</summary>
    public string Lwm2mVersion { get; }

    /// <summary>The binding mode, or <see langword="null"/> when the client declared none.</summary>
    public string? Binding { get; init; }

    /// <summary>Whether the client is in queue mode.</summary>
    public bool QueueMode { get; init; }

    /// <summary>The MSISDN, or <see langword="null"/>.</summary>
    public string? SmsNumber { get; init; }

    /// <summary>The identity the transport established for the Register.</summary>
    public ClientIdentity Identity { get; init; } = ClientIdentity.Unsecured;

    /// <summary>When the Register was accepted.</summary>
    public DateTimeOffset RegisteredAt { get; }

    /// <summary>When the registration was last refreshed by Register or Update.</summary>
    public DateTimeOffset LastUpdate { get; init; }

    /// <summary>When the registration lapses unless refreshed.</summary>
    public DateTimeOffset ExpiresAt => LastUpdate + Lifetime;

    /// <summary>The Object links from the Register or latest Update.</summary>
    public IReadOnlyList<Link> Objects
    {
        get => _objects;
        init => _objects = value?.ToImmutableArray() ?? throw new ArgumentNullException(nameof(value));
    }

    /// <summary>Query parameters other than the standard ones, from the Register.</summary>
    public IReadOnlyList<QueryParameter> AdditionalParameters
    {
        get => _additional;
        init => _additional = value?.ToImmutableArray() ?? throw new ArgumentNullException(nameof(value));
    }

    /// <summary>True when the registration has lapsed at <paramref name="now"/>.</summary>
    /// <param name="now">The current time.</param>
    /// <param name="gracePeriod">Extra time allowed past the lifetime, to absorb network delay.</param>
    /// <returns>Whether it has expired.</returns>
    public bool IsExpired(DateTimeOffset now, TimeSpan gracePeriod = default) => now >= ExpiresAt + gracePeriod;

    /// <summary>
    /// The alternate root path: the target of the link carrying <c>rt="oma.lwm2m"</c>, or <c>/</c> when there is none
    /// (OMA LwM2M 1.2 §6.2.1).
    /// </summary>
    public string RootPath =>
        _objects.FirstOrDefault(l => l.Get("rt") == "oma.lwm2m")?.Target is { } root ? root : "/";

    /// <summary>
    /// The Content-Formats the client declared on its root link with <c>ct</c>, such as
    /// <c>ct="60 110 112 11543"</c>. Empty when it declared none.
    /// </summary>
    public IReadOnlyList<int> SupportedContentFormats
    {
        get
        {
            var root = _objects.FirstOrDefault(l => l.Get("rt") == "oma.lwm2m");
            return root?.Get("ct") is { } ct
                ? ct.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                    .Select(c => int.TryParse(c, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : -1)
                    .Where(v => v >= 0)
                    .ToList()
                : [];
        }
    }

    /// <summary>
    /// The Objects the client supports, keyed by Object ID, with the version from <c>ver</c> or
    /// <see langword="null"/> when the link carries none (meaning the version in the Object's DDF).
    /// </summary>
    public IReadOnlyDictionary<int, string?> SupportedObjects
    {
        get
        {
            var objects = new SortedDictionary<int, string?>();
            foreach (var (link, path) in ObjectLinks())
            {
                if (path.IsObject)
                {
                    objects[path.ObjectId] = link.Get("ver") ?? objects.GetValueOrDefault(path.ObjectId);
                }
                else
                {
                    objects.TryAdd(path.ObjectId, null);
                }
            }

            return objects;
        }
    }

    /// <summary>The Object Instances the client reported, in the order listed.</summary>
    public IReadOnlyList<Lwm2mPath> AvailableInstances =>
        ObjectLinks().Select(x => x.Path).Where(p => p.IsObjectInstance).Distinct().ToList();

    /// <inheritdoc/>
    public bool Equals(ClientRegistration? other) =>
        other is not null && Id == other.Id && EndpointName == other.EndpointName && Lifetime == other.Lifetime &&
        Lwm2mVersion == other.Lwm2mVersion && Binding == other.Binding && QueueMode == other.QueueMode &&
        SmsNumber == other.SmsNumber && Identity == other.Identity && RegisteredAt == other.RegisteredAt &&
        LastUpdate == other.LastUpdate && _objects.SequenceEqual(other._objects) && _additional.SequenceEqual(other._additional);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Id, EndpointName, LastUpdate);

    private IEnumerable<(Link Link, Lwm2mPath Path)> ObjectLinks()
    {
        var root = RootPath.TrimEnd('/');
        foreach (var link in _objects)
        {
            if (link.Get("rt") == "oma.lwm2m")
            {
                continue;
            }

            var target = link.Target;
            if (root.Length > 0)
            {
                if (!target.StartsWith(root + "/", StringComparison.Ordinal))
                {
                    continue;
                }

                target = target[root.Length..];
            }

            if (Lwm2mPath.TryParse(target, out var path) && path.Depth <= 2)
            {
                yield return (link, path);
            }
        }
    }
}

using System.Security.Cryptography;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.Registration;

/// <summary>Settings for <see cref="RegistrationHandler"/>.</summary>
public sealed record RegistrationHandlerOptions
{
    /// <summary>The lifetime given to a Register that does not declare one. OMA LwM2M 1.2 §6.2.1 sets 86400 seconds.</summary>
    public TimeSpan DefaultLifetime { get; init; } = TimeSpan.FromSeconds(86400);

    /// <summary>
    /// Produces registration IDs. The default is ten random characters from a 62-character
    /// alphabet. Clients reveal the ID in every Update, so it is a handle, not a secret.
    /// </summary>
    public Func<string> NewRegistrationId { get; init; } = RandomRegistrationId;

    /// <summary>The default registration ID generator.</summary>
    /// <returns>A new ID.</returns>
    public static string RandomRegistrationId() =>
        RandomNumberGenerator.GetString("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", 10);
}

/// <summary>What a Registration Interface request did.</summary>
/// <param name="Response">The response to send the client.</param>
public sealed record RegistrationOutcome(WireResponse Response)
{
    /// <summary>The operation the request was, or <see langword="null"/> when it was not recognised.</summary>
    public RegistrationOperation? Operation { get; init; }

    /// <summary>The registration as it now stands after a successful Register or Update, otherwise <see langword="null"/>.</summary>
    public ClientRegistration? Registration { get; init; }

    /// <summary>
    /// The registration this one displaced or ended: the earlier registration of the same endpoint
    /// that a Register replaced, the state before an Update, or the registration a Deregister removed.
    /// </summary>
    /// <remarks>A server drops the observations of a replaced or deregistered registration (OMA LwM2M 1.2 §6.2).</remarks>
    public ClientRegistration? Previous { get; init; }

    /// <summary>True when the request succeeded.</summary>
    public bool IsSuccess => Response.Code.IsSuccess;
}

/// <summary>
/// The server side of the Registration Interface (OMA LwM2M 1.2 §6.2): takes a Register, Update or
/// Deregister in wire form, applies it to the store, and returns the response.
/// </summary>
/// <remarks>
/// <para>
/// The handler holds no state of its own. Time comes from the injected <see cref="TimeProvider"/>,
/// registrations from the injected store, and every decision about identity from the injected
/// authoriser, so the same handler runs behind any transport and is testable without one.
/// </para>
/// <para>
/// Responses: 2.01 Created with Location-Path <c>rd/{id}</c> for Register, 2.04 Changed for Update,
/// 2.02 Deleted for Deregister; 4.00 for malformed requests, 4.03 when refused, 4.04 for an unknown or
/// expired registration, 4.05 for a method the path does not support, and 4.12 for an unsupported
/// LwM2M version. Error responses carry a diagnostic payload.
/// </para>
/// </remarks>
public sealed class RegistrationHandler
{
    private readonly IRegistrationStore _store;
    private readonly IRegistrationAuthoriser _authoriser;
    private readonly TimeProvider _time;
    private readonly RegistrationHandlerOptions _options;

    /// <summary>Creates a handler.</summary>
    /// <param name="store">Where registrations live.</param>
    /// <param name="authoriser">Who may register.</param>
    /// <param name="time">The clock.</param>
    /// <param name="options">Settings, or <see langword="null"/> for the defaults.</param>
    public RegistrationHandler(IRegistrationStore store, IRegistrationAuthoriser authoriser, TimeProvider time, RegistrationHandlerOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(authoriser);
        ArgumentNullException.ThrowIfNull(time);
        _store = store;
        _authoriser = authoriser;
        _time = time;
        _options = options ?? new RegistrationHandlerOptions();
        if (_options.DefaultLifetime <= TimeSpan.Zero)
        {
            throw new ArgumentException("the default lifetime must be positive", nameof(options));
        }
    }

    /// <summary>True when <paramref name="request"/> is addressed to the Registration Interface (<c>/rd</c>).</summary>
    /// <param name="request">The request.</param>
    /// <returns>Whether it belongs to this handler.</returns>
    public static bool IsRegistrationRequest(WireRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return request.Path.Count is 1 or 2 && request.Path[0] == "rd";
    }

    /// <summary>Handles one Registration Interface request.</summary>
    /// <param name="request">The request as it arrived.</param>
    /// <param name="identity">Who sent it, as the transport established.</param>
    /// <returns>The response and what changed.</returns>
    public RegistrationOutcome Handle(WireRequest request, ClientIdentity identity)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(identity);
        if (!IsRegistrationRequest(request))
        {
            return Error(ResponseCode.NotFound, null, $"no Registration Interface resource at /{string.Join('/', request.Path)}");
        }

        try
        {
            return (request.Path.Count, request.Method) switch
            {
                (1, Method.Post) => Register(RegisterRequest.Parse(request), identity),
                (2, Method.Post) => Update(UpdateRequest.Parse(request), identity),
                (2, Method.Delete) => Deregister(DeregisterRequest.Parse(request), identity),
                _ => Error(ResponseCode.MethodNotAllowed, null, $"{request.Method} is not allowed on /{string.Join('/', request.Path)}"),
            };
        }
        catch (RegistrationRequestException e)
        {
            var operation = request.Path.Count == 1 ? RegistrationOperation.Register
                : request.Method == Method.Delete ? RegistrationOperation.Deregister
                : RegistrationOperation.Update;
            return Error(e.Code, operation, e.Message);
        }
    }

    /// <summary>Handles a parsed Register.</summary>
    /// <param name="request">The Register.</param>
    /// <param name="identity">Who sent it.</param>
    /// <returns>The response and what changed.</returns>
    public RegistrationOutcome Register(RegisterRequest request, ClientIdentity identity)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(identity);
        var decision = _authoriser.Authorise(new RegistrationAuthorisationContext(RegistrationOperation.Register, identity, request.EndpointName, null));
        if (!decision.Allowed)
        {
            return Error(ResponseCode.Forbidden, RegistrationOperation.Register, null);
        }

        var registration = new ClientRegistration(
            _options.NewRegistrationId(),
            request.EndpointName,
            request.Lifetime is { } lt ? TimeSpan.FromSeconds(lt) : _options.DefaultLifetime,
            request.EffectiveVersion,
            request.Objects,
            _time.GetUtcNow())
        {
            Binding = request.Binding,
            QueueMode = request.QueueMode,
            SmsNumber = request.SmsNumber,
            Identity = identity,
            AdditionalParameters = request.AdditionalParameters,
        };

        var replaced = _store.Add(registration);
        return new RegistrationOutcome(new WireResponse(ResponseCode.Created) { LocationPath = ["rd", registration.Id] })
        {
            Operation = RegistrationOperation.Register,
            Registration = registration,
            Previous = replaced,
        };
    }

    /// <summary>Handles a parsed Update.</summary>
    /// <param name="request">The Update.</param>
    /// <param name="identity">Who sent it.</param>
    /// <returns>The response and what changed.</returns>
    public RegistrationOutcome Update(UpdateRequest request, ClientIdentity identity)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(identity);
        var existing = _store.Get(request.RegistrationId);
        if (existing is null)
        {
            return Error(ResponseCode.NotFound, RegistrationOperation.Update, $"no registration {request.RegistrationId}");
        }

        if (Refused(RegistrationOperation.Update, identity, existing))
        {
            return Error(ResponseCode.Forbidden, RegistrationOperation.Update, null);
        }

        if (request.Binding is { } binding)
        {
            try
            {
                RegistrationParsing.CheckBinding(binding, existing.Lwm2mVersion);
            }
            catch (RegistrationRequestException e)
            {
                return Error(e.Code, RegistrationOperation.Update, e.Message);
            }
        }

        var updated = existing with
        {
            Lifetime = request.Lifetime is { } lt ? TimeSpan.FromSeconds(lt) : existing.Lifetime,
            Binding = request.Binding ?? existing.Binding,
            SmsNumber = request.SmsNumber ?? existing.SmsNumber,
            Objects = request.Objects ?? existing.Objects,
            Identity = identity with { PeerAddress = identity.PeerAddress ?? existing.Identity.PeerAddress },
            LastUpdate = _time.GetUtcNow(),
        };

        var previous = _store.Update(updated);
        return previous is null
            ? Error(ResponseCode.NotFound, RegistrationOperation.Update, $"no registration {request.RegistrationId}")
            : new RegistrationOutcome(new WireResponse(ResponseCode.Changed))
            {
                Operation = RegistrationOperation.Update,
                Registration = updated,
                Previous = previous,
            };
    }

    /// <summary>Handles a parsed Deregister.</summary>
    /// <param name="request">The Deregister.</param>
    /// <param name="identity">Who sent it.</param>
    /// <returns>The response and what changed.</returns>
    public RegistrationOutcome Deregister(DeregisterRequest request, ClientIdentity identity)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(identity);
        var existing = _store.Get(request.RegistrationId);
        if (existing is null)
        {
            return Error(ResponseCode.NotFound, RegistrationOperation.Deregister, $"no registration {request.RegistrationId}");
        }

        if (Refused(RegistrationOperation.Deregister, identity, existing))
        {
            return Error(ResponseCode.Forbidden, RegistrationOperation.Deregister, null);
        }

        var removed = _store.Remove(request.RegistrationId);
        return removed is null
            ? Error(ResponseCode.NotFound, RegistrationOperation.Deregister, $"no registration {request.RegistrationId}")
            : new RegistrationOutcome(new WireResponse(ResponseCode.Deleted))
            {
                Operation = RegistrationOperation.Deregister,
                Previous = removed,
            };
    }

    // An Update or Deregister must come from the identity that registered (OMA LwM2M 1.2 §6.2.2 and
    // §7.2: the same security context), whatever the authoriser would say.
    private bool Refused(RegistrationOperation operation, ClientIdentity identity, ClientRegistration existing) =>
        identity.PskIdentity != existing.Identity.PskIdentity ||
        !_authoriser.Authorise(new RegistrationAuthorisationContext(operation, identity, existing.EndpointName, existing)).Allowed;

    private static RegistrationOutcome Error(ResponseCode code, RegistrationOperation? operation, string? diagnostic) =>
        new(new WireResponse(code) { Payload = diagnostic is null ? ReadOnlyMemory<byte>.Empty : System.Text.Encoding.UTF8.GetBytes(diagnostic) })
        {
            Operation = operation,
        };
}

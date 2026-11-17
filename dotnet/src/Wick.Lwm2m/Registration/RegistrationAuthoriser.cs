namespace Wick.Lwm2m.Registration;

/// <summary>The Registration Interface operation being authorised.</summary>
public enum RegistrationOperation
{
    /// <summary>Register.</summary>
    Register,

    /// <summary>Update.</summary>
    Update,

    /// <summary>Deregister.</summary>
    Deregister,
}

/// <summary>What an authoriser is asked to decide on.</summary>
/// <param name="Operation">The operation.</param>
/// <param name="Identity">The identity the transport authenticated.</param>
/// <param name="EndpointName">The endpoint client name: from the Register, or from the existing registration for Update and Deregister.</param>
/// <param name="Existing">The registration being updated or removed, or <see langword="null"/> for Register.</param>
public sealed record RegistrationAuthorisationContext(
    RegistrationOperation Operation,
    ClientIdentity Identity,
    string EndpointName,
    ClientRegistration? Existing);

/// <summary>An authoriser's answer.</summary>
/// <param name="Allowed">Whether the operation may proceed.</param>
/// <param name="Reason">Why it was refused, for logs, or <see langword="null"/>. Not sent to the client.</param>
public sealed record AuthorisationDecision(bool Allowed, string? Reason = null)
{
    /// <summary>Allow the operation.</summary>
    public static AuthorisationDecision Allow { get; } = new(true);

    /// <summary>Refuse the operation.</summary>
    /// <param name="reason">Why, for logs.</param>
    /// <returns>The decision.</returns>
    public static AuthorisationDecision Deny(string? reason = null) => new(false, reason);
}

/// <summary>
/// Decides whether a Register, Update or Deregister may proceed, given the identity the transport
/// authenticated. A refusal is answered with 4.03 Forbidden.
/// </summary>
/// <remarks>
/// <see cref="RegistrationHandler"/> asks before it changes any state. Independently of the
/// authoriser, it refuses an Update or Deregister whose identity differs from the one that
/// registered, so one client cannot refresh or remove another's registration.
/// </remarks>
public interface IRegistrationAuthoriser
{
    /// <summary>Decides on one operation.</summary>
    /// <param name="context">The operation, identity and endpoint.</param>
    /// <returns>The decision.</returns>
    AuthorisationDecision Authorise(RegistrationAuthorisationContext context);
}

/// <summary>Ready-made authorisers.</summary>
public static class RegistrationAuthorisers
{
    /// <summary>Allows every operation. Suitable for tests and unsecured development servers only.</summary>
    public static IRegistrationAuthoriser AllowAll { get; } = new DelegateAuthoriser(_ => AuthorisationDecision.Allow);

    /// <summary>
    /// Requires a secured connection whose PSK identity equals the endpoint name, the common
    /// provisioning convention. Unsecured peers are refused.
    /// </summary>
    public static IRegistrationAuthoriser PskIdentityMatchesEndpoint { get; } = new DelegateAuthoriser(context =>
        context.Identity.PskIdentity is null ? AuthorisationDecision.Deny("the connection is not secured")
        : context.Identity.PskIdentity == context.EndpointName ? AuthorisationDecision.Allow
        : AuthorisationDecision.Deny($"PSK identity \"{context.Identity.PskIdentity}\" may not act for endpoint \"{context.EndpointName}\""));

    /// <summary>Wraps a function as an authoriser, typically one that looks the PSK identity up in a device database.</summary>
    /// <param name="decide">The decision function.</param>
    /// <returns>The authoriser.</returns>
    public static IRegistrationAuthoriser From(Func<RegistrationAuthorisationContext, AuthorisationDecision> decide)
    {
        ArgumentNullException.ThrowIfNull(decide);
        return new DelegateAuthoriser(decide);
    }

    private sealed class DelegateAuthoriser(Func<RegistrationAuthorisationContext, AuthorisationDecision> decide) : IRegistrationAuthoriser
    {
        public AuthorisationDecision Authorise(RegistrationAuthorisationContext context) =>
            decide(context ?? throw new ArgumentNullException(nameof(context)));
    }
}

using Wick.Coap.Transport;

namespace Wick.Coap;

/// <summary>Handles inbound requests on a <see cref="CoapEndpoint"/>.</summary>
public interface ICoapRequestHandler
{
    /// <summary>
    /// Produces the response to a request. The endpoint fills in the type, message id and
    /// token, splits a large payload into blocks, and adds the Observe option when the
    /// request registered an observation. Return null to send no response: a confirmable
    /// request then receives only an empty acknowledgement.
    /// </summary>
    /// <remarks>
    /// The call is made on the receive path and should not block. If it has not completed
    /// within <see cref="CoapEndpointOptions.SeparateResponseDelay"/> the endpoint acknowledges
    /// the request and sends the response separately once it is ready (RFC 7252 section 5.2.2).
    /// </remarks>
    /// <param name="context">The request and where it came from.</param>
    /// <returns>The response, or null.</returns>
    ValueTask<CoapMessage?> HandleAsync(CoapRequestContext context);
}

/// <summary>What the Observe option in a request asks for (RFC 7641 section 2).</summary>
public enum ObserveAction
{
    /// <summary>The request has no Observe option, or it is a method that cannot observe.</summary>
    None,

    /// <summary>Observe: 0, register an observation.</summary>
    Register,

    /// <summary>Observe: 1, cancel an observation.</summary>
    Deregister,
}

/// <summary>An inbound request as a handler sees it.</summary>
public sealed class CoapRequestContext
{
    internal CoapRequestContext(CoapEndpoint endpoint, ICoapPeer peer, CoapMessage request, ObserveAction observe, CancellationToken aborted)
    {
        Endpoint = endpoint;
        Peer = peer;
        Request = request;
        Observe = observe;
        Aborted = aborted;
    }

    /// <summary>The endpoint the request arrived on.</summary>
    public CoapEndpoint Endpoint { get; }

    /// <summary>The peer the request came from.</summary>
    public ICoapPeer Peer { get; }

    /// <summary>
    /// The request. When it arrived block-wise (Block1) the payload is the reassembled body and
    /// the Block1 option has been removed.
    /// </summary>
    public CoapMessage Request { get; }

    /// <summary>What the Observe option asks for. A successful response to a registration creates an observation.</summary>
    public ObserveAction Observe { get; }

    /// <summary>The PSK identity the peer authenticated with, or null on an unsecured transport.</summary>
    public string? PskIdentity => Peer.Security?.PskIdentity;

    /// <summary>Cancelled when the endpoint shuts down or the peer's session ends.</summary>
    public CancellationToken Aborted { get; }
}

/// <summary>Adapts a delegate to <see cref="ICoapRequestHandler"/>.</summary>
public sealed class DelegateRequestHandler : ICoapRequestHandler
{
    private readonly Func<CoapRequestContext, ValueTask<CoapMessage?>> _handler;

    /// <summary>Wraps a delegate.</summary>
    /// <param name="handler">The delegate.</param>
    public DelegateRequestHandler(Func<CoapRequestContext, ValueTask<CoapMessage?>> handler) =>
        _handler = handler ?? throw new ArgumentNullException(nameof(handler));

    /// <inheritdoc />
    public ValueTask<CoapMessage?> HandleAsync(CoapRequestContext context) => _handler(context);
}

/// <summary>
/// Routes requests to handlers by Uri-Path prefix. The longest matching prefix wins; a
/// request that matches nothing receives 4.04 Not Found.
/// </summary>
public sealed class CoapRouter : ICoapRequestHandler
{
    private readonly List<(string[] Prefix, ICoapRequestHandler Handler)> _routes = [];
    private readonly object _gate = new();

    /// <summary>Maps a path prefix to a handler.</summary>
    /// <param name="pathPrefix">A prefix such as <c>/rd</c>; <c>/</c> matches everything.</param>
    /// <param name="handler">The handler.</param>
    /// <returns>The router, for chaining.</returns>
    public CoapRouter Map(string pathPrefix, ICoapRequestHandler handler)
    {
        ArgumentNullException.ThrowIfNull(pathPrefix);
        ArgumentNullException.ThrowIfNull(handler);
        var prefix = pathPrefix.Split('/', StringSplitOptions.RemoveEmptyEntries);
        lock (_gate)
        {
            _routes.RemoveAll(r => r.Prefix.SequenceEqual(prefix));
            _routes.Add((prefix, handler));
            _routes.Sort((a, b) => b.Prefix.Length.CompareTo(a.Prefix.Length));
        }
        return this;
    }

    /// <summary>Maps a path prefix to a delegate.</summary>
    /// <param name="pathPrefix">A prefix such as <c>/rd</c>.</param>
    /// <param name="handler">The delegate.</param>
    /// <returns>The router, for chaining.</returns>
    public CoapRouter Map(string pathPrefix, Func<CoapRequestContext, ValueTask<CoapMessage?>> handler) =>
        Map(pathPrefix, new DelegateRequestHandler(handler));

    /// <inheritdoc />
    public ValueTask<CoapMessage?> HandleAsync(CoapRequestContext context)
    {
        var path = context.Request.UriPath;
        ICoapRequestHandler? match = null;
        lock (_gate)
        {
            foreach (var (prefix, handler) in _routes)
            {
                if (prefix.Length <= path.Count && prefix.SequenceEqual(path.Take(prefix.Length), StringComparer.Ordinal))
                {
                    match = handler;
                    break;
                }
            }
        }
        return match is null
            ? ValueTask.FromResult<CoapMessage?>(CoapMessage.CreateResponse(CoapCode.NotFound))
            : match.HandleAsync(context);
    }
}

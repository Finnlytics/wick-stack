using System.Collections.Concurrent;
using System.Net;
using Wick.Coap.Dtls;
using Wick.Coap.Transport;

namespace Wick.Coap.Tests.Support;

/// <summary>
/// A CoAP server over DTLS that answers the LwM2M registration interface just enough for
/// real clients: <c>POST /rd</c> creates a registration, <c>POST /rd/{id}</c> updates it,
/// <c>DELETE /rd/{id}</c> removes it.
/// </summary>
public sealed class RegistrationServer : IAsyncDisposable
{
    public const string Identity = "wick-test-device";
    public static readonly byte[] Key = Convert.FromHexString("00112233445566778899AABBCCDDEEFF");

    private int _nextId;

    private RegistrationServer(DtlsServerTransport transport, CoapEndpoint endpoint)
    {
        Transport = transport;
        Endpoint = endpoint;
    }

    public DtlsServerTransport Transport { get; }
    public CoapEndpoint Endpoint { get; }
    public IPEndPoint LocalEndPoint => (IPEndPoint)Transport.LocalEndPoint;
    public ConcurrentQueue<(string Kind, ICoapPeer Peer, string? Identity, EndPoint Address, CoapMessage Request)> Events { get; } = new();
    public ConcurrentDictionary<string, ICoapPeer> Registrations { get; } = new();

    public static async Task<RegistrationServer> StartAsync(DtlsServerOptions? options = null, IPskStore? store = null)
    {
        options ??= new DtlsServerOptions();
        options = options with { LocalEndPoint = new IPEndPoint(IPAddress.Loopback, 0) };
        store ??= new InMemoryPskStore().Set(Identity, Key);
        var transport = new DtlsServerTransport(options, store);
        var router = new CoapRouter();
        var endpoint = new CoapEndpoint(transport, handler: router);
        var server = new RegistrationServer(transport, endpoint);
        router.Map("/rd", server.HandleAsync);
        await endpoint.StartAsync();
        return server;
    }

    private ValueTask<CoapMessage?> HandleAsync(CoapRequestContext context)
    {
        var path = context.Request.UriPath;
        var request = context.Request;
        if (request.Code == CoapCode.Post && path.Count == 1)
        {
            var id = "r" + Interlocked.Increment(ref _nextId);
            Registrations[id] = context.Peer;
            Events.Enqueue(("register", context.Peer, context.PskIdentity, context.Peer.RemoteEndPoint, request));
            var created = CoapMessage.CreateResponse(CoapCode.Created);
            created.SetLocationPath(["rd", id]);
            return ValueTask.FromResult<CoapMessage?>(created);
        }
        if (request.Code == CoapCode.Post && path.Count == 2 && Registrations.ContainsKey(path[1]))
        {
            Events.Enqueue(("update", context.Peer, context.PskIdentity, context.Peer.RemoteEndPoint, request));
            Registrations[path[1]] = context.Peer;
            return ValueTask.FromResult<CoapMessage?>(CoapMessage.CreateResponse(CoapCode.Changed));
        }
        if (request.Code == CoapCode.Delete && path.Count == 2 && Registrations.TryRemove(path[1], out _))
        {
            Events.Enqueue(("deregister", context.Peer, context.PskIdentity, context.Peer.RemoteEndPoint, request));
            return ValueTask.FromResult<CoapMessage?>(CoapMessage.CreateResponse(CoapCode.Deleted));
        }
        return ValueTask.FromResult<CoapMessage?>(CoapMessage.CreateResponse(CoapCode.NotFound));
    }

    /// <summary>Waits, in real time, for an event of a kind to be recorded.</summary>
    public async Task<(string Kind, ICoapPeer Peer, string? Identity, EndPoint Address, CoapMessage Request)> WaitForAsync(string kind, int occurrence, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var matches = Events.Where(e => e.Kind == kind).ToList();
            if (matches.Count >= occurrence) return matches[occurrence - 1];
            await Task.Delay(50);
        }
        throw new TimeoutException($"No {kind} number {occurrence} within {timeout}.");
    }

    public async ValueTask DisposeAsync() => await Endpoint.DisposeAsync();
}

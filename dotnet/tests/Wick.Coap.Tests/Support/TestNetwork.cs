using System.Net;
using Wick.Coap.Transport;

namespace Wick.Coap.Tests.Support;

/// <summary>A client and a server endpoint on an in-memory network with a manual clock.</summary>
public sealed class TestNetwork : IAsyncDisposable
{
    public static readonly IPEndPoint ClientAddress = new(IPAddress.Parse("10.0.0.1"), 40000);
    public static readonly IPEndPoint ServerAddress = new(IPAddress.Parse("10.0.0.2"), 5683);

    private TestNetwork(InMemoryNetwork network, ManualTimeProvider time, CoapEndpoint client, CoapEndpoint server, InMemoryTransport clientTransport, InMemoryTransport serverTransport)
    {
        Network = network;
        Time = time;
        Client = client;
        Server = server;
        ClientTransport = clientTransport;
        ServerTransport = serverTransport;
    }

    public InMemoryNetwork Network { get; }
    public ManualTimeProvider Time { get; }
    public CoapEndpoint Client { get; }
    public CoapEndpoint Server { get; }
    public InMemoryTransport ClientTransport { get; }
    public InMemoryTransport ServerTransport { get; }

    /// <summary>The server as the client sees it.</summary>
    public ICoapPeer ServerPeer => ClientTransport.PeerFor(ServerAddress);

    /// <summary>The client as the server sees it.</summary>
    public ICoapPeer ClientPeer => ServerTransport.PeerFor(ClientAddress);

    /// <summary>Deterministic RFC timing: no randomisation of the initial timeout.</summary>
    public static CoapEndpointOptions DeterministicOptions => new()
    {
        Transmission = new CoapTransmissionParameters { AckRandomFactor = 1.0 },
    };

    public static async Task<TestNetwork> CreateAsync(
        ICoapRequestHandler? serverHandler = null,
        CoapEndpointOptions? clientOptions = null,
        CoapEndpointOptions? serverOptions = null,
        ICoapRequestHandler? clientHandler = null)
    {
        var network = new InMemoryNetwork();
        var time = new ManualTimeProvider();
        var clientTransport = network.CreateTransport(ClientAddress);
        var serverTransport = network.CreateTransport(ServerAddress);
        var client = new CoapEndpoint(clientTransport, clientOptions ?? DeterministicOptions, clientHandler, time);
        var server = new CoapEndpoint(serverTransport, serverOptions ?? DeterministicOptions, serverHandler, time);
        await client.StartAsync();
        await server.StartAsync();
        return new TestNetwork(network, time, client, server, clientTransport, serverTransport);
    }

    /// <summary>Pumps the network until the task completes.</summary>
    public async Task<T> Run<T>(Task<T> task)
    {
        await Network.RunUntilAsync(task);
        return await task;
    }

    /// <summary>Pumps the network until the task completes.</summary>
    public async Task Run(Task task) => await Network.RunUntilAsync(task);

    /// <summary>Delivers everything queued, including replies it provokes.</summary>
    public int Deliver() => Network.RunUntilIdle();

    /// <summary>Advances the clock, then delivers what the timers sent.</summary>
    public int Advance(TimeSpan by)
    {
        Time.Advance(by);
        return Network.RunUntilIdle();
    }

    /// <summary>Datagrams from one address to the other, decoded.</summary>
    public List<CoapMessage> SentBy(IPEndPoint from) =>
        [.. Network.Sent.Where(d => d.From.Equals(from)).Select(d => d.Message!)];

    public async ValueTask DisposeAsync()
    {
        await Client.DisposeAsync();
        await Server.DisposeAsync();
    }
}

/// <summary>Handler helpers for tests.</summary>
public static class Handlers
{
    public static ICoapRequestHandler From(Func<CoapRequestContext, CoapMessage?> handler) =>
        new DelegateRequestHandler(context => ValueTask.FromResult(handler(context)));

    public static ICoapRequestHandler From(Func<CoapRequestContext, ValueTask<CoapMessage?>> handler) =>
        new DelegateRequestHandler(handler);

    public static CoapMessage Content(string text) =>
        CoapMessage.CreateResponse(CoapCode.Content, System.Text.Encoding.UTF8.GetBytes(text), CoapContentFormat.TextPlain);

    public static CoapMessage Content(byte[] body) =>
        CoapMessage.CreateResponse(CoapCode.Content, body, CoapContentFormat.OctetStream);
}

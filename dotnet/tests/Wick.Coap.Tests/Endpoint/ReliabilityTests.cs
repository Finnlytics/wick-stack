using Wick.Coap.Tests.Support;
using Wick.Coap.Transport;

namespace Wick.Coap.Tests.Endpoint;

public class ReliabilityTests
{
    private static readonly TimeSpan Second = TimeSpan.FromSeconds(1);

    private static ICoapRequestHandler Hello(Action? onCall = null) => Handlers.From(context =>
    {
        onCall?.Invoke();
        return Handlers.Content("hello " + string.Join('/', context.Request.UriPath));
    });

    [Fact]
    public async Task A_confirmable_get_gets_a_piggybacked_response()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/world")));

        Assert.Equal(CoapCode.Content, response.Code);
        Assert.Equal(CoapMessageType.Acknowledgement, response.Type);
        Assert.Equal("hello world", response.PayloadAsString());
        var request = Assert.Single(net.SentBy(TestNetwork.ClientAddress));
        Assert.Equal(request.MessageId, response.MessageId);
        Assert.Equal(request.Token, response.Token);
        Assert.Equal(8, request.Token.Length);
    }

    [Fact]
    public async Task Concurrent_requests_are_matched_to_their_own_responses()
    {
        var options = TestNetwork.DeterministicOptions with { Transmission = new CoapTransmissionParameters { AckRandomFactor = 1.0, NStart = 8 } };
        await using var net = await TestNetwork.CreateAsync(Hello(), clientOptions: options);
        var tasks = Enumerable.Range(0, 8).Select(i => net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, $"/r{i}"))).ToArray();
        await net.Run(Task.WhenAll(tasks));
        var results = await Task.WhenAll(tasks);
        for (int i = 0; i < results.Length; i++) Assert.Equal($"hello r{i}", results[i].PayloadAsString());
    }

    [Fact]
    public async Task Nstart_1_holds_a_second_request_until_the_first_completes()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        var first = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/a"));
        var second = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/b"));

        Assert.Equal(1, net.Network.Pending);
        await net.Run(Task.WhenAll(first, second));
        var sent = net.SentBy(TestNetwork.ClientAddress);
        Assert.Equal(["a", "b"], sent.Select(m => m.UriPath[0]));
    }

    [Fact]
    public async Task A_lost_request_is_retransmitted_on_the_rfc_schedule()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        int drops = 2;
        net.Network.Fate = d => d.From.Equals(TestNetwork.ClientAddress) && drops-- > 0 ? 0 : 1;

        var pending = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/x"));
        net.Deliver();
        net.Advance(2 * Second);   // first retransmission at ACK_TIMEOUT, also lost
        Assert.False(pending.IsCompleted);
        net.Advance(4 * Second);   // second at 2 x ACK_TIMEOUT later, delivered
        var response = await net.Run(pending);

        Assert.Equal(CoapCode.Content, response.Code);
        var transmissions = net.SentBy(TestNetwork.ClientAddress);
        Assert.Equal(3, transmissions.Count);
        Assert.Single(transmissions.Select(m => m.MessageId).Distinct());
    }

    [Fact]
    public async Task Gives_up_after_max_retransmit_and_reports_a_timeout()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        net.Network.Fate = _ => 0;
        var pending = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/x"));

        // Transmissions at 0, 2, 6, 14 and 30 seconds; give up at 62 (RFC 7252 section 4.2).
        net.Advance(61 * Second);
        Assert.False(pending.IsCompleted);
        Assert.Equal(5, net.Network.Sent.Count);
        net.Advance(Second);
        await Assert.ThrowsAsync<CoapTimeoutException>(() => pending);
        Assert.Equal(5, net.Network.Sent.Count);
    }

    [Fact]
    public async Task A_lost_ack_makes_the_server_resend_its_cached_reply_without_rerunning_the_handler()
    {
        int calls = 0;
        await using var net = await TestNetwork.CreateAsync(Hello(() => calls++));
        int drops = 1;
        net.Network.Fate = d => d.From.Equals(TestNetwork.ServerAddress) && drops-- > 0 ? 0 : 1;

        var pending = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/x"));
        net.Deliver();
        net.Advance(2 * Second);
        var response = await net.Run(pending);

        Assert.Equal("hello x", response.PayloadAsString());
        Assert.Equal(1, calls);
        var replies = net.SentBy(TestNetwork.ServerAddress);
        Assert.Equal(2, replies.Count);
        Assert.Equal(replies[0].Encode(), replies[1].Encode());
    }

    [Fact]
    public async Task Duplicated_datagrams_are_processed_once()
    {
        int calls = 0;
        await using var net = await TestNetwork.CreateAsync(Hello(() => calls++));
        net.Network.Fate = _ => 3;
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/x")));
        Assert.Equal("hello x", response.PayloadAsString());
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task A_slow_handler_gets_an_empty_ack_then_a_confirmable_separate_response()
    {
        var gate = new TaskCompletionSource<CoapMessage?>();
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => new ValueTask<CoapMessage?>(gate.Task)));
        var pending = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/slow"));
        net.Deliver();
        Assert.Empty(net.SentBy(TestNetwork.ServerAddress));

        net.Advance(Second);
        var ack = Assert.Single(net.SentBy(TestNetwork.ServerAddress));
        Assert.Equal(CoapMessageType.Acknowledgement, ack.Type);
        Assert.True(ack.IsEmpty);

        // The client has stopped retransmitting: nothing more from it at the old schedule.
        net.Advance(10 * Second);
        Assert.Single(net.SentBy(TestNetwork.ClientAddress));

        gate.SetResult(Handlers.Content("done"));
        var response = await net.Run(pending);
        Assert.Equal("done", response.PayloadAsString());
        Assert.Equal(CoapMessageType.Confirmable, response.Type);

        // The client acknowledged the separate response, so the server does not retransmit it.
        var clientAck = net.SentBy(TestNetwork.ClientAddress).Last();
        Assert.Equal(CoapMessageType.Acknowledgement, clientAck.Type);
        Assert.Equal(response.MessageId, clientAck.MessageId);
        int before = net.Network.Sent.Count;
        net.Advance(60 * Second);
        Assert.Equal(before, net.Network.Sent.Count);
    }

    [Fact]
    public async Task A_lost_ack_of_a_separate_response_is_answered_again_from_the_cache()
    {
        var gate = new TaskCompletionSource<CoapMessage?>();
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => new ValueTask<CoapMessage?>(gate.Task)));
        var pending = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/slow"));
        net.Deliver();
        net.Advance(Second);
        gate.SetResult(Handlers.Content("done"));
        await net.Run(pending);

        // Pretend the client's ACK was lost: the server's retransmission arrives again.
        var separate = net.SentBy(TestNetwork.ServerAddress).Last();
        net.Network.Inject(new InMemoryDatagram(TestNetwork.ServerAddress, TestNetwork.ClientAddress, separate.Encode()));
        net.Deliver();
        var acks = net.SentBy(TestNetwork.ClientAddress).Where(m => m.Type == CoapMessageType.Acknowledgement).ToList();
        Assert.Equal(2, acks.Count);
        Assert.All(acks, a => Assert.Equal(separate.MessageId, a.MessageId));
    }

    [Fact]
    public async Task A_separate_response_is_retransmitted_until_acknowledged()
    {
        var gate = new TaskCompletionSource<CoapMessage?>();
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => new ValueTask<CoapMessage?>(gate.Task)));
        var pending = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/slow"));
        net.Deliver();
        net.Advance(Second);

        int drops = 1;
        net.Network.Fate = d => d.From.Equals(TestNetwork.ServerAddress) && drops-- > 0 ? 0 : 1;
        // The handler's continuation sends the separate response, which is dropped.
        int sentBefore = net.Network.Sent.Count;
        gate.SetResult(Handlers.Content("done"));
        await net.Network.WaitForSentAsync(sentBefore + 1);
        net.Deliver();
        Assert.False(pending.IsCompleted);
        net.Advance(2 * Second);
        var response = await net.Run(pending);
        Assert.Equal("done", response.PayloadAsString());
        Assert.Equal(2, net.SentBy(TestNetwork.ServerAddress).Count(m => m.Type == CoapMessageType.Confirmable));
    }

    [Fact]
    public async Task A_reset_fails_the_request()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        var pending = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/x"));
        var request = net.Network.TakePending().Single().Message!;
        var reset = new CoapMessage { Type = CoapMessageType.Reset, MessageId = request.MessageId };
        net.Network.Inject(new InMemoryDatagram(TestNetwork.ServerAddress, TestNetwork.ClientAddress, reset.Encode()));
        net.Deliver();
        await Assert.ThrowsAsync<CoapResetException>(() => pending);
    }

    [Fact]
    public async Task A_ping_is_answered_with_a_reset()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        await net.Run(net.Client.PingAsync(net.ServerPeer));
        var pong = Assert.Single(net.SentBy(TestNetwork.ServerAddress));
        Assert.Equal(CoapMessageType.Reset, pong.Type);
        Assert.Equal(net.SentBy(TestNetwork.ClientAddress)[0].MessageId, pong.MessageId);
    }

    [Fact]
    public async Task A_non_confirmable_request_gets_a_non_confirmable_response()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/n", CoapMessageType.NonConfirmable)));
        Assert.Equal(CoapMessageType.NonConfirmable, response.Type);
        Assert.Equal("hello n", response.PayloadAsString());
        Assert.NotEqual(net.SentBy(TestNetwork.ClientAddress)[0].MessageId, response.MessageId);
    }

    [Fact]
    public async Task An_unrecognised_critical_option_is_answered_with_bad_option()
    {
        int calls = 0;
        await using var net = await TestNetwork.CreateAsync(Hello(() => calls++));
        var request = CoapMessage.CreateRequest(CoapCode.Get, "/x").AddOption(new CoapOption(2049, [1]));
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, request));
        Assert.Equal(CoapCode.BadOption, response.Code);
        Assert.Equal(0, calls);
    }

    [Fact]
    public async Task An_unrecognised_elective_option_is_ignored()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        var request = CoapMessage.CreateRequest(CoapCode.Get, "/x").AddOption(new CoapOption(2048, [1]));
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, request));
        Assert.Equal(CoapCode.Content, response.Code);
    }

    [Fact]
    public async Task Proxy_requests_are_refused()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        var request = CoapMessage.CreateRequest(CoapCode.Get).AddOption(CoapOption.FromString(CoapOptionNumber.ProxyUri, "coap://elsewhere/x"));
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, request));
        Assert.Equal(CoapCode.ProxyingNotSupported, response.Code);
    }

    [Fact]
    public async Task A_malformed_confirmable_message_is_reset()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        net.Network.Inject(new InMemoryDatagram(TestNetwork.ClientAddress, TestNetwork.ServerAddress, [0x40, 0x01, 0x12, 0x34, 0x0F]));
        net.Deliver();
        var reset = Assert.Single(net.SentBy(TestNetwork.ServerAddress));
        Assert.Equal(CoapMessageType.Reset, reset.Type);
        Assert.Equal(0x1234, reset.MessageId);
    }

    [Fact]
    public async Task A_handler_exception_becomes_internal_server_error()
    {
        await using var net = await TestNetwork.CreateAsync(Handlers.From(new Func<CoapRequestContext, CoapMessage?>(_ => throw new InvalidOperationException("boom"))));
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/x")));
        Assert.Equal(CoapCode.InternalServerError, response.Code);
    }

    [Fact]
    public async Task A_confirmable_response_nobody_asked_for_is_reset()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        var stray = new CoapMessage { Type = CoapMessageType.Confirmable, Code = CoapCode.Content, MessageId = 77, Token = [9, 9] };
        net.Network.Inject(new InMemoryDatagram(TestNetwork.ServerAddress, TestNetwork.ClientAddress, stray.Encode()));
        net.Deliver();
        var reset = Assert.Single(net.SentBy(TestNetwork.ClientAddress));
        Assert.Equal(CoapMessageType.Reset, reset.Type);
        Assert.Equal(77, reset.MessageId);
    }

    [Fact]
    public async Task Cancellation_abandons_the_request_and_stops_retransmission()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        net.Network.Fate = _ => 0;
        using var cts = new CancellationTokenSource();
        var pending = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/x"), cts.Token);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        int sent = net.Network.Sent.Count;
        net.Advance(60 * Second);
        Assert.Equal(sent, net.Network.Sent.Count);

        // The NSTART slot was released: the next request goes straight out.
        net.Network.Fate = null;
        var next = await net.Run(net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/y")));
        Assert.Equal("hello y", next.PayloadAsString());
    }

    [Fact]
    public async Task Deduplication_state_expires_after_exchange_lifetime()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        for (int i = 0; i < 20; i++)
            await net.Run(net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, $"/{i}")));
        Assert.Equal(20, net.Server.DiagnosticCounts().Deduplication);

        net.Advance(TimeSpan.FromSeconds(248));
        var counts = net.Server.DiagnosticCounts();
        Assert.Equal(0, counts.Deduplication);
        Assert.Equal(0, counts.Peers);
    }

    [Fact]
    public async Task Too_many_concurrent_requests_from_one_peer_get_service_unavailable()
    {
        var gate = new TaskCompletionSource<CoapMessage?>();
        var serverOptions = TestNetwork.DeterministicOptions with { MaxConcurrentRequestsPerPeer = 2 };
        var clientOptions = TestNetwork.DeterministicOptions with { Transmission = new CoapTransmissionParameters { AckRandomFactor = 1.0, NStart = 3 } };
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => new ValueTask<CoapMessage?>(gate.Task)), clientOptions, serverOptions);
        var tasks = Enumerable.Range(0, 3).Select(i => net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, $"/{i}"))).ToArray();
        net.Deliver();
        var third = await net.Run(tasks[2]);
        Assert.Equal(CoapCode.ServiceUnavailable, third.Code);
        gate.SetResult(Handlers.Content("ok"));
        await net.Run(Task.WhenAll(tasks[0], tasks[1]));
    }

    [Fact]
    public async Task Peer_closure_fails_outstanding_requests()
    {
        await using var net = await TestNetwork.CreateAsync(Hello());
        net.Network.Fate = _ => 0;
        var pending = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/x"));
        net.ClientTransport.ClosePeer(TestNetwork.ServerAddress);
        await Assert.ThrowsAsync<CoapPeerClosedException>(() => pending);
    }

    [Fact]
    public async Task Psk_identity_from_the_transport_reaches_the_handler()
    {
        var network = new InMemoryNetwork();
        var time = new ManualTimeProvider();
        var security = new CoapPeerSecurity("DTLS 1.2", "device-7", "device-7"u8.ToArray(), 0xC0A8, false, null);
        var clientTransport = network.CreateTransport(TestNetwork.ClientAddress);
        var serverTransport = network.CreateTransport(TestNetwork.ServerAddress, _ => security);
        string? seen = null;
        await using var client = new CoapEndpoint(clientTransport, TestNetwork.DeterministicOptions, null, time);
        await using var server = new CoapEndpoint(serverTransport, TestNetwork.DeterministicOptions, Handlers.From(c => { seen = c.PskIdentity; return Handlers.Content("ok"); }), time);
        await client.StartAsync();
        await server.StartAsync();
        var task = client.SendAsync(clientTransport.PeerFor(TestNetwork.ServerAddress), CoapMessage.CreateRequest(CoapCode.Get, "/x"));
        await network.RunUntilAsync(task);
        Assert.Equal("device-7", seen);
    }
}

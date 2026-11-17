using System.Text;
using Wick.Coap.Tests.Support;
using Wick.Coap.Transport;

namespace Wick.Coap.Tests.Endpoint;

public class ObserveTests
{
    private static readonly TimeSpan Second = TimeSpan.FromSeconds(1);

    private sealed class Counter : ICoapRequestHandler
    {
        public int Value;

        public ValueTask<CoapMessage?> HandleAsync(CoapRequestContext context) =>
            ValueTask.FromResult<CoapMessage?>(Handlers.Content(Value.ToString()));
    }

    private static async Task<(TestNetwork Net, Counter Counter)> CreateAsync(CoapEndpointOptions? serverOptions = null)
    {
        var counter = new Counter();
        var net = await TestNetwork.CreateAsync(counter, serverOptions: serverOptions);
        return (net, counter);
    }

    private static async Task<CoapMessage> NextAsync(TestNetwork net, CoapObservation observation)
    {
        var read = observation.Notifications.ReadAsync().AsTask();
        return await net.Run(read);
    }

    [Fact]
    public async Task Register_notify_and_cancel()
    {
        var (net, counter) = await CreateAsync();
        await using var _ = net;
        var observation = await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/counter")));

        Assert.True(observation.IsRegistered);
        Assert.Equal("0", observation.InitialResponse.PayloadAsString());
        var relation = Assert.Single(net.Server.GetServerObservations());
        Assert.Equal(["counter"], relation.UriPath);
        Assert.Equal(observation.Token, relation.Token);

        for (int i = 1; i <= 3; i++)
        {
            counter.Value = i;
            Assert.Equal(1, net.Server.NotifyObservers("/counter", Handlers.Content(i.ToString())));
            var notification = await NextAsync(net, observation);
            Assert.Equal(i.ToString(), notification.PayloadAsString());
            Assert.Equal(CoapMessageType.NonConfirmable, notification.Type);
        }

        var cancelled = await net.Run(observation.CancelAsync());
        Assert.NotNull(cancelled);
        Assert.Null(cancelled!.Observe);
        Assert.Empty(net.Server.GetServerObservations());
        Assert.Equal(0, net.Server.NotifyObservers("/counter", Handlers.Content("x")));
        await observation.Ended;
    }

    [Fact]
    public async Task Stale_notifications_are_dropped_by_the_ordering_rule()
    {
        var (net, _) = await CreateAsync();
        await using var __ = net;
        var observation = await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/counter")));
        var relation = net.Server.GetServerObservations()[0];

        net.Server.Notify(relation, Handlers.Content("a"));
        net.Server.Notify(relation, Handlers.Content("b"));
        var queued = net.Network.TakePending();
        Assert.Equal(2, queued.Count);

        // Deliver the newer one first; the older one must then be ignored.
        net.Network.Inject(queued[1]);
        net.Network.Inject(queued[0]);
        net.Deliver();
        Assert.Equal("b", (await NextAsync(net, observation)).PayloadAsString());
        Assert.False(observation.Notifications.TryRead(out _));

        // After 128 seconds any sequence number counts as newer. A fresh message id keeps
        // deduplication out of it.
        net.Advance(TimeSpan.FromSeconds(129));
        var late = queued[0].Message!;
        late.MessageId++;
        late.MessageId++;
        net.Network.Inject(queued[0] with { Bytes = late.Encode() });
        net.Deliver();
        Assert.Equal("a", (await NextAsync(net, observation)).PayloadAsString());
    }

    [Fact]
    public async Task Confirmable_notifications_are_acknowledged_and_retransmitted_when_lost()
    {
        var (net, _) = await CreateAsync();
        await using var __ = net;
        var observation = await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/counter")));
        var relation = net.Server.GetServerObservations()[0];

        int drops = 1;
        net.Network.Fate = d => d.From.Equals(TestNetwork.ServerAddress) && drops-- > 0 ? 0 : 1;
        Assert.True(net.Server.Notify(relation, Handlers.Content("c1"), confirmable: true));
        net.Deliver();
        net.Advance(2 * Second);
        var notification = await NextAsync(net, observation);
        Assert.Equal("c1", notification.PayloadAsString());
        Assert.Equal(CoapMessageType.Confirmable, notification.Type);

        var ack = net.SentBy(TestNetwork.ClientAddress).Last();
        Assert.Equal(CoapMessageType.Acknowledgement, ack.Type);
        Assert.Equal(notification.MessageId, ack.MessageId);
        int sent = net.Network.Sent.Count;
        net.Advance(100 * Second);
        Assert.Equal(sent, net.Network.Sent.Count);
    }

    [Fact]
    public async Task An_unacknowledged_confirmable_notification_removes_the_observer()
    {
        var (net, _) = await CreateAsync();
        await using var __ = net;
        await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/counter")));
        var relation = net.Server.GetServerObservations()[0];
        net.Network.Fate = _ => 0;
        net.Server.Notify(relation, Handlers.Content("lost"), confirmable: true);
        net.Advance(100 * Second);
        Assert.Empty(net.Server.GetServerObservations());
    }

    [Fact]
    public async Task A_forgotten_observation_is_reset_and_the_server_drops_it()
    {
        var (net, _) = await CreateAsync();
        await using var __ = net;
        var observation = await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/counter")));
        await observation.DisposeAsync();
        Assert.True(observation.Notifications.Completion.IsCompleted);

        net.Server.NotifyObservers("/counter", Handlers.Content("ignored"));
        net.Deliver();
        Assert.Equal(CoapMessageType.Reset, net.SentBy(TestNetwork.ClientAddress).Last().Type);
        Assert.Empty(net.Server.GetServerObservations());
    }

    [Fact]
    public async Task Two_observations_of_one_path_from_one_peer_coexist()
    {
        // The Elixir library keyed relations by peer and path, so the second replaced the first.
        var (net, _) = await CreateAsync();
        await using var __ = net;
        var request = CoapMessage.CreateRequest(CoapCode.Fetch);
        request.ContentFormat = CoapContentFormat.SenmlCbor;
        request.Payload = new byte[] { 1 };
        var first = await net.Run(net.Client.ObserveAsync(net.ServerPeer, request));
        request.Payload = new byte[] { 2 };
        var second = await net.Run(net.Client.ObserveAsync(net.ServerPeer, request));

        var relations = net.Server.GetServerObservations();
        Assert.Equal(2, relations.Count);
        foreach (var relation in relations)
            net.Server.Notify(relation, Handlers.Content("for " + relation.Request.Payload.Span[0]));
        Assert.Equal("for 1", (await NextAsync(net, first)).PayloadAsString());
        Assert.Equal("for 2", (await NextAsync(net, second)).PayloadAsString());
    }

    [Fact]
    public async Task A_large_notification_is_completed_with_block2_before_delivery()
    {
        var serverOptions = TestNetwork.DeterministicOptions with { PreferredBlockSize = 32 };
        var (net, counter) = await CreateAsync(serverOptions);
        await using var __ = net;
        var observation = await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/counter")));
        var big = string.Concat(Enumerable.Repeat("0123456789", 10));
        net.Server.NotifyObservers("/counter", Handlers.Content(big));
        var notification = await NextAsync(net, observation);
        Assert.Equal(big, notification.PayloadAsString());
        Assert.NotNull(notification.Observe);
        Assert.Null(notification.Block2);
        var followUps = net.SentBy(TestNetwork.ClientAddress).Where(m => m.Block2 is not null).ToList();
        Assert.Equal(3, followUps.Count);
        Assert.All(followUps, m => Assert.Null(m.Observe));
    }

    [Fact]
    public async Task An_error_notification_ends_the_observation()
    {
        var (net, _) = await CreateAsync();
        await using var __ = net;
        var observation = await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/counter")));
        net.Server.NotifyObservers("/counter", CoapMessage.CreateResponse(CoapCode.NotFound));
        var final = await NextAsync(net, observation);
        Assert.Equal(CoapCode.NotFound, final.Code);
        await observation.Ended;
        Assert.Empty(net.Server.GetServerObservations());
    }

    [Fact]
    public async Task A_registration_answered_without_observe_is_not_registered()
    {
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => CoapMessage.CreateResponse(CoapCode.NotFound)));
        var observation = await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/missing")));
        Assert.False(observation.IsRegistered);
        Assert.Equal(CoapCode.NotFound, observation.InitialResponse.Code);
        Assert.True(observation.Notifications.Completion.IsCompleted);
        Assert.Empty(net.Server.GetServerObservations());
    }

    [Fact]
    public async Task Observations_per_peer_are_capped()
    {
        var serverOptions = TestNetwork.DeterministicOptions with { MaxObservationsPerPeer = 2 };
        var (net, _) = await CreateAsync(serverOptions);
        await using var __ = net;
        var results = new List<CoapObservation>();
        for (int i = 0; i < 3; i++)
            results.Add(await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, $"/r{i}"))));
        Assert.Equal([true, true, false], results.Select(r => r.IsRegistered));
        Assert.Equal(2, net.Server.GetServerObservations().Count);
    }

    [Fact]
    public async Task A_new_confirmable_notification_replaces_the_one_in_flight()
    {
        var (net, _) = await CreateAsync();
        await using var __ = net;
        var observation = await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/counter")));
        var relation = net.Server.GetServerObservations()[0];
        net.Network.Fate = _ => 0;
        net.Server.Notify(relation, Handlers.Content("old"), confirmable: true);
        net.Deliver();
        net.Network.Fate = null;
        net.Server.Notify(relation, Handlers.Content("new"));
        Assert.Equal("new", (await NextAsync(net, observation)).PayloadAsString());

        // Only the new notification is ever retransmitted.
        net.Advance(100 * Second);
        var payloads = net.SentBy(TestNetwork.ServerAddress).Where(m => m.Observe is not null && m.Code == CoapCode.Content).Select(m => m.PayloadAsString()).ToList();
        Assert.Equal(1, payloads.Count(p => p == "old"));
        Assert.Single(net.Server.GetServerObservations());
    }

    [Fact]
    public async Task A_reregistration_with_the_same_token_refreshes_the_relation()
    {
        var (net, _) = await CreateAsync();
        await using var __ = net;
        var request = CoapMessage.CreateRequest(CoapCode.Get, "/counter");
        request.Observe = 0;
        request.Token = [1, 2, 3];
        for (ushort id = 1; id <= 2; id++)
        {
            request.MessageId = id;
            net.Network.Inject(new InMemoryDatagram(TestNetwork.ClientAddress, TestNetwork.ServerAddress, request.Encode()));
            net.Deliver();
        }
        Assert.Single(net.Server.GetServerObservations());
        var replies = net.SentBy(TestNetwork.ServerAddress);
        Assert.True(replies[1].Observe > replies[0].Observe);
    }

    [Fact]
    public async Task Peer_closure_ends_observations_on_both_sides()
    {
        var (net, _) = await CreateAsync();
        await using var __ = net;
        var observation = await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/counter")));
        ServerObservation? ended = null;
        var endedSignal = new TaskCompletionSource();
        net.Server.ServerObservationEnded += o => { ended = o; endedSignal.TrySetResult(); };
        net.ServerTransport.ClosePeer(TestNetwork.ClientAddress);
        net.ClientTransport.ClosePeer(TestNetwork.ServerAddress);
        await endedSignal.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.NotNull(ended);
        Assert.Empty(net.Server.GetServerObservations());
        await observation.Ended.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task Notifications_in_both_directions_use_the_registration_token()
    {
        var (net, _) = await CreateAsync();
        await using var __ = net;
        var observation = await net.Run(net.Client.ObserveAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/counter")));
        net.Server.NotifyObservers("/counter", Handlers.Content("1"));
        var notification = await NextAsync(net, observation);
        Assert.Equal(observation.Token, notification.Token);
        Assert.Equal(Encoding.UTF8.GetBytes("1"), notification.Payload.ToArray());
    }
}

using Wick.Coap.Tests.Support;
using Wick.Coap.Transport;

namespace Wick.Coap.Tests.Endpoint;

public class BlockwiseTests
{
    private static byte[] Body(int length) => Enumerable.Range(0, length).Select(i => (byte)(i * 7 + 3)).ToArray();

    private static CoapEndpointOptions WithBlockSize(int size) => TestNetwork.DeterministicOptions with { PreferredBlockSize = size };

    [Fact]
    public async Task A_large_response_is_sent_with_block2_and_reassembled()
    {
        var body = Body(1000);
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => Handlers.Content(body)), serverOptions: WithBlockSize(64));
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/big")));

        Assert.Equal(body, response.Payload.ToArray());
        Assert.Null(response.Block2);
        Assert.Equal(CoapContentFormat.OctetStream, response.ContentFormat);

        var replies = net.SentBy(TestNetwork.ServerAddress);
        Assert.Equal(16, replies.Count); // ceil(1000 / 64)
        Assert.Equal(1000u, replies[0].Size2);
        Assert.All(replies.Take(15), r => Assert.Equal(64, r.Payload.Length));
        Assert.False(replies[^1].Block2!.Value.More);
        Assert.Equal(0, net.Server.DiagnosticCounts().Block2);
    }

    [Fact]
    public async Task A_payload_of_exactly_one_block_is_not_split()
    {
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => Handlers.Content(Body(64))), serverOptions: WithBlockSize(64));
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/one")));
        Assert.Equal(64, response.Payload.Length);
        Assert.Single(net.SentBy(TestNetwork.ServerAddress));
        Assert.Null(net.SentBy(TestNetwork.ServerAddress)[0].Block2);
    }

    [Fact]
    public async Task The_client_can_ask_for_smaller_blocks()
    {
        var body = Body(300);
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => Handlers.Content(body)));
        var request = CoapMessage.CreateRequest(CoapCode.Get, "/big");
        request.Block2 = new BlockOption(0, false, 1); // 32 bytes, early negotiation (RFC 7959 section 2.4)
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, request));
        Assert.Equal(body, response.Payload.ToArray());
        Assert.Equal(10, net.SentBy(TestNetwork.ServerAddress).Count);
    }

    [Fact]
    public async Task Lost_blocks_are_recovered_by_retransmission()
    {
        var body = Body(500);
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => Handlers.Content(body)), serverOptions: WithBlockSize(64));
        int count = 0;
        net.Network.Fate = d => d.From.Equals(TestNetwork.ServerAddress) && ++count == 3 ? 0 : 1;
        var pending = net.Client.SendAsync(net.ServerPeer, CoapMessage.CreateRequest(CoapCode.Get, "/big"));

        // Request and reply alternate; the sixth datagram is the third reply, which is lost.
        for (int k = 1; k <= 6; k++)
        {
            await net.Network.WaitForSentAsync(k);
            net.Deliver();
        }
        Assert.False(pending.IsCompleted);
        net.Advance(TimeSpan.FromSeconds(2));
        var response = await net.Run(pending);
        Assert.Equal(body, response.Payload.ToArray());
        var requests = net.SentBy(TestNetwork.ClientAddress);
        Assert.Equal(requests[2].MessageId, requests[3].MessageId);
    }

    [Fact]
    public async Task A_large_request_is_sent_with_block1_and_reassembled_for_the_handler()
    {
        var body = Body(3000);
        byte[]? seen = null;
        await using var net = await TestNetwork.CreateAsync(Handlers.From(context =>
        {
            seen = context.Request.Payload.ToArray();
            Assert.Null(context.Request.Block1);
            return CoapMessage.CreateResponse(CoapCode.Changed);
        }), clientOptions: WithBlockSize(256));

        var request = CoapMessage.CreateRequest(CoapCode.Put, "/upload");
        request.Payload = body;
        request.ContentFormat = CoapContentFormat.OctetStream;
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, request));

        Assert.Equal(CoapCode.Changed, response.Code);
        Assert.Equal(body, seen);
        Assert.Equal(new BlockOption(11, false, 4), response.Block1);
        var requests = net.SentBy(TestNetwork.ClientAddress);
        Assert.Equal(12, requests.Count);
        Assert.Equal(3000u, requests[0].Size1);
        Assert.All(net.SentBy(TestNetwork.ServerAddress).Take(11), r => Assert.Equal(CoapCode.Continue, r.Code));
    }

    [Fact]
    public async Task A_server_that_wants_smaller_blocks_gets_them()
    {
        var body = Body(1000);
        byte[]? seen = null;
        await using var net = await TestNetwork.CreateAsync(
            Handlers.From(context => { seen = context.Request.Payload.ToArray(); return CoapMessage.CreateResponse(CoapCode.Changed); }),
            clientOptions: WithBlockSize(256),
            serverOptions: WithBlockSize(64));
        var request = CoapMessage.CreateRequest(CoapCode.Post, "/upload");
        request.Payload = body;
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, request));

        Assert.Equal(CoapCode.Changed, response.Code);
        Assert.Equal(body, seen);
        var requests = net.SentBy(TestNetwork.ClientAddress);
        Assert.Equal(256, requests[0].Payload.Length);
        Assert.Equal(new BlockOption(4, true, 2), requests[1].Block1); // continues at byte 256 in 64-byte blocks
        Assert.Equal(1 + (1000 - 256 + 63) / 64, requests.Count);
    }

    [Fact]
    public async Task Block1_in_and_block2_out_combine()
    {
        var body = Body(700);
        await using var net = await TestNetwork.CreateAsync(
            Handlers.From(context => CoapMessage.CreateResponse(CoapCode.Changed, context.Request.Payload.ToArray().Reverse().ToArray())),
            clientOptions: WithBlockSize(128),
            serverOptions: WithBlockSize(128));
        var request = CoapMessage.CreateRequest(CoapCode.Post, "/echo");
        request.Payload = body;
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, request));
        Assert.Equal(CoapCode.Changed, response.Code);
        Assert.Equal(body.Reverse().ToArray(), response.Payload.ToArray());
    }

    [Fact]
    public async Task A_block_out_of_order_is_answered_with_request_entity_incomplete()
    {
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => CoapMessage.CreateResponse(CoapCode.Changed)));
        var request = CoapMessage.CreateRequest(CoapCode.Put, "/upload");
        request.Block1 = new BlockOption(3, true, 0);
        request.Payload = Body(16);
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, request));
        Assert.Equal(CoapCode.RequestEntityIncomplete, response.Code);
    }

    [Fact]
    public async Task A_declared_size_beyond_the_limit_is_refused_with_size1()
    {
        var serverOptions = TestNetwork.DeterministicOptions with { MaxBodySize = 100 };
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => CoapMessage.CreateResponse(CoapCode.Changed)), WithBlockSize(64), serverOptions);
        var request = CoapMessage.CreateRequest(CoapCode.Put, "/upload");
        request.Payload = Body(500);
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, request));
        Assert.Equal(CoapCode.RequestEntityTooLarge, response.Code);
        Assert.Equal(100u, response.Size1);
    }

    [Fact]
    public async Task A_body_that_grows_beyond_the_limit_is_refused()
    {
        var serverOptions = TestNetwork.DeterministicOptions with { MaxBodySize = 100 };
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => CoapMessage.CreateResponse(CoapCode.Changed)), serverOptions: serverOptions);
        for (int i = 0; i < 7; i++)
        {
            var block = CoapMessage.CreateRequest(CoapCode.Put, "/upload");
            block.Block1 = new BlockOption(i, true, 0);
            block.Payload = Body(16);
            var response = await net.Run(net.Client.SendAsync(net.ServerPeer, block));
            Assert.Equal(i < 6 ? CoapCode.Continue : CoapCode.RequestEntityTooLarge, response.Code);
        }
    }

    [Fact]
    public async Task Server_transfers_are_capped_per_peer_and_expire()
    {
        var serverOptions = WithBlockSize(16) with { MaxBlockTransfersPerPeer = 3 };
        await using var net = await TestNetwork.CreateAsync(Handlers.From(c => Handlers.Content(Body(100))), serverOptions: serverOptions);
        for (int i = 0; i < 5; i++)
        {
            // Ask only for the first block of each resource, leaving the transfers open.
            var request = CoapMessage.CreateRequest(CoapCode.Get, $"/r{i}");
            request.MessageId = (ushort)(100 + i);
            request.Token = [(byte)i];
            request.Block2 = new BlockOption(0, false, 0);
            net.Network.Inject(new InMemoryDatagram(TestNetwork.ClientAddress, TestNetwork.ServerAddress, request.Encode()));
            net.Deliver();
        }
        Assert.Equal(3, net.Server.DiagnosticCounts().Block2);
        net.Advance(TimeSpan.FromSeconds(260));
        Assert.Equal(0, net.Server.DiagnosticCounts().Block2);
    }

    [Fact]
    public async Task A_later_block_without_stored_state_is_served_by_running_the_handler_again()
    {
        var body = Body(200);
        int calls = 0;
        await using var net = await TestNetwork.CreateAsync(Handlers.From(_ => { calls++; return Handlers.Content(body); }), serverOptions: WithBlockSize(64));
        var request = CoapMessage.CreateRequest(CoapCode.Get, "/big");
        request.Block2 = new BlockOption(3, false, 2);
        var response = await net.Run(net.Client.SendAsync(net.ServerPeer, request));
        Assert.Equal(body.AsSpan(192, 8).ToArray(), response.Payload.ToArray());
        Assert.Equal(new BlockOption(3, false, 2), response.Block2);
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task The_message_fits_the_transport_even_with_long_options()
    {
        var network = new InMemoryNetwork();
        var time = new ManualTimeProvider();
        var small = network.CreateTransport(TestNetwork.ClientAddress);
        var server = network.CreateTransport(TestNetwork.ServerAddress);
        await using var clientEndpoint = new CoapEndpoint(small, TestNetwork.DeterministicOptions, null, time);
        await using var serverEndpoint = new CoapEndpoint(server, TestNetwork.DeterministicOptions, Handlers.From(c => CoapMessage.CreateResponse(CoapCode.Changed)), time);
        await clientEndpoint.StartAsync();
        await serverEndpoint.StartAsync();
        var request = CoapMessage.CreateRequest(CoapCode.Post, "/" + new string('p', 200));
        request.Payload = Body(1024);
        var task = clientEndpoint.SendAsync(small.PeerFor(TestNetwork.ServerAddress), request);
        await network.RunUntilAsync(task);
        Assert.All(network.Sent, d => Assert.True(d.Bytes.Length <= 1152));
        Assert.True(network.Sent.Count > 2);
    }
}

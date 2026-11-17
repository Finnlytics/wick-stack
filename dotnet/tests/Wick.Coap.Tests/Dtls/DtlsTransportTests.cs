using Org.BouncyCastle.Tls;
using Wick.Coap.Dtls;
using Wick.Coap.Tests.Support;

namespace Wick.Coap.Tests.Dtls;

/// <summary>DTLS over real loopback sockets against a BouncyCastle client.</summary>
public class DtlsTransportTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    private static CoapMessage Register() => CoapMessage.CreateRequest(CoapCode.Post, "/rd").AddUriQuery("ep=dtls-test");

    [Theory]
    [InlineData(CipherSuite.TLS_PSK_WITH_AES_128_CCM_8)]
    [InlineData(CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256)]
    [InlineData(CipherSuite.TLS_PSK_WITH_AES_128_CBC_SHA256)]
    public async Task Handshakes_with_each_suite_and_exposes_the_psk_identity(int suite)
    {
        await using var server = await RegistrationServer.StartAsync();
        var response = await Task.Run(() =>
        {
            using var client = DtlsTestClient.Connect(server.LocalEndPoint, RegistrationServer.Identity, RegistrationServer.Key, suite);
            Assert.Equal(suite, client.Parameters.CipherSuite);
            return client.Request(Register(), Timeout);
        });

        Assert.NotNull(response);
        Assert.Equal(CoapCode.Created, response!.Code);
        Assert.Equal("rd", response.LocationPath[0]);
        var registration = await server.WaitForAsync("register", 1, Timeout);
        Assert.Equal(RegistrationServer.Identity, registration.Identity);
        var session = Assert.IsType<DtlsSession>(registration.Peer);
        Assert.Equal(suite, session.Security!.CipherSuite);
        // The client has closed by now, so check that the session was established rather than that it still is.
        Assert.NotNull(session.EstablishedAt);
    }

    [Fact]
    public async Task A_wrong_key_fails_the_handshake()
    {
        await using var server = await RegistrationServer.StartAsync();
        await Assert.ThrowsAnyAsync<Exception>(() => Task.Run(() =>
            DtlsTestClient.Connect(server.LocalEndPoint, RegistrationServer.Identity, new byte[16], CipherSuite.TLS_PSK_WITH_AES_128_CCM_8)));
        Assert.DoesNotContain(server.Transport.GetSessions(), s => s.State == DtlsSessionState.Established);
    }

    [Fact]
    public async Task An_unknown_identity_fails_the_handshake()
    {
        await using var server = await RegistrationServer.StartAsync();
        await Assert.ThrowsAnyAsync<Exception>(() => Task.Run(() =>
            DtlsTestClient.Connect(server.LocalEndPoint, "nobody", RegistrationServer.Key, CipherSuite.TLS_PSK_WITH_AES_128_CCM_8)));
    }

    [Fact]
    public async Task A_client_without_extended_master_secret_is_accepted_by_default_and_refused_when_required()
    {
        await using (var lenient = await RegistrationServer.StartAsync())
        {
            await Task.Run(() =>
            {
                using var client = DtlsTestClient.Connect(lenient.LocalEndPoint, RegistrationServer.Identity, RegistrationServer.Key,
                    CipherSuite.TLS_PSK_WITH_AES_128_CCM_8, offerExtendedMasterSecret: false);
                Assert.False(client.Parameters.IsExtendedMasterSecret);
            });
        }

        await using var strict = await RegistrationServer.StartAsync(new DtlsServerOptions { RequireExtendedMasterSecret = true });
        await Assert.ThrowsAnyAsync<Exception>(() => Task.Run(() =>
            DtlsTestClient.Connect(strict.LocalEndPoint, RegistrationServer.Identity, RegistrationServer.Key,
                CipherSuite.TLS_PSK_WITH_AES_128_CCM_8, offerExtendedMasterSecret: false)));
    }

    [Fact]
    public async Task The_extended_master_secret_is_negotiated_when_offered()
    {
        await using var server = await RegistrationServer.StartAsync();
        await Task.Run(() =>
        {
            using var client = DtlsTestClient.Connect(server.LocalEndPoint, RegistrationServer.Identity, RegistrationServer.Key, CipherSuite.TLS_PSK_WITH_AES_128_CCM_8);
            Assert.True(client.Parameters.IsExtendedMasterSecret);
            client.Request(Register(), Timeout);
        });
        var registration = await server.WaitForAsync("register", 1, Timeout);
        Assert.True(registration.Peer.Security!.ExtendedMasterSecret);
    }

    [Fact]
    public async Task With_a_connection_id_the_session_follows_the_peer_to_a_new_address()
    {
        await using var server = await RegistrationServer.StartAsync(new DtlsServerOptions { ConnectionIdLength = 4 });
        using var relay = new UdpRelay(server.LocalEndPoint);
        using var client = await Task.Run(() => DtlsTestClient.Connect(relay.ListenEndPoint, RegistrationServer.Identity, RegistrationServer.Key,
            CipherSuite.TLS_PSK_WITH_AES_128_CCM_8, connectionId: []));
        Assert.Equal(4, client.Parameters.ConnectionIDLocal.Length);

        var created = await Task.Run(() => client.Request(Register(), Timeout));
        Assert.Equal(CoapCode.Created, created!.Code);
        var registration = await server.WaitForAsync("register", 1, Timeout);
        var session = Assert.IsType<DtlsSession>(registration.Peer);
        var before = relay.UpstreamEndPoint;
        Assert.Equal(before, session.RemoteEndPoint);

        relay.Rebind();
        var after = relay.UpstreamEndPoint;
        Assert.NotEqual(before.Port, after.Port);
        var update = CoapMessage.CreateRequest(CoapCode.Post, "/" + string.Join('/', created.LocationPath));
        var changed = await Task.Run(() => client.Request(update, Timeout));
        Assert.Equal(CoapCode.Changed, changed!.Code);

        var updated = await server.WaitForAsync("update", 1, Timeout);
        Assert.Same(session, updated.Peer);
        Assert.Equal(after, updated.Address);
        Assert.Equal(after, session.RemoteEndPoint);
        Assert.Single(server.Transport.GetSessions());

        // A request from the server reaches the client at its new address.
        var read = server.Endpoint.SendAsync(session, CoapMessage.CreateRequest(CoapCode.Get, "/3/0/0"));
        var served = await Task.Run(() => client.ServeOne("Wick", Timeout));
        Assert.NotNull(served);
        var response = await read.WaitAsync(Timeout);
        Assert.Equal("Wick", response.PayloadAsString());
    }

    [Fact]
    public async Task Without_a_connection_id_a_moved_peer_is_not_accepted()
    {
        await using var server = await RegistrationServer.StartAsync(new DtlsServerOptions { ConnectionIdLength = 0 });
        using var relay = new UdpRelay(server.LocalEndPoint);
        using var client = await Task.Run(() => DtlsTestClient.Connect(relay.ListenEndPoint, RegistrationServer.Identity, RegistrationServer.Key,
            CipherSuite.TLS_PSK_WITH_AES_128_CCM_8, connectionId: []));
        Assert.Null(client.Parameters.ConnectionIDLocal);
        await Task.Run(() => client.Request(Register(), Timeout));
        relay.Rebind();
        var lost = await Task.Run(() => client.Request(CoapMessage.CreateRequest(CoapCode.Post, "/rd/r1"), TimeSpan.FromSeconds(2)));
        Assert.Null(lost);
        Assert.DoesNotContain(server.Events, e => e.Kind == "update");
    }

    [Fact]
    public async Task A_close_notify_ends_the_session_and_releases_endpoint_state()
    {
        await using var server = await RegistrationServer.StartAsync();
        var closed = new TaskCompletionSource<Transport.ICoapPeer>();
        server.Endpoint.PeerClosed += p => closed.TrySetResult(p);
        await Task.Run(() =>
        {
            using var client = DtlsTestClient.Connect(server.LocalEndPoint, RegistrationServer.Identity, RegistrationServer.Key, CipherSuite.TLS_PSK_WITH_AES_128_CCM_8);
            client.Request(Register(), Timeout);
            client.Close();
        });
        var peer = await closed.Task.WaitAsync(Timeout);
        Assert.Equal(DtlsSessionState.Closed, ((DtlsSession)peer).State);
        Assert.Empty(server.Transport.GetSessions());
    }

    [Fact]
    public async Task A_new_handshake_from_the_same_address_replaces_the_old_session()
    {
        await using var server = await RegistrationServer.StartAsync(new DtlsServerOptions { ConnectionIdLength = 0 });
        using var relay = new UdpRelay(server.LocalEndPoint);
        await Task.Run(() =>
        {
            // The relay keeps the same server-facing address for both clients, so the second
            // ClientHello arrives where the first session lives, as after a device reboot.
            using var first = DtlsTestClient.Connect(relay.ListenEndPoint, RegistrationServer.Identity, RegistrationServer.Key, CipherSuite.TLS_PSK_WITH_AES_128_CCM_8);
            first.Request(Register(), Timeout);
        });
        var firstSession = (DtlsSession)(await server.WaitForAsync("register", 1, Timeout)).Peer;
        await Task.Run(() =>
        {
            using var second = DtlsTestClient.Connect(relay.ListenEndPoint, RegistrationServer.Identity, RegistrationServer.Key, CipherSuite.TLS_PSK_WITH_AES_128_CCM_8);
            second.Request(Register(), Timeout);
        });
        var secondSession = (DtlsSession)(await server.WaitForAsync("register", 2, Timeout)).Peer;
        Assert.NotSame(firstSession, secondSession);
        Assert.Equal(DtlsSessionState.Closed, firstSession.State);
    }

    [Fact]
    public async Task Large_payloads_travel_block_wise_over_dtls()
    {
        await using var server = await RegistrationServer.StartAsync();
        var big = string.Concat(Enumerable.Repeat("</3/0>,", 400));
        var response = await Task.Run(() =>
        {
            using var client = DtlsTestClient.Connect(server.LocalEndPoint, RegistrationServer.Identity, RegistrationServer.Key, CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256);
            var request = Register();
            request.Payload = System.Text.Encoding.UTF8.GetBytes(big);
            request.Block1 = new BlockOption(0, true, 6);
            request.Payload = request.Payload[..1024];
            return client.Request(request, Timeout);
        });
        Assert.Equal(CoapCode.Continue, response!.Code);
        Assert.Equal(new BlockOption(0, true, 6), response.Block1);
    }
}

using System.Text;
using Wick.Lwm2m.Links;
using Wick.Lwm2m.Registration;
using Wick.Lwm2m.Tests.Support;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.Tests.Registration;

public sealed class RegistrationRequestTests
{
    private static WireRequest Register(string query, string payload = "</1/0>,</3/0>") => new(Method.Post)
    {
        Path = ["rd"],
        Query = query.Length == 0 ? [] : query.Split('&').Select(QueryParameter.Parse).ToList(),
        ContentFormat = 40,
        Payload = Encoding.UTF8.GetBytes(payload),
    };

    [Fact]
    public void Parses_every_register_parameter()
    {
        var request = RegisterRequest.Parse(Register("ep=device-1&lt=300&lwm2m=1.1&b=U&Q&sms=447700900123&apn=iot", """</>;rt="oma.lwm2m";ct=11543,</1/0>,</3/0>"""));

        Assert.Equal("device-1", request.EndpointName);
        Assert.Equal(300, request.Lifetime);
        Assert.Equal("1.1", request.Lwm2mVersion);
        Assert.Equal("U", request.Binding);
        Assert.True(request.QueueMode);
        Assert.Equal("447700900123", request.SmsNumber);
        Assert.Equal(["apn=iot"], request.AdditionalParameters.Select(p => p.ToString()));
        Assert.Equal(["/", "/1/0", "/3/0"], request.Objects.Select(l => l.Target));
    }

    [Fact]
    public void A_missing_version_means_1_0()
    {
        var request = RegisterRequest.Parse(Register("ep=d"));

        Assert.Null(request.Lwm2mVersion);
        Assert.Equal("1.0", request.EffectiveVersion);
    }

    [Theory]
    [InlineData("lt=60", "ep")]
    [InlineData("ep=", "ep")]
    [InlineData("ep=d&lt=0", "lifetime")]
    [InlineData("ep=d&lt=-5", "lifetime")]
    [InlineData("ep=d&lt=soon", "lifetime")]
    [InlineData("ep=d&lt", "lifetime")]
    [InlineData("ep=d&Q=1&lwm2m=1.1", "Q")]
    [InlineData("ep=d&Q", "queue mode")]
    [InlineData("ep=d&lwm2m=1.0&b=T", "binding T")]
    [InlineData("ep=d&lwm2m=1.1&b=UQ", "binding Q")]
    [InlineData("ep=d&b=X", "unknown binding")]
    [InlineData("ep=d&b=UU", "repeats")]
    [InlineData("ep=d&lwm2m=one", "invalid LwM2M version")]
    public void Malformed_registers_are_bad_requests(string query, string mention)
    {
        var e = Assert.Throws<RegistrationRequestException>(() => RegisterRequest.Parse(Register(query)));

        Assert.Equal(ResponseCode.BadRequest, e.Code);
        Assert.Contains(mention, e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void An_unsupported_version_is_a_precondition_failure()
    {
        Assert.Equal(ResponseCode.PreconditionFailed, Assert.Throws<RegistrationRequestException>(() => RegisterRequest.Parse(Register("ep=d&lwm2m=2.0"))).Code);
    }

    [Theory]
    [InlineData("")]
    [InlineData("</1/0")]
    public void A_missing_or_malformed_object_list_is_a_bad_request(string payload)
    {
        Assert.Equal(ResponseCode.BadRequest, Assert.Throws<RegistrationRequestException>(() => RegisterRequest.Parse(Register("ep=d", payload))).Code);
    }

    [Fact]
    public void Register_round_trips_through_the_wire()
    {
        var request = new RegisterRequest("device-1", CoreLinkFormat.Parse("</1/0>,</3/0>"))
        {
            Lifetime = 86400,
            Lwm2mVersion = "1.2",
            Binding = "U",
            QueueMode = true,
            SmsNumber = "123",
            AdditionalParameters = [new QueryParameter("x", "y")],
        };

        var wire = request.ToWire();

        Assert.Equal(["ep=device-1", "lt=86400", "lwm2m=1.2", "b=U", "Q", "sms=123", "x=y"], wire.Query.Select(q => q.ToString()));
        Assert.Equal(request, RegisterRequest.Parse(wire));
    }

    [Fact]
    public void Update_parses_optional_parameters_and_payload()
    {
        var wire = new UpdateRequest("abc") { Lifetime = 60, Binding = "U", Objects = CoreLinkFormat.Parse("</3/0>") }.ToWire();

        var parsed = UpdateRequest.Parse(wire);

        Assert.Equal("abc", parsed.RegistrationId);
        Assert.Equal(60, parsed.Lifetime);
        Assert.Equal(["/3/0"], parsed.Objects!.Select(l => l.Target));
        Assert.Null(UpdateRequest.Parse(new UpdateRequest("abc").ToWire()).Objects);
        Assert.Null(new UpdateRequest("abc").ToWire().ContentFormat);
    }

    [Fact]
    public void Deregister_is_a_delete_on_the_registration()
    {
        Assert.Equal(new WireRequest(Method.Delete) { Path = ["rd", "abc"] }, new DeregisterRequest("abc").ToWire());
        Assert.Equal(new DeregisterRequest("abc"), DeregisterRequest.Parse(new DeregisterRequest("abc").ToWire()));
    }
}

public sealed class ClientRegistrationTests
{
    private static ClientRegistration With(string links) =>
        new("r", "e", TimeSpan.FromMinutes(1), "1.1", CoreLinkFormat.Parse(links), DateTimeOffset.UnixEpoch);

    [Fact]
    public void Reads_supported_objects_instances_and_formats_from_the_links()
    {
        var registration = With("""</>;rt="oma.lwm2m";ct="60 110 112 11543",</1>;ver=1.1,</1/0>,</3/0>,</3303>,</3303/0>,</3303/1>""");

        Assert.Equal("/", registration.RootPath);
        Assert.Equal([60, 110, 112, 11543], registration.SupportedContentFormats);
        Assert.Equal(new Dictionary<int, string?> { [1] = "1.1", [3] = null, [3303] = null }, registration.SupportedObjects);
        Assert.Equal(["/1/0", "/3/0", "/3303/0", "/3303/1"], registration.AvailableInstances.Select(p => p.ToString()));
    }

    [Fact]
    public void Honours_an_alternate_root_path()
    {
        var registration = With("""</lwm2m>;rt="oma.lwm2m",</lwm2m/1/0>,</lwm2m/3/0>,</other/4/0>""");

        Assert.Equal("/lwm2m", registration.RootPath);
        Assert.Equal(["/1/0", "/3/0"], registration.AvailableInstances.Select(p => p.ToString()));
        Assert.Empty(registration.SupportedContentFormats);
    }

    [Fact]
    public void Expires_at_last_update_plus_lifetime()
    {
        var registration = With("</1/0>");

        Assert.Equal(DateTimeOffset.UnixEpoch.AddMinutes(1), registration.ExpiresAt);
        Assert.False(registration.IsExpired(DateTimeOffset.UnixEpoch.AddSeconds(59)));
        Assert.True(registration.IsExpired(DateTimeOffset.UnixEpoch.AddSeconds(60)));
        Assert.False(registration.IsExpired(DateTimeOffset.UnixEpoch.AddSeconds(60), TimeSpan.FromSeconds(5)));
    }
}

public sealed class RegistrationStoreTests
{
    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static ClientRegistration Make(string id, string endpoint, int lifetimeSeconds = 60) =>
        new(id, endpoint, TimeSpan.FromSeconds(lifetimeSeconds), "1.1", CoreLinkFormat.Parse("</1/0>"), T0);

    [Fact]
    public void Looks_registrations_up_by_id_and_endpoint()
    {
        var store = new InMemoryRegistrationStore(new ManualTimeProvider(T0));
        store.Add(Make("a", "e1"));

        Assert.Equal("e1", store.Get("a")!.EndpointName);
        Assert.Equal("a", store.GetByEndpoint("e1")!.Id);
        Assert.Null(store.Get("b"));
        Assert.Single(store.GetAll());
    }

    [Fact]
    public void A_new_registration_replaces_the_endpoints_previous_one()
    {
        var store = new InMemoryRegistrationStore(new ManualTimeProvider(T0));
        store.Add(Make("a", "e1"));

        var replaced = store.Add(Make("b", "e1"));

        Assert.Equal("a", replaced!.Id);
        Assert.Null(store.Get("a"));
        Assert.Equal("b", store.GetByEndpoint("e1")!.Id);
    }

    [Fact]
    public void Expired_registrations_vanish_from_lookups_and_are_purged_on_request()
    {
        var clock = new ManualTimeProvider(T0);
        var store = new InMemoryRegistrationStore(clock);
        store.Add(Make("a", "e1", lifetimeSeconds: 60));
        store.Add(Make("b", "e2", lifetimeSeconds: 600));

        clock.Advance(TimeSpan.FromSeconds(61));

        Assert.Null(store.Get("a"));
        Assert.Null(store.GetByEndpoint("e1"));
        Assert.Equal(["b"], store.GetAll().Select(r => r.Id));
        Assert.Null(store.Update(Make("a", "e1")));
        Assert.Equal(["a"], store.RemoveExpired().Select(r => r.Id));
        Assert.Empty(store.RemoveExpired());
    }

    [Fact]
    public void Replacing_an_expired_but_unpurged_registration_still_reports_it()
    {
        var clock = new ManualTimeProvider(T0);
        var store = new InMemoryRegistrationStore(clock);
        store.Add(Make("a", "e1", lifetimeSeconds: 60));
        clock.Advance(TimeSpan.FromSeconds(61));

        Assert.Equal("a", store.Add(Make("b", "e1", lifetimeSeconds: 600))?.Id);
        Assert.Empty(store.RemoveExpired());
    }

    [Fact]
    public void The_grace_period_extends_every_lifetime()
    {
        var clock = new ManualTimeProvider(T0);
        var store = new InMemoryRegistrationStore(clock, TimeSpan.FromSeconds(10));
        store.Add(Make("a", "e1", lifetimeSeconds: 60));

        clock.Advance(TimeSpan.FromSeconds(65));
        Assert.NotNull(store.Get("a"));

        clock.Advance(TimeSpan.FromSeconds(5));
        Assert.Null(store.Get("a"));
    }

    [Fact]
    public void Update_and_remove()
    {
        var store = new InMemoryRegistrationStore(new ManualTimeProvider(T0));
        var original = Make("a", "e1");
        store.Add(original);

        Assert.Equal(original, store.Update(original with { Binding = "T" }));
        Assert.Equal("T", store.Get("a")!.Binding);
        Assert.Throws<ArgumentException>(() => store.Update(Make("a", "other")));
        Assert.NotNull(store.Remove("a"));
        Assert.Null(store.Remove("a"));
        Assert.Null(store.GetByEndpoint("e1"));
    }
}

public sealed class RegistrationHandlerTests
{
    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private static readonly ClientIdentity Alice = new("alice", "203.0.113.7:5684");

    private readonly ManualTimeProvider _clock = new(T0);
    private readonly InMemoryRegistrationStore _store;
    private int _ids;

    public RegistrationHandlerTests()
    {
        _store = new InMemoryRegistrationStore(_clock);
    }

    private RegistrationHandler Handler(IRegistrationAuthoriser? authoriser = null) =>
        new(_store, authoriser ?? RegistrationAuthorisers.PskIdentityMatchesEndpoint, _clock, new RegistrationHandlerOptions { NewRegistrationId = () => $"r{_ids++}" });

    private static WireRequest Register(string endpoint = "alice", string extra = "") => new(Method.Post)
    {
        Path = ["rd"],
        Query = $"ep={endpoint}&lt=60&lwm2m=1.1&b=U{extra}".Split('&').Select(QueryParameter.Parse).ToList(),
        ContentFormat = 40,
        Payload = "</1/0>,</3/0>"u8.ToArray(),
    };

    [Fact]
    public void Register_creates_and_answers_with_the_location()
    {
        var outcome = Handler().Handle(Register(), Alice);

        Assert.Equal(ResponseCode.Created, outcome.Response.Code);
        Assert.Equal(["rd", "r0"], outcome.Response.LocationPath);
        Assert.Equal(RegistrationOperation.Register, outcome.Operation);
        var stored = _store.Get("r0")!;
        Assert.Equal(TimeSpan.FromSeconds(60), stored.Lifetime);
        Assert.Equal(Alice, stored.Identity);
        Assert.Equal(T0, stored.RegisteredAt);
        Assert.Equal("1.1", stored.Lwm2mVersion);
    }

    [Fact]
    public void A_register_without_a_lifetime_gets_the_default()
    {
        var request = Register() with { Query = [new("ep", "alice")] };

        Handler().Handle(request, Alice);

        Assert.Equal(TimeSpan.FromSeconds(86400), _store.Get("r0")!.Lifetime);
        Assert.Equal("1.0", _store.Get("r0")!.Lwm2mVersion);
    }

    [Fact]
    public void Re_registering_replaces_and_reports_the_previous_registration()
    {
        var handler = Handler();
        handler.Handle(Register(), Alice);

        var outcome = handler.Handle(Register(), Alice);

        Assert.Equal("r0", outcome.Previous!.Id);
        Assert.Equal("r1", outcome.Registration!.Id);
        Assert.Null(_store.Get("r0"));
    }

    [Fact]
    public void The_authoriser_sees_the_psk_identity_and_endpoint()
    {
        RegistrationAuthorisationContext? seen = null;
        var handler = Handler(RegistrationAuthorisers.From(c =>
        {
            seen = c;
            return AuthorisationDecision.Deny("no");
        }));

        var outcome = handler.Handle(Register("dev-9"), Alice);

        Assert.Equal(ResponseCode.Forbidden, outcome.Response.Code);
        Assert.Equal(new RegistrationAuthorisationContext(RegistrationOperation.Register, Alice, "dev-9", null), seen);
        Assert.Empty(_store.GetAll());
    }

    [Fact]
    public void The_psk_identity_must_match_the_endpoint_by_default()
    {
        Assert.Equal(ResponseCode.Forbidden, Handler().Handle(Register("bob"), Alice).Response.Code);
        Assert.Equal(ResponseCode.Forbidden, Handler().Handle(Register(), ClientIdentity.Unsecured).Response.Code);
        Assert.Equal(ResponseCode.Created, Handler(RegistrationAuthorisers.AllowAll).Handle(Register("bob"), ClientIdentity.Unsecured).Response.Code);
    }

    [Fact]
    public void Malformed_registers_answer_with_a_diagnostic()
    {
        var outcome = Handler().Handle(Register() with { Payload = default }, Alice);

        Assert.Equal(ResponseCode.BadRequest, outcome.Response.Code);
        Assert.Contains("Object list", outcome.Response.PayloadText, StringComparison.Ordinal);
        Assert.Equal(RegistrationOperation.Register, outcome.Operation);
        Assert.Equal(ResponseCode.PreconditionFailed, Handler().Handle(Register() with { Query = [new("ep", "alice"), new("lwm2m", "9.9")] }, Alice).Response.Code);
    }

    [Fact]
    public void Update_refreshes_the_lifetime_and_applies_changes()
    {
        var handler = Handler();
        handler.Handle(Register(), Alice);
        _clock.Advance(TimeSpan.FromSeconds(50));

        var outcome = handler.Handle(new UpdateRequest("r0") { Lifetime = 120, Objects = CoreLinkFormat.Parse("</1/0>,</3/0>,</3303/0>") }.ToWire(), Alice with { PeerAddress = "203.0.113.8:5684" });

        Assert.Equal(ResponseCode.Changed, outcome.Response.Code);
        Assert.Equal(T0, outcome.Previous!.LastUpdate);
        var stored = _store.Get("r0")!;
        Assert.Equal(T0.AddSeconds(50), stored.LastUpdate);
        Assert.Equal(TimeSpan.FromSeconds(120), stored.Lifetime);
        Assert.Equal(3, stored.AvailableInstances.Count);
        Assert.Equal("203.0.113.8:5684", stored.Identity.PeerAddress);
        Assert.Equal(T0, stored.RegisteredAt);

        _clock.Advance(TimeSpan.FromSeconds(100));
        Assert.NotNull(_store.Get("r0"));
    }

    [Fact]
    public void An_empty_update_only_refreshes()
    {
        var handler = Handler();
        handler.Handle(Register(), Alice);
        _clock.Advance(TimeSpan.FromSeconds(30));

        handler.Handle(new UpdateRequest("r0").ToWire(), Alice);

        var stored = _store.Get("r0")!;
        Assert.Equal(TimeSpan.FromSeconds(60), stored.Lifetime);
        Assert.Equal(2, stored.Objects.Count);
        Assert.Equal(T0.AddSeconds(90), stored.ExpiresAt);
    }

    [Fact]
    public void Updates_to_unknown_or_expired_registrations_are_not_found()
    {
        var handler = Handler();
        Assert.Equal(ResponseCode.NotFound, handler.Handle(new UpdateRequest("nope").ToWire(), Alice).Response.Code);

        handler.Handle(Register(), Alice);
        _clock.Advance(TimeSpan.FromSeconds(60));
        Assert.Equal(ResponseCode.NotFound, handler.Handle(new UpdateRequest("r0").ToWire(), Alice).Response.Code);
    }

    [Fact]
    public void Only_the_registering_identity_may_update_or_deregister()
    {
        var handler = Handler(RegistrationAuthorisers.AllowAll);
        handler.Handle(Register(), Alice);
        var mallory = new ClientIdentity("mallory");

        Assert.Equal(ResponseCode.Forbidden, handler.Handle(new UpdateRequest("r0").ToWire(), mallory).Response.Code);
        Assert.Equal(ResponseCode.Forbidden, handler.Handle(new DeregisterRequest("r0").ToWire(), mallory).Response.Code);
        Assert.NotNull(_store.Get("r0"));
    }

    [Fact]
    public void An_update_binding_is_checked_against_the_registered_version()
    {
        var handler = Handler();
        handler.Handle(Register(), Alice);

        Assert.Equal(ResponseCode.BadRequest, handler.Handle(new UpdateRequest("r0") { Binding = "UQ" }.ToWire(), Alice).Response.Code);
        Assert.Equal(ResponseCode.Changed, handler.Handle(new UpdateRequest("r0") { Binding = "T" }.ToWire(), Alice).Response.Code);
    }

    [Fact]
    public void Deregister_removes_and_reports_the_registration()
    {
        var handler = Handler();
        handler.Handle(Register(), Alice);

        var outcome = handler.Handle(new DeregisterRequest("r0").ToWire(), Alice);

        Assert.Equal(ResponseCode.Deleted, outcome.Response.Code);
        Assert.Equal("r0", outcome.Previous!.Id);
        Assert.Null(_store.Get("r0"));
        Assert.Equal(ResponseCode.NotFound, handler.Handle(new DeregisterRequest("r0").ToWire(), Alice).Response.Code);
    }

    [Fact]
    public void Other_paths_and_methods_are_refused()
    {
        var handler = Handler();

        Assert.Equal(ResponseCode.NotFound, handler.Handle(new WireRequest(Method.Post) { Path = ["bs"] }, Alice).Response.Code);
        Assert.Equal(ResponseCode.NotFound, handler.Handle(new WireRequest(Method.Post) { Path = ["rd", "a", "b"] }, Alice).Response.Code);
        Assert.Equal(ResponseCode.MethodNotAllowed, handler.Handle(new WireRequest(Method.Get) { Path = ["rd"] }, Alice).Response.Code);
        Assert.Equal(ResponseCode.MethodNotAllowed, handler.Handle(new WireRequest(Method.Put) { Path = ["rd", "r0"] }, Alice).Response.Code);
        Assert.False(RegistrationHandler.IsRegistrationRequest(new WireRequest(Method.Post) { Path = ["dp"] }));
    }

    [Fact]
    public void Default_registration_ids_are_random_and_url_safe()
    {
        var ids = Enumerable.Range(0, 100).Select(_ => RegistrationHandlerOptions.RandomRegistrationId()).ToList();

        Assert.Equal(100, ids.Distinct().Count());
        Assert.All(ids, id => Assert.Matches("^[0-9A-Za-z]{10}$", id));
    }
}

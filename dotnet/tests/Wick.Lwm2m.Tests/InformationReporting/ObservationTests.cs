using System.Text;
using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.DeviceManagement;
using Wick.Lwm2m.InformationReporting;
using Wick.Lwm2m.Model;
using Wick.Lwm2m.Senml;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.Tests.InformationReporting;

public sealed class ObservationTests
{
    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private static readonly Lwm2mPath Temperature = Lwm2mPath.Parse("/3303/0/5700");

    private static Observation Relation(string registration = "r0", byte token = 1) =>
        new(registration, [Temperature], new byte[] { token }, false, T0);

    [Fact]
    public void A_new_relation_has_seen_nothing()
    {
        var observation = Relation();

        Assert.Null(observation.LastSequence);
        Assert.Null(observation.LastNotifiedAt);
        Assert.False(observation.IsComposite);
        Assert.Equal("01", observation.TokenHex);
    }

    [Fact]
    public void A_plain_relation_observes_exactly_one_path()
    {
        Assert.Throws<ArgumentException>(() => new Observation("r0", [Temperature, Temperature], default, false, T0));
        Assert.Throws<ArgumentException>(() => new Observation("r0", [], default, true, T0));
        Assert.True(new Observation("r0", [Temperature], default, true, T0).IsComposite);
    }

    [Fact]
    public void The_first_notification_is_always_fresh()
    {
        Assert.True(Relation().IsFresh(12345, T0));
    }

    [Theory]
    [InlineData(10u, 11u, true)]
    [InlineData(10u, 9u, false)]
    [InlineData(10u, 10u, false)]
    [InlineData(16777215u, 0u, true)]
    [InlineData(0u, 16777215u, false)]
    [InlineData(0u, 8388609u, false)]
    [InlineData(0u, 8388607u, true)]
    public void Freshness_follows_rfc_7641_with_wrap_around(uint last, uint arriving, bool fresh)
    {
        var observation = Relation() with { LastSequence = last, LastNotifiedAt = T0 };

        Assert.Equal(fresh, observation.IsFresh(arriving, T0.AddSeconds(1)));
    }

    [Fact]
    public void After_128_seconds_any_notification_is_fresh()
    {
        var observation = Relation() with { LastSequence = 10, LastNotifiedAt = T0 };

        Assert.False(observation.IsFresh(9, T0.AddSeconds(128)));
        Assert.True(observation.IsFresh(9, T0.AddSeconds(129)));
    }

    [Fact]
    public void Accept_advances_or_reports_stale()
    {
        var observation = Relation();

        var advanced = observation.Accept(10, T0.AddSeconds(1))!;
        Assert.Equal(10u, advanced.LastSequence);
        Assert.Equal(T0.AddSeconds(1), advanced.LastNotifiedAt);
        Assert.Null(advanced.Accept(9, T0.AddSeconds(2)));
    }

    [Fact]
    public void Establish_takes_the_relation_from_the_observe_exchange()
    {
        var request = new ObserveRequest(Temperature, ContentFormats.SenmlCbor) { Token = new byte[] { 0xAB } };
        var response = request.ParseResponse(new WireResponse(ResponseCode.Content) { ContentFormat = 0, Observe = 7, Payload = "20"u8.ToArray() }, ObjectRegistry.Standard);

        var observation = Observation.Establish("r0", request, response, T0);

        Assert.Equal(7u, observation.LastSequence);
        Assert.Equal("AB", observation.TokenHex);
        Assert.Equal(ContentFormats.SenmlCbor, observation.ContentFormat);
        Assert.Equal(new CancelObservationRequest(Temperature) { Token = new byte[] { 0xAB } }, CancelObservationRequest.For(observation));

        var refused = request.ParseResponse(new WireResponse(ResponseCode.Content) { ContentFormat = 0, Payload = "20"u8.ToArray() }, ObjectRegistry.Standard);
        Assert.Throws<ArgumentException>(() => Observation.Establish("r0", request, refused, T0));
    }
}

public sealed class ObservationStoreTests
{
    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static Observation Relation(string registration, byte token) =>
        new(registration, [Lwm2mPath.Parse("/3303/0/5700")], new byte[] { token }, false, T0);

    [Fact]
    public void Add_get_and_remove()
    {
        var store = new InMemoryObservationStore();
        store.Add(Relation("r0", 1));

        Assert.NotNull(store.Get("r0", [1]));
        Assert.Null(store.Get("r0", [2]));
        Assert.Null(store.Get("r1", [1]));
        Assert.NotNull(store.Remove("r0", [1]));
        Assert.Null(store.Remove("r0", [1]));
        Assert.Equal(0, store.Count);
    }

    [Fact]
    public void Re_adding_a_token_replaces_rather_than_duplicates()
    {
        var store = new InMemoryObservationStore();
        store.Add(Relation("r0", 1));
        store.Add(Relation("r0", 1) with { ContentFormat = 112 });

        Assert.Single(store.GetByRegistration("r0"));
        Assert.Equal(112, store.Get("r0", [1])!.ContentFormat);
    }

    [Fact]
    public void Remove_by_registration_drops_only_that_registration()
    {
        var store = new InMemoryObservationStore();
        store.Add(Relation("r0", 1));
        store.Add(Relation("r0", 2));
        store.Add(Relation("r1", 1));

        Assert.Equal(["01", "02"], store.GetByRegistration("r0").Select(o => o.TokenHex));
        Assert.Equal(2, store.RemoveByRegistration("r0").Count);
        Assert.Empty(store.GetByRegistration("r0"));
        Assert.Single(store.GetByRegistration("r1"));
        Assert.Empty(store.RemoveByRegistration("r0"));
    }

    [Fact]
    public void Accept_classifies_notifications()
    {
        var store = new InMemoryObservationStore();
        store.Add(Relation("r0", 1));

        Assert.Equal(NotificationOrder.Fresh, store.Accept("r0", [1], 5, T0, out var first));
        Assert.Equal(5u, first!.LastSequence);
        Assert.Equal(NotificationOrder.Stale, store.Accept("r0", [1], 4, T0, out var stale));
        Assert.Equal(5u, stale!.LastSequence);
        Assert.Equal(NotificationOrder.Unknown, store.Accept("r0", [9], 6, T0, out var unknown));
        Assert.Null(unknown);
        Assert.Equal(5u, store.Get("r0", [1])!.LastSequence);
    }

    [Fact]
    public void Is_safe_under_concurrent_notifications()
    {
        var store = new InMemoryObservationStore();
        store.Add(Relation("r0", 1));

        Parallel.For(1, 2001, i => store.Accept("r0", [1], (uint)i, T0, out _));

        Assert.Equal(2000u, store.Get("r0", [1])!.LastSequence);
    }
}

public sealed class NotificationTests
{
    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public void A_single_path_notification_decodes_against_its_relation()
    {
        var observation = new Observation("r0", [Lwm2mPath.Parse("/3303/0/5700")], new byte[] { 1 }, false, T0);
        var response = new WireResponse(ResponseCode.Content) { Observe = 8, ContentFormat = ContentFormats.SenmlJson, Payload = """[{"bn":"/3303/0/5700","v":23.5}]"""u8.ToArray() };

        var notification = Notification.Parse(response, observation, ObjectRegistry.Standard);

        Assert.True(notification.IsSuccess);
        Assert.Equal(8u, notification.Sequence);
        Assert.Equal(new Lwm2mSingleResource(5700, Lwm2mValue.FromFloat(23.5)), notification.Node);
        Assert.Empty(notification.Nodes);
    }

    [Fact]
    public void A_composite_notification_names_its_paths()
    {
        var paths = new[] { Lwm2mPath.Parse("/3303/0/5700"), Lwm2mPath.Parse("/3/0/9") };
        var observation = new Observation("r0", paths, new byte[] { 2 }, true, T0);
        var payload = Lwm2mNodeCodec.EncodeComposite(
            [KeyValuePair.Create(paths[0], (Lwm2mNode?)new Lwm2mSingleResource(5700, Lwm2mValue.FromFloat(19)))],
            ContentFormats.SenmlCbor,
            ObjectRegistry.Standard);

        var notification = Notification.Parse(new WireResponse(ResponseCode.Content) { Observe = 2, ContentFormat = 112, Payload = payload }, observation, ObjectRegistry.Standard);

        Assert.Null(notification.Node);
        Assert.Equal(new Lwm2mSingleResource(5700, Lwm2mValue.FromFloat(19)), notification.Nodes[0].Value);
        Assert.Null(notification.Nodes[1].Value);
    }

    [Fact]
    public void An_error_notification_ends_the_relation()
    {
        var observation = new Observation("r0", [Lwm2mPath.Parse("/3303/0/5700")], new byte[] { 1 }, false, T0);

        var notification = Notification.Parse(new WireResponse(ResponseCode.NotFound) { Payload = "gone"u8.ToArray() }, observation);

        Assert.False(notification.IsSuccess);
        Assert.Equal("gone", notification.ErrorMessage);
        Assert.Null(notification.Sequence);
    }

    [Fact]
    public void A_content_response_without_observe_is_not_a_notification()
    {
        var observation = new Observation("r0", [Lwm2mPath.Parse("/3303/0/5700")], new byte[] { 1 }, false, T0);

        var e = Assert.Throws<Lwm2mException>(() => Notification.Parse(new WireResponse(ResponseCode.Content) { ContentFormat = 0, Payload = "1"u8.ToArray() }, observation));

        Assert.Equal(Lwm2mErrorCode.InvalidResponse, e.Code);
    }
}

public sealed class SendTests
{
    [Fact]
    public void Parses_a_send_and_decodes_its_values_by_time()
    {
        var payload = SenmlCborCodec.Encode(new SenmlPack(
            new SenmlRecord { BaseName = "/3303/0/", BaseTime = 1_700_000_000, Name = "5700", NumberValue = SenmlNumber.FromFloat(21.5) },
            new SenmlRecord { Name = "5700", Time = 10, NumberValue = 22 }));
        var request = new WireRequest(Method.Post) { Path = ["dp"], ContentFormat = 112, Payload = payload };

        var send = SendRequest.Parse(request);
        var groups = send.DecodeNodes(ObjectRegistry.Standard);

        Assert.True(SendRequest.IsSend(request));
        Assert.Equal(2, groups.Count);
        Assert.Equal(new Lwm2mSingleResource(5700, Lwm2mValue.FromFloat(22)), groups[1].Nodes.Single().Value);
        Assert.Equal(ResponseCode.Changed, SendRequest.Accepted().Code);
    }

    [Fact]
    public void Refuses_what_is_not_a_senml_post_to_dp()
    {
        Assert.Equal(Lwm2mErrorCode.UnsupportedOperation, Assert.Throws<Lwm2mException>(() => SendRequest.Parse(new WireRequest(Method.Post) { Path = ["rd"] })).Code);
        Assert.Equal(Lwm2mErrorCode.UnsupportedContentFormat, Assert.Throws<Lwm2mException>(() => SendRequest.Parse(new WireRequest(Method.Post) { Path = ["dp"], ContentFormat = 11542 })).Code);
        Assert.Equal(Lwm2mErrorCode.UnsupportedContentFormat, Assert.Throws<Lwm2mException>(() => SendRequest.Parse(new WireRequest(Method.Post) { Path = ["dp"] })).Code);
    }

    [Fact]
    public void Decodes_json_too()
    {
        var request = new WireRequest(Method.Post) { Path = ["dp"], ContentFormat = 110, Payload = Encoding.UTF8.GetBytes("""[{"n":"/3/0/9","v":42}]""") };

        var groups = SendRequest.Parse(request).DecodeNodes(ObjectRegistry.Standard);

        Assert.Null(groups.Single().Time);
        Assert.Equal(new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(42)), groups.Single().Nodes.Single().Value);
    }
}

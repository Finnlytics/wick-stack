using System.Text;
using Wick.Lwm2m.Attributes;
using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.DeviceManagement;
using Wick.Lwm2m.Model;
using Wick.Lwm2m.Tests.Support;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.Tests.DeviceManagement;

public sealed class WireTests
{
    [Fact]
    public void Request_options_are_ordered_by_number()
    {
        var request = new WireRequest(Method.Get) { Path = ["3", "0", "9"], Accept = 112, Observe = 0 };

        var options = CoapOptions.ToOptions(request);

        Assert.Equal([6, 11, 11, 11, 17], options.Select(o => o.Number));
        Assert.Empty(options[0].Value.ToArray());
        Assert.Equal([112], options[4].Value.ToArray());
    }

    [Fact]
    public void Requests_survive_the_option_mapping()
    {
        var request = new WireRequest(Method.Post)
        {
            Path = ["rd"],
            Query = [new QueryParameter("ep", "d1"), new QueryParameter("Q", null), new QueryParameter("x", "a=b")],
            ContentFormat = 40,
            Payload = "</1/0>"u8.ToArray(),
            Token = new byte[] { 1, 2, 3 },
        };

        var back = CoapOptions.ToRequest(request.Method, CoapOptions.ToOptions(request), request.Payload, request.Token);

        Assert.Equal(request, back);
        Assert.Equal("POST /rd?ep=d1&Q&x=a=b cf=40 payload=6B", request.ToString());
    }

    [Fact]
    public void Responses_survive_the_option_mapping()
    {
        var response = new WireResponse(ResponseCode.Created) { LocationPath = ["rd", "abc"], ContentFormat = 0, Observe = 70000 };

        var options = CoapOptions.ToOptions(response);
        var back = CoapOptions.ToResponse(response.Code, options);

        Assert.Equal([6, 8, 8, 12], options.Select(o => o.Number));
        Assert.Equal(response, back);
    }

    [Theory]
    [InlineData(0u, "")]
    [InlineData(112u, "70")]
    [InlineData(1543u, "0607")]
    [InlineData(11542u, "2D16")]
    [InlineData(16777215u, "FFFFFF")]
    public void Unsigned_options_use_the_shortest_form(uint value, string hex)
    {
        Assert.Equal(hex, Hex.Of(CoapOptions.EncodeUInt(value)));
        Assert.Equal(value, CoapOptions.DecodeUInt(Hex.Bytes(hex)));
    }

    [Fact]
    public void Response_codes_map_to_and_from_their_byte()
    {
        Assert.Equal(0x45, ResponseCode.Content.ToByte());
        Assert.Equal(ResponseCode.NotFound, ResponseCode.FromByte(0x84));
        Assert.Equal("4.04", ResponseCode.NotFound.ToString());
        Assert.True(ResponseCode.Changed.IsSuccess);
        Assert.True(ResponseCode.ServiceUnavailable.IsError);
        Assert.Equal(new ResponseCode(4, 3), ResponseCode.FromByte(0x83));
    }

    [Fact]
    public void Tokens_are_at_most_eight_bytes()
    {
        Assert.Throws<ArgumentException>(() => new WireRequest(Method.Get) { Token = new byte[9] });
    }
}

public sealed class RequestWireTests
{
    private static Lwm2mPath P(string text) => Lwm2mPath.Parse(text);

    private static T RoundTrip<T>(T request)
        where T : Lwm2mRequest
    {
        var wire = request.ToWire();
        var back = CoapOptions.ToRequest(wire.Method, CoapOptions.ToOptions(wire), wire.Payload, wire.Token);
        return Assert.IsType<T>(Lwm2mRequest.FromWire(back));
    }

    [Fact]
    public void Read_is_a_get_with_optional_accept()
    {
        Assert.Equal(new WireRequest(Method.Get) { Path = ["3", "0", "9"] }, new ReadRequest(P("/3/0/9")).ToWire());
        Assert.Equal(112, new ReadRequest(P("/3/0/9"), 112).ToWire().Accept);
        foreach (var path in new[] { "/3", "/3/0", "/3/0/9", "/3/0/6/1" })
        {
            Assert.Equal(new ReadRequest(P(path), 112), RoundTrip(new ReadRequest(P(path), 112)));
        }
    }

    [Fact]
    public void Write_replace_is_a_put_and_partial_update_a_post()
    {
        var replace = new WriteRequest(P("/1/0/1"), WriteMode.Replace, ContentFormats.PlainText, "60"u8.ToArray());
        var partial = new WriteRequest(P("/1/0"), WriteMode.PartialUpdate, ContentFormats.SenmlCbor, new byte[] { 0x80 });

        Assert.Equal(Method.Put, replace.ToWire().Method);
        Assert.Equal(Method.Post, partial.ToWire().Method);
        Assert.Equal(replace, RoundTrip(replace));
        Assert.Equal(partial, RoundTrip(partial));
    }

    [Fact]
    public void Write_paths_are_checked()
    {
        Assert.Throws<Lwm2mException>(() => new WriteRequest(P("/1"), WriteMode.Replace, 0, default));
        Assert.Throws<Lwm2mException>(() => new WriteRequest(P("/1/0/1"), WriteMode.PartialUpdate, 0, default));
    }

    [Fact]
    public void An_empty_payload_is_still_a_write_when_a_content_format_is_present()
    {
        var wire = new WireRequest(Method.Put) { Path = ["1", "0", "1"], ContentFormat = 0 };

        Assert.IsType<WriteRequest>(Lwm2mRequest.FromWire(wire));
    }

    [Fact]
    public void Execute_sends_arguments_as_plain_text()
    {
        var withArguments = new ExecuteRequest(P("/3/0/4"), "1='x'");
        var without = new ExecuteRequest(P("/3/0/4"));

        Assert.Equal(new WireRequest(Method.Post) { Path = ["3", "0", "4"], ContentFormat = 0, Payload = "1='x'"u8.ToArray() }, withArguments.ToWire());
        Assert.Equal(new WireRequest(Method.Post) { Path = ["3", "0", "4"] }, without.ToWire());
        Assert.Null(new ExecuteRequest(P("/3/0/4"), string.Empty).Arguments);
        Assert.Equal(withArguments, RoundTrip(withArguments));
        Assert.Equal(without, RoundTrip(without));
        Assert.Throws<Lwm2mException>(() => new ExecuteRequest(P("/3/0")));
    }

    [Fact]
    public void Discover_is_a_get_accepting_link_format()
    {
        Assert.Equal(40, new DiscoverRequest(P("/3")).ToWire().Accept);
        Assert.Equal(new DiscoverRequest(P("/3/0")), RoundTrip(new DiscoverRequest(P("/3/0"))));
        Assert.Throws<Lwm2mException>(() => new DiscoverRequest(P("/3/0/6/1")));
    }

    [Fact]
    public void Create_and_delete()
    {
        var create = new CreateRequest(P("/3303"), ContentFormats.Tlv, new byte[] { 0x08, 0x00, 0x00 });

        Assert.Equal(Method.Post, create.ToWire().Method);
        Assert.Equal(create, RoundTrip(create));
        Assert.Equal(new WireRequest(Method.Delete) { Path = ["3303", "1"] }, new DeleteRequest(P("/3303/1")).ToWire());
        Assert.Equal(new DeleteRequest(P("/3303/1")), RoundTrip(new DeleteRequest(P("/3303/1"))));
        Assert.Throws<Lwm2mException>(() => new CreateRequest(P("/3303/0"), 0, default));
        Assert.Throws<Lwm2mException>(() => new DeleteRequest(P("/3303")));
    }

    [Fact]
    public void Write_attributes_is_a_put_with_a_query_and_no_body()
    {
        var request = new WriteAttributesRequest(P("/3303/0/5700"), new NotificationAttributes { Pmin = 10, Pmax = 60, Gt = 25.5m, St = AttributeValue<decimal>.Cleared });

        var wire = request.ToWire();

        Assert.Equal(Method.Put, wire.Method);
        Assert.Null(wire.ContentFormat);
        Assert.True(wire.Payload.IsEmpty);
        Assert.Equal(["pmin=10", "pmax=60", "gt=25.5", "st"], wire.Query.Select(q => q.ToString()));
        Assert.Equal(request, RoundTrip(request));
    }

    [Fact]
    public void Write_attributes_validates_the_set()
    {
        Assert.Equal(Lwm2mErrorCode.InvalidAttribute, Assert.Throws<Lwm2mException>(() => new WriteAttributesRequest(P("/3/0"), new NotificationAttributes())).Code);
        Assert.Equal(Lwm2mErrorCode.InvalidAttribute, Assert.Throws<Lwm2mException>(() => new WriteAttributesRequest(P("/3/0"), new NotificationAttributes { Gt = 1 })).Code);
        Assert.Equal(Lwm2mErrorCode.InvalidAttribute, Assert.Throws<Lwm2mException>(() => Lwm2mRequest.FromWire(new WireRequest(Method.Put) { Path = ["3", "0"], Query = [new("pmin", "soon")] })).Code);
    }

    [Fact]
    public void Observe_and_cancel_are_gets_distinguished_by_the_observe_option()
    {
        var observe = new ObserveRequest(P("/3303/0/5700"), 112) { Token = new byte[] { 0xA1 } };
        var cancel = new CancelObservationRequest(P("/3303/0/5700")) { Token = new byte[] { 0xA1 } };

        Assert.Equal(0u, observe.ToWire().Observe);
        Assert.Equal(1u, cancel.ToWire().Observe);
        Assert.Equal(observe, RoundTrip(observe));
        Assert.Equal(cancel, RoundTrip(cancel));
    }

    [Fact]
    public void Observe_wins_over_accept_link_format()
    {
        var wire = new WireRequest(Method.Get) { Path = ["3"], Accept = 40, Observe = 0 };

        Assert.IsType<ObserveRequest>(Lwm2mRequest.FromWire(wire));
    }

    [Theory]
    [InlineData(ContentFormats.SenmlCbor)]
    [InlineData(ContentFormats.SenmlJson)]
    public void Composite_requests_carry_a_senml_path_list(int format)
    {
        var paths = new[] { P("/3/0/9"), P("/3303/0/5700") };
        var read = new ReadCompositeRequest(paths, format, 112);
        var observe = new ObserveCompositeRequest(paths, format) { Token = new byte[] { 7 } };
        var cancel = new CancelObserveCompositeRequest(paths, format) { Token = new byte[] { 7 } };

        Assert.Equal(Method.Fetch, read.ToWire().Method);
        Assert.Empty(read.ToWire().Path);
        Assert.Equal(read, RoundTrip(read));
        Assert.Equal(observe, RoundTrip(observe));
        Assert.Equal(cancel, RoundTrip(cancel));
    }

    [Fact]
    public void Composite_body_bytes_are_the_senml_path_list()
    {
        var wire = new ReadCompositeRequest([P("/3/0/9")], ContentFormats.SenmlJson).ToWire();

        Assert.Equal("""[{"n":"/3/0/9"}]""", Encoding.UTF8.GetString(wire.Payload.Span));
    }

    [Fact]
    public void Composite_requests_need_senml_and_a_path()
    {
        Assert.Throws<Lwm2mException>(() => new ReadCompositeRequest([P("/3/0/9")], ContentFormats.Tlv));
        Assert.Throws<Lwm2mException>(() => new ReadCompositeRequest([]));
        Assert.Throws<Lwm2mException>(() => Lwm2mRequest.FromWire(new WireRequest(Method.Fetch) { Payload = new byte[] { 0x80 } }));
        Assert.Throws<Lwm2mException>(() => Lwm2mRequest.FromWire(new WireRequest(Method.Fetch) { ContentFormat = 112, Payload = Hex.Bytes("81A10063782F79") }));
    }

    [Fact]
    public void Write_composite_is_an_ipatch_on_the_root()
    {
        var request = WriteCompositeRequest.Create(
            [KeyValuePair.Create(P("/3/0/14"), (Lwm2mNode)new Lwm2mSingleResource(14, Lwm2mValue.FromString("+01:00"))),
             KeyValuePair.Create(P("/1/0/1"), (Lwm2mNode)new Lwm2mSingleResource(1, Lwm2mValue.FromInteger(300)))],
            ContentFormats.SenmlJson,
            ObjectRegistry.Standard);

        Assert.Equal(Method.IPatch, request.ToWire().Method);
        Assert.Equal("""[{"bn":"/3/0/14","vs":"+01:00"},{"bn":"/1/0/1","v":300}]""", Encoding.UTF8.GetString(request.Payload.Span));
        Assert.Equal(request, RoundTrip(request));
        Assert.Throws<Lwm2mException>(() => Lwm2mRequest.FromWire(new WireRequest(Method.IPatch)));
    }

    [Fact]
    public void Post_is_disambiguated_by_path_depth()
    {
        WireRequest Post(params string[] path) => new(Method.Post) { Path = path, ContentFormat = 112, Payload = new byte[] { 0x80 } };

        Assert.IsType<CreateRequest>(Lwm2mRequest.FromWire(Post("3")));
        Assert.Equal(WriteMode.PartialUpdate, Assert.IsType<WriteRequest>(Lwm2mRequest.FromWire(Post("3", "0"))).Mode);
        Assert.IsType<ExecuteRequest>(Lwm2mRequest.FromWire(Post("3", "0", "4")));
        Assert.Equal(Lwm2mErrorCode.UnsupportedOperation, Assert.Throws<Lwm2mException>(() => Lwm2mRequest.FromWire(Post("3", "0", "4", "1"))).Code);
    }

    [Fact]
    public void Registration_and_send_traffic_is_not_device_management()
    {
        Assert.Equal(Lwm2mErrorCode.InvalidPath, Assert.Throws<Lwm2mException>(() => Lwm2mRequest.FromWire(new WireRequest(Method.Post) { Path = ["rd"] })).Code);
        Assert.Equal(Lwm2mErrorCode.InvalidPath, Assert.Throws<Lwm2mException>(() => Lwm2mRequest.FromWire(new WireRequest(Method.Post) { Path = ["dp"] })).Code);
        Assert.Equal(Lwm2mErrorCode.InvalidPath, Assert.Throws<Lwm2mException>(() => Lwm2mRequest.FromWire(new WireRequest(Method.Get))).Code);
    }

    [Fact]
    public void Write_create_from_a_node_encodes_it()
    {
        var node = new Lwm2mSingleResource(1, Lwm2mValue.FromInteger(300));

        var request = WriteRequest.Create(P("/1/0/1"), node, WriteMode.Replace, ContentFormats.Tlv, ObjectRegistry.Standard);

        Assert.Equal("C201012C", Hex.Of(request.Payload));
        Assert.Equal(node, request.DecodeNode(ObjectRegistry.Standard));
    }

    [Fact]
    public void Create_from_instances_encodes_an_object()
    {
        var instance = new Lwm2mObjectInstance(1, new Lwm2mSingleResource(5700, Lwm2mValue.FromFloat(20)), new Lwm2mSingleResource(5701, Lwm2mValue.FromString("Cel")));

        var request = CreateRequest.Create(P("/3303"), [instance], ContentFormats.SenmlCbor, ObjectRegistry.Standard);

        Assert.Equal(new Lwm2mObject(3303, instance), request.DecodeNode(ObjectRegistry.Standard));
        Assert.Throws<Lwm2mException>(() => CreateRequest.Create(P("/3303"), [instance], ContentFormats.PlainText));
    }
}

public sealed class ResponseParsingTests
{
    private static readonly ObjectRegistry Model = ObjectRegistry.Standard;

    [Fact]
    public void A_read_decodes_the_value_in_the_format_the_client_chose()
    {
        var read = new ReadRequest(Lwm2mPath.Parse("/3/0/9"));

        var tlv = read.ParseResponse(new WireResponse(ResponseCode.Content) { ContentFormat = ContentFormats.Tlv, Payload = Hex.Bytes("C10957") }, Model);
        var text = read.ParseResponse(new WireResponse(ResponseCode.Content) { ContentFormat = 0, Payload = "87"u8.ToArray() }, Model);
        var noFormat = read.ParseResponse(new WireResponse(ResponseCode.Content) { Payload = "87"u8.ToArray() }, Model);

        var expected = new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(87));
        Assert.Equal(expected, tlv.Node);
        Assert.Equal(expected, text.Node);
        Assert.Equal(expected, noFormat.Node);
        Assert.Equal(ContentFormats.Tlv, tlv.ContentFormat);
    }

    [Fact]
    public void An_error_response_is_an_outcome_with_its_diagnostic()
    {
        var response = new ReadRequest(Lwm2mPath.Parse("/3/0/99")).ParseResponse(new WireResponse(ResponseCode.NotFound) { Payload = "no such resource"u8.ToArray() });

        Assert.False(response.IsSuccess);
        Assert.Equal(ResponseCode.NotFound, response.Code);
        Assert.Equal("no such resource", response.ErrorMessage);
        Assert.Null(response.Node);
    }

    [Fact]
    public void An_unexpected_success_code_is_a_protocol_error()
    {
        var e = Assert.Throws<Lwm2mException>(() => new ReadRequest(Lwm2mPath.Parse("/3/0/9")).ParseResponse(new WireResponse(ResponseCode.Changed)));

        Assert.Equal(Lwm2mErrorCode.InvalidResponse, e.Code);
    }

    [Fact]
    public void A_multi_value_read_without_a_content_format_is_refused()
    {
        var e = Assert.Throws<Lwm2mException>(() => new ReadRequest(Lwm2mPath.Parse("/3/0")).ParseResponse(new WireResponse(ResponseCode.Content) { Payload = new byte[] { 0xC1 } }));

        Assert.Equal(Lwm2mErrorCode.InvalidResponse, e.Code);
    }

    [Fact]
    public void Write_execute_delete_and_write_attributes_expect_their_codes()
    {
        var write = new WriteRequest(Lwm2mPath.Parse("/1/0/1"), WriteMode.Replace, 0, "60"u8.ToArray());

        Assert.True(write.ParseResponse(new WireResponse(ResponseCode.Changed)).IsSuccess);
        Assert.Equal(ResponseCode.MethodNotAllowed, write.ParseResponse(new WireResponse(ResponseCode.MethodNotAllowed)).Code);
        Assert.True(new ExecuteRequest(Lwm2mPath.Parse("/3/0/4")).ParseResponse(new WireResponse(ResponseCode.Changed)).IsSuccess);
        Assert.True(new DeleteRequest(Lwm2mPath.Parse("/3303/1")).ParseResponse(new WireResponse(ResponseCode.Deleted)).IsSuccess);
        Assert.Throws<Lwm2mException>(() => new DeleteRequest(Lwm2mPath.Parse("/3303/1")).ParseResponse(new WireResponse(ResponseCode.Changed)));
    }

    [Fact]
    public void Create_reports_the_new_instance_location()
    {
        var create = new CreateRequest(Lwm2mPath.Parse("/3303"), ContentFormats.Tlv, Hex.Bytes("C0"));

        Assert.Equal(Lwm2mPath.Parse("/3303/2"), create.ParseResponse(new WireResponse(ResponseCode.Created) { LocationPath = ["3303", "2"] }).Location);
        Assert.Null(create.ParseResponse(new WireResponse(ResponseCode.Created)).Location);
        Assert.Throws<Lwm2mException>(() => create.ParseResponse(new WireResponse(ResponseCode.Created) { LocationPath = ["rd", "x"] }));
    }

    [Fact]
    public void Discover_parses_links_and_their_attributes()
    {
        var response = new DiscoverRequest(Lwm2mPath.Parse("/3303/0")).ParseResponse(new WireResponse(ResponseCode.Content)
        {
            ContentFormat = 40,
            Payload = "</3303/0>;pmin=10,</3303/0/5700>;pmax=60;gt=25.5,</3303/0/5701>"u8.ToArray(),
        });

        Assert.Equal(["/3303/0", "/3303/0/5700", "/3303/0/5701"], response.Links.Select(l => l.Target));
        var attributes = NotificationAttributes.FromLinkParams(response.Links[1].Parameters);
        Assert.Equal(60, attributes.Pmax.Value);
        Assert.Equal(25.5m, attributes.Gt.Value);
        Assert.Throws<Lwm2mException>(() => new DiscoverRequest(Lwm2mPath.Parse("/3")).ParseResponse(new WireResponse(ResponseCode.Content) { ContentFormat = 112 }));
    }

    [Fact]
    public void Observe_is_established_only_when_the_option_comes_back()
    {
        var observe = new ObserveRequest(Lwm2mPath.Parse("/3303/0/5700"));
        var established = observe.ParseResponse(new WireResponse(ResponseCode.Content) { ContentFormat = 0, Observe = 3, Payload = "21.5"u8.ToArray() }, Model);
        var plainRead = observe.ParseResponse(new WireResponse(ResponseCode.Content) { ContentFormat = 0, Payload = "21.5"u8.ToArray() }, Model);

        Assert.True(established.IsEstablished);
        Assert.Equal(3u, established.Sequence);
        Assert.Equal(new Lwm2mSingleResource(5700, Lwm2mValue.FromFloat(21.5)), established.Node);
        Assert.False(plainRead.IsEstablished);
    }

    [Fact]
    public void Read_composite_parses_a_node_per_path()
    {
        var paths = new[] { Lwm2mPath.Parse("/3/0/9"), Lwm2mPath.Parse("/3303/0/5700") };
        var request = new ReadCompositeRequest(paths);
        var body = Lwm2mNodeCodec.EncodeComposite(
            [KeyValuePair.Create(paths[0], (Lwm2mNode?)new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(80)))],
            ContentFormats.SenmlCbor);

        var response = request.ParseResponse(new WireResponse(ResponseCode.Content) { ContentFormat = 112, Payload = body }, Model);

        Assert.Equal(new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(80)), response.Nodes[0].Value);
        Assert.Null(response.Nodes[1].Value);
    }
}

public sealed class ExecuteArgumentsTests
{
    [Fact]
    public void Formats_and_parses_the_argument_list()
    {
        var arguments = new[] { new ExecuteArgument(0, "abc"), new ExecuteArgument(1, null), new ExecuteArgument(5, string.Empty) };

        var text = ExecuteArguments.Format(arguments);

        Assert.Equal("0='abc',1,5=''", text);
        Assert.Equal(arguments, ExecuteArguments.Parse(text));
        Assert.Empty(ExecuteArguments.Parse(string.Empty));
    }

    [Theory]
    [InlineData("a")]
    [InlineData("10")]
    [InlineData("0=abc")]
    [InlineData("0='abc")]
    [InlineData("0,")]
    [InlineData("0='a b'")]
    [InlineData("0='a\"b'")]
    public void Rejects_text_outside_the_grammar(string text)
    {
        Assert.Equal(Lwm2mErrorCode.MalformedText, Assert.Throws<Lwm2mException>(() => ExecuteArguments.Parse(text)).Code);
    }

    [Fact]
    public void Refuses_to_format_what_it_could_not_parse()
    {
        Assert.Throws<ArgumentException>(() => ExecuteArguments.Format([new ExecuteArgument(10, null)]));
        Assert.Throws<ArgumentException>(() => ExecuteArguments.Format([new ExecuteArgument(0, "it's")]));
    }
}

using System.Text;
using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.Model;
using Wick.Lwm2m.Senml;
using Wick.Lwm2m.Tests.Support;

namespace Wick.Lwm2m.Tests.Codecs;

public sealed class NodeCodecTests
{
    private static readonly ObjectRegistry Model = ObjectRegistry.Standard;

    private static Lwm2mObjectInstance Device() => new(0,
        new Lwm2mSingleResource(0, Lwm2mValue.FromString("Open Mobile Alliance")),
        new Lwm2mMultipleResource(6, Lwm2mType.Integer, new Lwm2mResourceInstance(0, Lwm2mValue.FromInteger(1)), new Lwm2mResourceInstance(1, Lwm2mValue.FromInteger(5))),
        new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(87)),
        new Lwm2mSingleResource(13, Lwm2mValue.FromTime(1367491215)));

    [Fact]
    public void Senml_output_follows_leshans_base_name_layout()
    {
        var json = Encoding.UTF8.GetString(Lwm2mNodeCodec.Encode(Device(), Lwm2mPath.Parse("/3/0"), ContentFormats.SenmlJson, Model));

        Assert.Equal(
            """[{"bn":"/3/0/","n":"0","vs":"Open Mobile Alliance"},{"n":"6/0","v":1},{"n":"6/1","v":5},{"n":"9","v":87},{"n":"13","v":1367491215}]""",
            json);
    }

    [Fact]
    public void A_single_resource_is_named_by_its_base_name_alone()
    {
        var json = Encoding.UTF8.GetString(Lwm2mNodeCodec.Encode(new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(87)), Lwm2mPath.Parse("/3/0/9"), ContentFormats.SenmlJson));

        Assert.Equal("""[{"bn":"/3/0/9","v":87}]""", json);
    }

    [Theory]
    [InlineData(ContentFormats.SenmlJson)]
    [InlineData(ContentFormats.SenmlCbor)]
    [InlineData(ContentFormats.Tlv)]
    public void An_object_round_trips_with_the_model(int format)
    {
        var node = new Lwm2mObject(3, Device(), new Lwm2mObjectInstance(1, new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(12))));
        var path = Lwm2mPath.Parse("/3");

        Assert.Equal(node, Lwm2mNodeCodec.Decode(Lwm2mNodeCodec.Encode(node, path, format, Model), format, path, Model));
    }

    [Fact]
    public void The_model_recovers_types_senml_cannot_carry()
    {
        var json = """[{"bn":"/3/0/","n":"13","v":1700000000},{"n":"9","v":87}]"""u8;

        var typed = (Lwm2mObjectInstance)Lwm2mNodeCodec.Decode(json, ContentFormats.SenmlJson, Lwm2mPath.Parse("/3/0"), Model);
        var untyped = (Lwm2mObjectInstance)Lwm2mNodeCodec.Decode(json, ContentFormats.SenmlJson, Lwm2mPath.Parse("/3/0"));

        Assert.Equal(Lwm2mValue.FromTime(1700000000), ((Lwm2mSingleResource)typed.Resources[13]).Value);
        Assert.Equal(Lwm2mValue.FromInteger(1700000000), ((Lwm2mSingleResource)untyped.Resources[13]).Value);
    }

    [Fact]
    public void A_whole_number_is_accepted_for_a_float_resource()
    {
        var node = Lwm2mNodeCodec.Decode("""[{"bn":"/3303/0/5700","v":22}]"""u8, ContentFormats.SenmlJson, Lwm2mPath.Parse("/3303/0/5700"), Model);

        Assert.Equal(new Lwm2mSingleResource(5700, Lwm2mValue.FromFloat(22)), node);
    }

    [Theory]
    [InlineData("""[{"bn":"/3/0/9","vs":"high"}]""")]
    [InlineData("""[{"bn":"/3/0/9","v":1.5}]""")]
    [InlineData("""[{"bn":"/3/0/9","vb":true}]""")]
    public void A_value_that_cannot_satisfy_its_declared_type_is_refused(string json)
    {
        var e = Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Decode(Encoding.UTF8.GetBytes(json), ContentFormats.SenmlJson, Lwm2mPath.Parse("/3/0/9"), Model));

        Assert.Equal(Lwm2mErrorCode.TypeMismatch, e.Code);
    }

    [Fact]
    public void Object_links_sent_as_strings_are_accepted_where_declared()
    {
        // Leshan's node encoder writes Object Links with vs rather than the vlo LwM2M 1.1 defines.
        var model = ObjectRegistry.From([new ObjectModel(9, "Nine", true, false, [new ResourceModel(0, "Link", ResourceOperations.ReadWrite, false, false, Lwm2mType.ObjectLink)])]);

        var node = Lwm2mNodeCodec.Decode("""[{"bn":"/9/0/0","vs":"3:0"}]"""u8, ContentFormats.SenmlJson, Lwm2mPath.Parse("/9/0/0"), model);

        Assert.Equal(new Lwm2mSingleResource(0, Lwm2mValue.FromObjectLink(new ObjectLink(3, 0))), node);
        Assert.Contains("\"vlo\":\"3:0\"", Encoding.UTF8.GetString(Lwm2mNodeCodec.Encode(node, Lwm2mPath.Parse("/9/0/0"), ContentFormats.SenmlJson, model)), StringComparison.Ordinal);
    }

    [Fact]
    public void Encoding_converts_values_to_the_declared_type_where_lossless()
    {
        // Resource 5700 is a Float and 13 a Time; the caller supplied integers.
        var bytes = Lwm2mNodeCodec.Encode(new Lwm2mSingleResource(5700, Lwm2mValue.FromInteger(22)), Lwm2mPath.Parse("/3303/0/5700"), ContentFormats.Tlv, Model);
        Assert.Equal("E816440840360000000000 00".Replace(" ", string.Empty, StringComparison.Ordinal), Hex.Of(bytes));

        var e = Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Encode(new Lwm2mSingleResource(9, Lwm2mValue.FromString("x")), Lwm2mPath.Parse("/3/0/9"), ContentFormats.Tlv, Model));
        Assert.Equal(Lwm2mErrorCode.TypeMismatch, e.Code);
    }

    [Fact]
    public void Relative_and_empty_names_resolve_against_the_request_path()
    {
        var pack = new SenmlPack(new SenmlRecord { Name = "9", NumberValue = 87 });
        var node = Lwm2mNodeCodec.Decode(SenmlCborCodec.Encode(pack), ContentFormats.SenmlCbor, Lwm2mPath.Parse("/3/0"), Model);

        Assert.Equal(new Lwm2mObjectInstance(0, new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(87))), node);

        var bare = Lwm2mNodeCodec.Decode("""[{"v":87}]"""u8, ContentFormats.SenmlJson, Lwm2mPath.Parse("/3/0/9"), Model);
        Assert.Equal(new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(87)), bare);
    }

    [Fact]
    public void Records_outside_the_request_path_are_refused()
    {
        var e = Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Decode("""[{"n":"/4/0/1","v":1}]"""u8, ContentFormats.SenmlJson, Lwm2mPath.Parse("/3/0"), Model));

        Assert.Equal(Lwm2mErrorCode.InvalidPath, e.Code);
    }

    [Fact]
    public void A_node_that_does_not_fit_the_path_is_refused()
    {
        var resource = new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(87));

        Assert.Equal(Lwm2mErrorCode.InvalidNode, Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Encode(resource, Lwm2mPath.Parse("/3/0/10"), ContentFormats.SenmlJson)).Code);
        Assert.Equal(Lwm2mErrorCode.InvalidNode, Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Encode(resource, Lwm2mPath.Parse("/3/0"), ContentFormats.SenmlJson)).Code);
    }

    [Fact]
    public void Plain_text_and_opaque_carry_single_values_only()
    {
        var path = Lwm2mPath.Parse("/3/0/9");
        var single = new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(87));

        Assert.Equal("87", Encoding.UTF8.GetString(Lwm2mNodeCodec.Encode(single, path, ContentFormats.PlainText, Model)));
        Assert.Equal(single, Lwm2mNodeCodec.Decode("87"u8, ContentFormats.PlainText, path, Model));
        Assert.Equal(Lwm2mErrorCode.UnsupportedContentFormat, Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Encode(Device(), Lwm2mPath.Parse("/3/0"), ContentFormats.PlainText)).Code);
        Assert.Equal(Lwm2mErrorCode.UnsupportedContentFormat, Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Decode("1"u8, ContentFormats.PlainText, Lwm2mPath.Parse("/3/0/6"), Model)).Code);
        Assert.Equal(Lwm2mErrorCode.UnsupportedContentFormat, Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Decode([1], ContentFormats.Opaque, path, Model)).Code);
    }

    [Fact]
    public void Plain_text_reads_a_resource_instance()
    {
        Assert.Equal(new Lwm2mResourceInstance(1, Lwm2mValue.FromInteger(5)), Lwm2mNodeCodec.Decode("5"u8, ContentFormats.PlainText, Lwm2mPath.Parse("/3/0/6/1"), Model));
    }

    [Fact]
    public void Unsupported_formats_are_named()
    {
        var e = Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Decode([], ContentFormats.Lwm2mCbor, Lwm2mPath.Parse("/3/0"), Model));

        Assert.Equal(Lwm2mErrorCode.UnsupportedContentFormat, e.Code);
        Assert.False(Lwm2mNodeCodec.IsSupported(ContentFormats.Lwm2mJson));
        Assert.True(Lwm2mNodeCodec.IsSupported(ContentFormats.Tlv));
    }

    [Fact]
    public void Without_a_model_a_multiple_resource_is_recognised_from_its_paths()
    {
        var node = Lwm2mNodeCodec.Decode("""[{"bn":"/9/0/","n":"6/0","v":1},{"n":"6/1","v":2.5}]"""u8, ContentFormats.SenmlJson, Lwm2mPath.Parse("/9/0"));

        var resource = (Lwm2mMultipleResource)((Lwm2mObjectInstance)node).Resources[6];
        Assert.Equal(Lwm2mType.Float, resource.Type);
        Assert.Equal(Lwm2mValue.FromFloat(1), resource.Instances[0].Value);
    }

    [Fact]
    public void Composite_payloads_split_by_requested_path()
    {
        var paths = new[] { "/3/0/9", "/3303/0", "/6/0/0" }.Select(Lwm2mPath.Parse).ToList();
        var nodes = new Dictionary<Lwm2mPath, Lwm2mNode?>
        {
            [paths[0]] = new Lwm2mSingleResource(9, Lwm2mValue.FromInteger(87)),
            [paths[1]] = new Lwm2mObjectInstance(0, new Lwm2mSingleResource(5700, Lwm2mValue.FromFloat(22.5))),
            [paths[2]] = null,
        };

        var bytes = Lwm2mNodeCodec.EncodeComposite(nodes, ContentFormats.SenmlCbor, Model);
        var decoded = Lwm2mNodeCodec.DecodeComposite(bytes, ContentFormats.SenmlCbor, paths, Model);

        Assert.Equal(paths, decoded.Select(d => d.Key));
        Assert.Equal(nodes[paths[0]], decoded[0].Value);
        Assert.Equal(nodes[paths[1]], decoded[1].Value);
        Assert.Null(decoded[2].Value);
    }

    [Fact]
    public void Composite_records_outside_every_requested_path_are_refused()
    {
        var e = Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.DecodeComposite("""[{"n":"/4/0/1","v":1}]"""u8, ContentFormats.SenmlJson, [Lwm2mPath.Parse("/3/0")], Model));

        Assert.Equal(Lwm2mErrorCode.InvalidPath, e.Code);
    }

    [Fact]
    public void Composite_needs_senml()
    {
        Assert.Equal(Lwm2mErrorCode.UnsupportedContentFormat, Assert.Throws<Lwm2mException>(() =>
            Lwm2mNodeCodec.EncodeComposite([], ContentFormats.Tlv)).Code);
    }

    [Fact]
    public void Timestamped_payloads_group_by_time_and_resource()
    {
        var json = """
            [{"bn":"/3303/0/","bt":1700000000,"n":"5700","v":21.5},
             {"n":"5701","vs":"Cel"},
             {"n":"5700","t":60,"v":22.0},
             {"bn":"/3/0/","n":"9","t":60,"v":80}]
            """;

        var groups = Lwm2mNodeCodec.DecodeTimestamped(Encoding.UTF8.GetBytes(json), ContentFormats.SenmlJson, Model);

        Assert.Equal([(SenmlNumber)1700000000, (SenmlNumber)1700000060], groups.Select(g => g.Time!.Value));
        Assert.Equal(["/3303/0/5700", "/3303/0/5701"], groups[0].Nodes.Select(n => n.Key.ToString()));
        Assert.Equal(["/3/0/9", "/3303/0/5700"], groups[1].Nodes.Select(n => n.Key.ToString()));
        Assert.Equal(new Lwm2mSingleResource(5700, Lwm2mValue.FromFloat(22)), groups[1].Nodes[1].Value);
    }
}

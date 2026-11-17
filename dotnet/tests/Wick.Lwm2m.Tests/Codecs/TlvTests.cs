using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.Model;
using Wick.Lwm2m.Senml;
using Wick.Lwm2m.Tests.Support;

namespace Wick.Lwm2m.Tests.Codecs;

public sealed class TlvPrimitiveTests
{
    private static string Encode(params TlvEntry[] entries) => Hex.Of(Tlv.Encode(entries));

    private static TlvEntry Resource(int id, params byte[] value) => TlvEntry.WithValue(TlvEntryType.Resource, id, value);

    [Fact]
    public void A_short_value_rides_in_the_type_byte()
    {
        Assert.Equal("C10957", Encode(Resource(9, 87)));
    }

    [Fact]
    public void Lengths_widen_at_8_256_and_65536_bytes()
    {
        Assert.Equal("C80108" + new string('A', 16), Encode(Resource(1, Enumerable.Repeat((byte)0xAA, 8).ToArray())));
        Assert.StartsWith("D001012C", Encode(Resource(1, new byte[300])), StringComparison.Ordinal);
        Assert.StartsWith("D801011170", Encode(Resource(1, new byte[70_000])), StringComparison.Ordinal);
    }

    [Fact]
    public void A_wide_identifier_sets_bit_5()
    {
        Assert.Equal("E1012C01", Encode(Resource(300, 1)));
    }

    [Fact]
    public void Each_entry_type_has_its_own_bits()
    {
        Assert.StartsWith("C1", Encode(Resource(0, 1)), StringComparison.Ordinal);
        Assert.StartsWith("41", Encode(TlvEntry.WithValue(TlvEntryType.ResourceInstance, 0, [1])), StringComparison.Ordinal);
        Assert.StartsWith("83", Encode(TlvEntry.WithChildren(TlvEntryType.MultipleResource, 0, [TlvEntry.WithValue(TlvEntryType.ResourceInstance, 0, [1])])), StringComparison.Ordinal);
        Assert.StartsWith("03", Encode(TlvEntry.WithChildren(TlvEntryType.ObjectInstance, 0, [Resource(0, 1)])), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("C1")]
    [InlineData("C801")]
    [InlineData("C109")]
    [InlineData("0302C505")]
    [InlineData("E1")]
    public void Malformed_input_is_rejected(string hex)
    {
        Assert.Equal(Lwm2mErrorCode.MalformedTlv, Assert.Throws<Lwm2mException>(() => Tlv.Decode(Hex.Bytes(hex))).Code);
    }

    [Fact]
    public void An_empty_payload_has_no_entries()
    {
        Assert.Empty(Tlv.Decode([]));
    }

    // The examples from the LwM2M specification's TLV section. Decoding then re-encoding must give
    // the same bytes, which shows both directions agree with the spec rather than only with each other.
    public static TheoryData<string> SpecificationVectors => new()
    {
        DeviceResources,
        DeviceInstance,
        "08000EC10001C101008302417F07C1037F080212C10003C101008702417F0761013601C1037F",
        "08000FC10001C40100015180C10601C10755",
        "88000C440000420000440100420001C8010D38363133383030373535353030C40212345678",
        "080026C8000B6D79536572766963652031C8010F496E7465726E65742E31352E323334C40200430000080126C8000B6D79536572766963652032C8010F496E7465726E65742E31352E323335C402FFFFFFFF",
    };

    internal const string DeviceResources =
        "C800144F70656E204D6F62696C6520416C6C69616E6365C801164C69676874776569676874204D324D20436C69656E74C80209333435303030313233C303312E30860641000141010588070842000ED842011388870841007D42010384C10964C10A0F830B410000C40D5182428FC60E2B30323A3030C11055";

    internal const string DeviceInstance = "080079" + DeviceResources;

    [Theory]
    [MemberData(nameof(SpecificationVectors))]
    public void Specification_examples_round_trip(string hex)
    {
        var bytes = Hex.Bytes(hex);

        Assert.Equal(hex, Hex.Of(Tlv.Encode(Tlv.Decode(bytes))));
    }

    [Fact]
    public void The_device_example_has_the_structure_the_spec_describes()
    {
        var entries = Tlv.Decode(Hex.Bytes(DeviceResources));

        var manufacturer = entries.Single(e => e.Id == 0);
        Assert.Equal(TlvEntryType.Resource, manufacturer.Type);
        Assert.Equal("Open Mobile Alliance", System.Text.Encoding.UTF8.GetString(manufacturer.Value.Span));

        var powerSources = entries.Single(e => e.Id == 6);
        Assert.Equal(TlvEntryType.MultipleResource, powerSources.Type);
        Assert.Equal([(0, 1), (1, 5)], powerSources.Children.Select(c => (c.Id, (int)c.Value.Span[0])));

        var wrapped = Tlv.Decode(Hex.Bytes(DeviceInstance)).Single();
        Assert.Equal(TlvEntryType.ObjectInstance, wrapped.Type);
        Assert.Equal(DeviceResources, Hex.Of(Tlv.Encode(wrapped.Children)));
    }

    [Theory]
    [InlineData(0L, "00")]
    [InlineData(127L, "7F")]
    [InlineData(128L, "0080")]
    [InlineData(-128L, "80")]
    [InlineData(-129L, "FF7F")]
    [InlineData(2147483647L, "7FFFFFFF")]
    [InlineData(2147483648L, "0000000080000000")]
    [InlineData(long.MinValue, "8000000000000000")]
    public void Integers_take_the_shortest_signed_width(long value, string hex)
    {
        Assert.Equal(hex, Hex.Of(Tlv.EncodeInteger(value)));
        Assert.Equal(value, Tlv.DecodeInteger(Hex.Bytes(hex)));
    }

    [Fact]
    public void Integers_decode_at_the_odd_widths_peers_emit()
    {
        Assert.Equal(1, Tlv.DecodeInteger(Hex.Bytes("000001")));
        Assert.Equal(1, Tlv.DecodeInteger(Hex.Bytes("0000000001")));
        Assert.Equal(-1, Tlv.DecodeInteger(Hex.Bytes("FFFFFF")));
        Assert.Throws<Lwm2mException>(() => Tlv.DecodeInteger(new byte[9]));
        Assert.Throws<Lwm2mException>(() => Tlv.DecodeInteger([]));
    }

    [Fact]
    public void Unsigned_integers_widen_rather_than_wrap()
    {
        Assert.Equal("00C8", Hex.Of(Tlv.EncodeUnsignedInteger(200)));
        Assert.Equal(200UL, Tlv.DecodeUnsignedInteger(Hex.Bytes("00C8")));
        Assert.Equal(200UL, Tlv.DecodeUnsignedInteger(Hex.Bytes("C8")));
        Assert.Equal("FFFFFFFFFFFFFFFF", Hex.Of(Tlv.EncodeUnsignedInteger(ulong.MaxValue)));
        Assert.Equal(ulong.MaxValue, Tlv.DecodeUnsignedInteger(Hex.Bytes("FFFFFFFFFFFFFFFF")));
    }

    [Fact]
    public void Floats_encode_as_doubles_and_decode_from_either_width()
    {
        Assert.Equal("4036800000000000", Hex.Of(Tlv.EncodeFloat(22.5)));
        Assert.Equal(22.5, Tlv.DecodeFloat(Hex.Bytes("4036800000000000")));
        Assert.Equal(22.5, Tlv.DecodeFloat(Hex.Bytes("41B40000")));
        Assert.Throws<Lwm2mException>(() => Tlv.DecodeFloat([1, 2, 3]));
    }

    [Fact]
    public void Booleans_and_object_links()
    {
        Assert.True(Tlv.DecodeBoolean(Tlv.EncodeBoolean(true)));
        Assert.False(Tlv.DecodeBoolean(Tlv.EncodeBoolean(false)));
        Assert.True(Tlv.DecodeBoolean([2]));
        Assert.Throws<Lwm2mException>(() => Tlv.DecodeBoolean([0, 1]));

        Assert.Equal("00030000", Hex.Of(Tlv.EncodeObjectLink(new ObjectLink(3, 0))));
        Assert.Equal(ObjectLink.Null, Tlv.DecodeObjectLink(Hex.Bytes("FFFFFFFF")));
        Assert.Throws<Lwm2mException>(() => Tlv.DecodeObjectLink([1, 2]));
    }
}

public sealed class TlvCodecTests
{
    private static readonly ObjectRegistry DeviceModel = ObjectRegistry.Standard;

    private static string Encode(SenmlPack pack, string path) => Hex.Of(TlvCodec.Encode(pack, Lwm2mPath.Parse(path), DeviceModel));

    [Fact]
    public void An_object_instance_path_emits_bare_resources()
    {
        Assert.Equal("C10957", Encode(new SenmlPack(new SenmlRecord { Name = "/3/0/9", NumberValue = 87 }), "/3/0"));
    }

    [Fact]
    public void An_object_path_wraps_each_instance()
    {
        var pack = new SenmlPack(
            new SenmlRecord { Name = "/3/0/9", NumberValue = 87 },
            new SenmlRecord { Name = "/3/1/9", NumberValue = 88 });

        Assert.Equal("0300C109570301C10958", Encode(pack, "/3"));
    }

    [Fact]
    public void Instances_under_a_resource_make_a_multiple_resource()
    {
        var pack = new SenmlPack(
            new SenmlRecord { Name = "/3/0/6/0", NumberValue = 1 },
            new SenmlRecord { Name = "/3/0/6/1", NumberValue = 5 });

        Assert.Equal("8606410001410105", Encode(pack, "/3/0"));
        Assert.Equal("410001", Encode(new SenmlPack(pack.Records[0]), "/3/0/6/0"));
    }

    [Fact]
    public void Entries_are_ordered_by_id()
    {
        var pack = new SenmlPack(
            new SenmlRecord { Name = "/3/0/9", NumberValue = 87 },
            new SenmlRecord { Name = "/3/0/0", StringValue = "ACME" });

        Assert.Equal("C40041434D45C10957", Encode(pack, "/3/0"));
    }

    [Fact]
    public void Records_outside_the_request_path_are_refused()
    {
        var pack = new SenmlPack(new SenmlRecord { Name = "/4/0/1", NumberValue = 1 });

        Assert.Equal(Lwm2mErrorCode.InvalidPath, Assert.Throws<Lwm2mException>(() => TlvCodec.Encode(pack, Lwm2mPath.Parse("/3/0"))).Code);
    }

    [Fact]
    public void Without_a_model_values_encode_from_their_shape_and_decode_as_opaque()
    {
        var path = Lwm2mPath.Parse("/9/0");
        var pack = new SenmlPack(
            new SenmlRecord { Name = "/9/0/1", NumberValue = 87 },
            new SenmlRecord { Name = "/9/0/2", NumberValue = SenmlNumber.FromFloat(22.5) });

        var bytes = TlvCodec.Encode(pack, path);
        var decoded = TlvCodec.Decode(bytes, path);

        Assert.Equal("C10157C802084036800000000000", Hex.Of(bytes));
        Assert.All(decoded.Records, r => Assert.Equal(SenmlValueKind.Opaque, r.ValueKind));
    }

    [Fact]
    public void A_value_that_cannot_satisfy_its_declared_type_is_refused()
    {
        var pack = new SenmlPack(new SenmlRecord { Name = "/3/0/9", StringValue = "high" });

        Assert.Equal(Lwm2mErrorCode.TypeMismatch, Assert.Throws<Lwm2mException>(() => TlvCodec.Encode(pack, Lwm2mPath.Parse("/3/0"), DeviceModel)).Code);
    }

    [Fact]
    public void The_device_example_decodes_against_the_standard_model()
    {
        var pack = TlvCodec.Decode(Hex.Bytes(TlvPrimitiveTests.DeviceResources), Lwm2mPath.Parse("/3/0"), DeviceModel);
        var byName = pack.Records.ToDictionary(r => r.Name!);

        Assert.Equal("Open Mobile Alliance", byName["/3/0/0"].StringValue);
        Assert.Equal((SenmlNumber)1367491215, byName["/3/0/13"].NumberValue);
        Assert.Equal((SenmlNumber)5, byName["/3/0/6/1"].NumberValue);
        Assert.Equal("+02:00", byName["/3/0/14"].StringValue);
    }
}

public sealed class TlvNodeTests
{
    [Fact]
    public void The_device_example_round_trips_as_a_typed_node()
    {
        var path = Lwm2mPath.Parse("/3/0");
        var bytes = Hex.Bytes(TlvPrimitiveTests.DeviceResources);

        var node = (Lwm2mObjectInstance)Lwm2mNodeCodec.Decode(bytes, ContentFormats.Tlv, path, ObjectRegistry.Standard);

        Assert.Equal(Lwm2mValue.FromTime(1367491215), ((Lwm2mSingleResource)node.Resources[13]).Value);
        Assert.Equal(Lwm2mType.Integer, node.Resources[6].Type);
        Assert.True(node.Resources[6].IsMultiple);
        Assert.Equal(TlvPrimitiveTests.DeviceResources, Hex.Of(Lwm2mNodeCodec.Encode(node, path, ContentFormats.Tlv, ObjectRegistry.Standard)));
    }

    [Fact]
    public void A_wrapped_instance_decodes_at_object_and_instance_level()
    {
        var bytes = Hex.Bytes(TlvPrimitiveTests.DeviceInstance);

        var asObject = (Lwm2mObject)Lwm2mNodeCodec.Decode(bytes, ContentFormats.Tlv, Lwm2mPath.Parse("/3"), ObjectRegistry.Standard);
        var asInstance = Lwm2mNodeCodec.Decode(bytes, ContentFormats.Tlv, Lwm2mPath.Parse("/3/0"), ObjectRegistry.Standard);

        Assert.Equal(asObject.Instances[0], asInstance);
        Assert.Equal(TlvPrimitiveTests.DeviceInstance, Hex.Of(Lwm2mNodeCodec.Encode(asObject, Lwm2mPath.Parse("/3"), ContentFormats.Tlv, ObjectRegistry.Standard)));
    }

    [Fact]
    public void A_single_instance_object_may_arrive_without_an_instance_entry()
    {
        var node = (Lwm2mObject)Lwm2mNodeCodec.Decode(Hex.Bytes("C10957"), ContentFormats.Tlv, Lwm2mPath.Parse("/3"), ObjectRegistry.Standard);

        Assert.Equal(Lwm2mValue.FromInteger(87), ((Lwm2mSingleResource)node.Instances[0].Resources[9]).Value);
    }

    [Fact]
    public void An_empty_multiple_resource_survives()
    {
        var node = new Lwm2mMultipleResource(6, Lwm2mType.Integer);
        var path = Lwm2mPath.Parse("/3/0/6");

        var bytes = Lwm2mNodeCodec.Encode(node, path, ContentFormats.Tlv, ObjectRegistry.Standard);

        Assert.Equal("8006", Hex.Of(bytes));
        Assert.Equal(node, Lwm2mNodeCodec.Decode(bytes, ContentFormats.Tlv, path, ObjectRegistry.Standard));
    }

    [Fact]
    public void A_resource_entry_with_the_wrong_id_is_refused()
    {
        var e = Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Decode(Hex.Bytes("C10A57"), ContentFormats.Tlv, Lwm2mPath.Parse("/3/0/9"), ObjectRegistry.Standard));

        Assert.Equal(Lwm2mErrorCode.MalformedTlv, e.Code);
    }

    [Fact]
    public void A_length_that_does_not_fit_the_declared_type_is_refused()
    {
        // Resource 13 is a Time; three bytes of float would not be, and neither would a nine-byte integer.
        var e = Assert.Throws<Lwm2mException>(() => Lwm2mNodeCodec.Decode(Hex.Bytes("C80D09010203040506070809"), ContentFormats.Tlv, Lwm2mPath.Parse("/3/0/13"), ObjectRegistry.Standard));

        Assert.Equal(Lwm2mErrorCode.MalformedTlv, e.Code);
    }
}

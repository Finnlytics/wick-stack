using System.Text;
using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.Codecs.Internal;
using Wick.Lwm2m.Senml;
using Wick.Lwm2m.Tests.Support;

namespace Wick.Lwm2m.Tests.Codecs;

public sealed class CborPrimitiveTests
{
    [Theory]
    [InlineData(0, "00")]
    [InlineData(23, "17")]
    [InlineData(24, "1818")]
    [InlineData(255, "18FF")]
    [InlineData(256, "190100")]
    [InlineData(65536, "1A00010000")]
    [InlineData(4294967296, "1B0000000100000000")]
    [InlineData(-1, "20")]
    [InlineData(-24, "37")]
    [InlineData(-25, "3818")]
    [InlineData(-1000, "3903E7")]
    public void Integers_use_the_shortest_head(long value, string hex)
    {
        var writer = new CborWriter();
        writer.WriteInteger(value);

        Assert.Equal(hex, Hex.Of(writer.ToArray()));
        Assert.Equal((SenmlNumber)value, CborReader.Decode(writer.ToArray()));
    }

    [Theory]
    [InlineData(1.5, "F93E00")]
    [InlineData(0.0, "F90000")]
    [InlineData(-0.0, "F98000")]
    [InlineData(22.5, "F94DA0")]
    [InlineData(65504.0, "F97BFF")]
    [InlineData(100000.0, "FA47C35000")]
    [InlineData(3.4028234663852886E38, "FA7F7FFFFF")]
    [InlineData(1.1, "FB3FF199999999999A")]
    [InlineData(double.PositiveInfinity, "F97C00")]
    [InlineData(double.NaN, "F97E00")]
    public void Floats_use_the_shortest_exact_width(double value, string hex)
    {
        var writer = new CborWriter();
        writer.WriteFloat(value);

        Assert.Equal(hex, Hex.Of(writer.ToArray()));
        Assert.Equal(SenmlNumber.FromFloat(value), CborReader.Decode(writer.ToArray()));
    }

    [Fact]
    public void Full_unsigned_and_negative_64_bit_range_decodes()
    {
        Assert.Equal(SenmlNumber.FromInteger(ulong.MaxValue), CborReader.Decode(Hex.Bytes("1BFFFFFFFFFFFFFFFF")));
        Assert.Equal(SenmlNumber.FromInteger(SenmlNumber.MinInteger), CborReader.Decode(Hex.Bytes("3BFFFFFFFFFFFFFFFF")));
    }

    [Theory]
    [InlineData("C482001A6553F100", 1700000000L)]
    [InlineData("C4820005", 5L)]
    [InlineData("C482011819", 250L)]
    public void Tag_4_decimal_fractions_resolve_to_integers(string hex, long expected)
    {
        Assert.Equal((SenmlNumber)expected, CborReader.Decode(Hex.Bytes(hex)));
    }

    [Fact]
    public void Tag_4_with_a_negative_exponent_resolves_to_a_float()
    {
        // [-1, 225] is 22.5.
        Assert.Equal(SenmlNumber.FromFloat(22.5), CborReader.Decode(Hex.Bytes("C4822018E1")));
    }

    [Theory]
    [InlineData("")]
    [InlineData("19")]
    [InlineData("6261")]
    [InlineData("9F")]
    [InlineData("5F")]
    [InlineData("FC")]
    [InlineData("0000")]
    [InlineData("C48100")]
    [InlineData("62FFFE")]
    public void Malformed_input_is_rejected(string hex)
    {
        var e = Assert.Throws<Lwm2mException>(() => CborReader.Decode(Hex.Bytes(hex)));
        Assert.Equal(Lwm2mErrorCode.MalformedCbor, e.Code);
    }

    [Fact]
    public void Declared_lengths_beyond_the_input_are_rejected_without_allocating()
    {
        // An array claiming 2^32 items in a five-byte payload.
        Assert.Throws<Lwm2mException>(() => CborReader.Decode(Hex.Bytes("9AFFFFFFFF")));
    }

    [Fact]
    public void Deep_nesting_is_rejected()
    {
        var bytes = Enumerable.Repeat((byte)0x81, 200).Append((byte)0x00).ToArray();
        Assert.Equal(Lwm2mErrorCode.MalformedCbor, Assert.Throws<Lwm2mException>(() => CborReader.Decode(bytes)).Code);
    }
}

public sealed class JavaDoubleTests
{
    [Theory]
    [InlineData(1.5, "1.5")]
    [InlineData(22.5, "22.5")]
    [InlineData(30.0, "30.0")]
    [InlineData(100.0, "100.0")]
    [InlineData(0.0, "0.0")]
    [InlineData(-0.0, "-0.0")]
    [InlineData(0.001, "0.001")]
    [InlineData(0.0001, "1.0E-4")]
    [InlineData(1234567.0, "1234567.0")]
    [InlineData(9999999.0, "9999999.0")]
    [InlineData(1.0E7, "1.0E7")]
    [InlineData(12345678.9, "1.23456789E7")]
    [InlineData(-3.14, "-3.14")]
    [InlineData(1.0E-5, "1.0E-5")]
    [InlineData(1.0E100, "1.0E100")]
    [InlineData(0.1, "0.1")]
    [InlineData(double.MaxValue, "1.7976931348623157E308")]
    [InlineData(double.NaN, "NaN")]
    [InlineData(double.NegativeInfinity, "-Infinity")]
    public void Formats_like_java_double_to_string(double value, string expected)
    {
        Assert.Equal(expected, JavaDouble.Format(value));
    }
}

public sealed class SenmlCodecTests
{
    private static readonly SenmlPack Device = new(
        new SenmlRecord { BaseName = "/3/0/", Name = "0", StringValue = "Open Mobile Alliance" },
        new SenmlRecord { Name = "9", NumberValue = 87 },
        new SenmlRecord { Name = "13", NumberValue = 1_700_000_000 },
        new SenmlRecord { Name = "3", OpaqueValue = new byte[] { 0xDE, 0xAD } },
        new SenmlRecord { Name = "1", BooleanValue = true },
        new SenmlRecord { Name = "14", ObjectLinkValue = "1:0" },
        new SenmlRecord { Name = "5700", NumberValue = SenmlNumber.FromFloat(-1.25), Time = 5 });

    [Fact]
    public void Json_round_trips()
    {
        Assert.Equal(Device, SenmlJsonCodec.Decode(SenmlJsonCodec.Encode(Device)));
    }

    [Fact]
    public void Cbor_round_trips()
    {
        Assert.Equal(Device, SenmlCborCodec.Decode(SenmlCborCodec.Encode(Device)));
    }

    [Fact]
    public void Json_writes_fields_in_leshan_order()
    {
        var pack = new SenmlPack(new SenmlRecord { NumberValue = 1, Time = 2, Name = "n", BaseTime = 3, BaseName = "b" });

        Assert.Equal("""[{"bn":"b","bt":3,"n":"n","t":2,"v":1}]""", Encoding.UTF8.GetString(SenmlJsonCodec.Encode(pack)));
    }

    [Fact]
    public void Cbor_sorts_keys_canonically()
    {
        var pack = new SenmlPack(new SenmlRecord { ObjectLinkValue = "3:0", Time = 2, Name = "n", BaseTime = 3, BaseName = "b" });

        // n(0), t(6), bn(-2), bt(-3), then the text key "vlo".
        Assert.Equal("81A500616E060221616222036376 6C6F63333A30".Replace(" ", string.Empty, StringComparison.Ordinal), Hex.Of(SenmlCborCodec.Encode(pack)));
    }

    [Fact]
    public void Json_escapes_what_rfc_8259_requires()
    {
        var pack = new SenmlPack(new SenmlRecord { Name = "/3/0/0", StringValue = "a\"b\\c\nd\u0001é" });
        var json = Encoding.UTF8.GetString(SenmlJsonCodec.Encode(pack));

        Assert.Equal("""[{"n":"/3/0/0","vs":"a\"b\\c\nd\u0001é"}]""", json);
        Assert.Equal(pack, SenmlJsonCodec.Decode(Encoding.UTF8.GetBytes(json)));
    }

    [Fact]
    public void A_record_with_no_value_is_refused_unless_allowed()
    {
        var pack = new SenmlPack(new SenmlRecord { Name = "/3/0/9" });

        Assert.Equal(Lwm2mErrorCode.MissingValue, Assert.Throws<Lwm2mException>(() => SenmlCborCodec.Encode(pack)).Code);
        Assert.Equal(Lwm2mErrorCode.MissingValue, Assert.Throws<Lwm2mException>(() => SenmlJsonCodec.Encode(pack)).Code);
        Assert.Equal("81A100662F332F302F39", Hex.Of(SenmlCborCodec.Encode(pack, allowNoValue: true)));
    }

    [Fact]
    public void Leshan_value_precedence_applies_when_several_values_are_set()
    {
        var record = new SenmlRecord { Name = "x", NumberValue = 5, BooleanValue = true, StringValue = "s" };

        Assert.Equal(SenmlValueKind.Boolean, record.ValueKind);
        Assert.Equal("""[{"n":"x","vb":true}]""", Encoding.UTF8.GetString(SenmlJsonCodec.Encode(new SenmlPack(record))));
    }

    [Fact]
    public void Json_keeps_integers_and_floats_apart()
    {
        var pack = SenmlJsonCodec.Decode("""[{"n":"a","v":22},{"n":"b","v":22.0},{"n":"c","v":2e1},{"n":"d","v":-0}]"""u8);

        Assert.True(pack.Records[0].NumberValue!.Value.IsInteger);
        Assert.False(pack.Records[1].NumberValue!.Value.IsInteger);
        Assert.False(pack.Records[2].NumberValue!.Value.IsInteger);
        Assert.True(pack.Records[3].NumberValue!.Value.IsInteger);
    }

    [Fact]
    public void Json_carries_unsigned_integers_above_long()
    {
        var pack = new SenmlPack(new SenmlRecord { Name = "u", NumberValue = ulong.MaxValue });
        var json = SenmlJsonCodec.Encode(pack);

        Assert.Equal("""[{"n":"u","v":18446744073709551615}]""", Encoding.UTF8.GetString(json));
        Assert.Equal(pack, SenmlJsonCodec.Decode(json));
    }

    [Fact]
    public void Json_cannot_carry_non_finite_floats()
    {
        var pack = new SenmlPack(new SenmlRecord { Name = "x", NumberValue = double.NaN });

        Assert.Equal(Lwm2mErrorCode.UnencodableValue, Assert.Throws<Lwm2mException>(() => SenmlJsonCodec.Encode(pack)).Code);
    }

    [Theory]
    [InlineData("""{"n":"x"}""", Lwm2mErrorCode.MalformedSenml)]
    [InlineData("""[1]""", Lwm2mErrorCode.MalformedSenml)]
    [InlineData("""[{"n":5}]""", Lwm2mErrorCode.MalformedSenml)]
    [InlineData("""[{"v":"5"}]""", Lwm2mErrorCode.MalformedSenml)]
    [InlineData("""[{"vb":1}]""", Lwm2mErrorCode.MalformedSenml)]
    [InlineData("""[{"vd":"not base64!"}]""", Lwm2mErrorCode.MalformedSenml)]
    [InlineData("""[{"n":"x",}]""", Lwm2mErrorCode.MalformedJson)]
    [InlineData("""[{"n":"x"}""", Lwm2mErrorCode.MalformedJson)]
    [InlineData("""[{"n":"x"}] trailing""", Lwm2mErrorCode.MalformedJson)]
    [InlineData("""[01]""", Lwm2mErrorCode.MalformedJson)]
    [InlineData("""["\x"]""", Lwm2mErrorCode.MalformedJson)]
    public void Json_rejects_malformed_payloads(string json, Lwm2mErrorCode code)
    {
        Assert.Equal(code, Assert.Throws<Lwm2mException>(() => SenmlJsonCodec.Decode(Encoding.UTF8.GetBytes(json))).Code);
    }

    [Theory]
    [InlineData("A0", Lwm2mErrorCode.MalformedSenml)]
    [InlineData("8101", Lwm2mErrorCode.MalformedSenml)]
    [InlineData("81A10005", Lwm2mErrorCode.MalformedSenml)]
    [InlineData("81A1086161", Lwm2mErrorCode.MalformedSenml)]
    [InlineData("81A2", Lwm2mErrorCode.MalformedCbor)]
    public void Cbor_rejects_malformed_payloads(string hex, Lwm2mErrorCode code)
    {
        Assert.Equal(code, Assert.Throws<Lwm2mException>(() => SenmlCborCodec.Decode(Hex.Bytes(hex))).Code);
    }

    [Fact]
    public void Cbor_accepts_leshan_tag_4_times_and_unknown_labels()
    {
        // {0: "/3/0/9", 2: 87, 6: 4([0, 5]), 99: "ignored"}
        var pack = SenmlCborCodec.Decode(Hex.Bytes("81A400662F332F302F3902185706C482000518636769676E6F726564"));

        Assert.Equal((SenmlNumber)5L, pack.Records[0].Time);
    }

    [Fact]
    public void Resolve_applies_base_name_and_base_time()
    {
        var pack = new SenmlPack(
            new SenmlRecord { BaseName = "/3/0/", BaseTime = 1000, Name = "9", Time = 5, NumberValue = 1 },
            new SenmlRecord { Name = "0", StringValue = "OMA" },
            new SenmlRecord { BaseName = "/4/0/", Name = "1", NumberValue = 2, Time = SenmlNumber.FromFloat(0.5) });

        var resolved = pack.Resolve();

        Assert.Equal(["/3/0/9", "/3/0/0", "/4/0/1"], resolved.Select(r => r.Name));
        Assert.Equal([(SenmlNumber)1005L, (SenmlNumber)1000L, SenmlNumber.FromFloat(1000.5)], resolved.Select(r => r.Time!.Value));
    }

    [Fact]
    public void Resolve_leaves_time_null_when_none_is_in_scope()
    {
        Assert.Null(new SenmlPack(new SenmlRecord { Name = "/1/0/1", NumberValue = 1 }).Resolve()[0].Time);
    }

    [Fact]
    public void Paths_round_trip_through_a_pack()
    {
        var paths = new[] { "/3/0/9", "/3303/0/5700", "/1" }.Select(Lwm2mPath.Parse).ToList();

        Assert.Equal(paths, SenmlPack.FromPaths(paths).ToPaths());
        Assert.Equal(paths, SenmlCborCodec.Decode(SenmlCborCodec.Encode(SenmlPack.FromPaths(paths), allowNoValue: true)).ToPaths());
    }

    [Fact]
    public void To_paths_rejects_records_that_are_not_paths()
    {
        Assert.Equal(Lwm2mErrorCode.InvalidPath, Assert.Throws<Lwm2mException>(() => new SenmlPack(new SenmlRecord { Name = "/nope" }).ToPaths()).Code);
        Assert.Equal(Lwm2mErrorCode.MissingName, Assert.Throws<Lwm2mException>(() => new SenmlPack(new SenmlRecord { NumberValue = 1 }).ToPaths()).Code);
    }
}

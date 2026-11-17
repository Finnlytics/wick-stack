using System.Text.Json;
using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.Model;
using Wick.Lwm2m.Senml;
using Wick.Lwm2m.Tests.Support;

namespace Wick.Lwm2m.Tests.Codecs;

// Cross-implementation checks against bytes produced by Eclipse Leshan 2.0.0-M18
// (wick/tools/leshan_oracle). The fixtures are shared with the Elixir library and read in place.
// Where a fixture has a sibling .wick.bin, Wick deliberately diverges from Leshan (SenML CBOR
// time fields, ADR 0003) and the encoder is held to that file instead; Leshan's bytes must still
// decode to the same pack.
public sealed class SenmlCborOracleTests
{
    private const string Format = "senml_cbor";

    public static TheoryData<string> Stems => Fixtures.TheoryStems(Format);

    [Theory]
    [MemberData(nameof(Stems))]
    public void Encoder_matches_the_reference_bytes(string stem)
    {
        var spec = Fixtures.Spec(Format, stem);
        var expected = Reference(stem);

        var encoded = SenmlCborCodec.Encode(SenmlFixture.Pack(spec), SenmlFixture.AllowNoValue(spec));

        Assert.Equal(Hex.Of(expected), Hex.Of(encoded));
    }

    [Theory]
    [MemberData(nameof(Stems))]
    public void Leshan_bytes_decode_to_the_fixture_pack(string stem)
    {
        var spec = Fixtures.Spec(Format, stem);

        var decoded = SenmlCborCodec.Decode(Fixtures.Bytes(Format, stem + ".bin"));

        Assert.Equal(Normalise(SenmlFixture.Pack(spec)), Normalise(decoded));
    }

    [Theory]
    [MemberData(nameof(Stems))]
    public void Leshan_bytes_survive_decode_then_encode(string stem)
    {
        var spec = Fixtures.Spec(Format, stem);
        var decoded = SenmlCborCodec.Decode(Fixtures.Bytes(Format, stem + ".bin"));

        var reencoded = SenmlCborCodec.Encode(decoded, SenmlFixture.AllowNoValue(spec));

        Assert.Equal(Hex.Of(Reference(stem)), Hex.Of(reencoded));
    }

    [Fact]
    public void Divergent_fixtures_are_exactly_the_time_field_ones()
    {
        var overrides = Directory.GetFiles(Fixtures.Directory(Format), "*.wick.bin")
            .Select(f => Path.GetFileName(f)[..^".wick.bin".Length])
            .Order(StringComparer.Ordinal)
            .ToList();

        Assert.Equal(["09_base_name_plus_base_time", "13_per_record_time"], overrides);
        foreach (var stem in overrides)
        {
            // Leshan writes the time as tag 4 [0, n]; Wick writes the plain integer, three bytes shorter.
            Assert.Equal(Fixtures.Bytes(Format, stem + ".bin").Length - 3, Fixtures.Bytes(Format, stem + ".wick.bin").Length);
        }
    }

    [Fact]
    public void Every_bin_has_a_json_spec()
    {
        var bins = Directory.GetFiles(Fixtures.Directory(Format), "*.bin")
            .Select(Path.GetFileName)
            .OfType<string>()
            .Where(f => !f.EndsWith(".wick.bin", StringComparison.Ordinal))
            .Select(f => f[..^4]);

        Assert.All(bins, stem => Assert.True(Fixtures.Exists(Format, stem + ".json"), stem));
    }

    private static byte[] Reference(string stem) =>
        Fixtures.Exists(Format, stem + ".wick.bin") ? Fixtures.Bytes(Format, stem + ".wick.bin") : Fixtures.Bytes(Format, stem + ".bin");

    // Leshan omits empty names, so an empty string in the spec and an absent field mean the same.
    internal static SenmlPack Normalise(SenmlPack pack) => new(pack.Records.Select(r => r with
    {
        BaseName = string.IsNullOrEmpty(r.BaseName) ? null : r.BaseName,
        Name = string.IsNullOrEmpty(r.Name) ? null : r.Name,
    }));
}

public sealed class SenmlJsonOracleTests
{
    private const string Format = "senml_json";

    public static TheoryData<string> Stems => Fixtures.TheoryStems(Format);

    [Theory]
    [MemberData(nameof(Stems))]
    public void Encoder_matches_Leshan_byte_for_byte(string stem)
    {
        var spec = Fixtures.Spec(Format, stem);

        var encoded = SenmlJsonCodec.Encode(SenmlFixture.Pack(spec), SenmlFixture.AllowNoValue(spec));

        Assert.Equal(System.Text.Encoding.UTF8.GetString(Fixtures.Bytes(Format, stem + ".bin")), System.Text.Encoding.UTF8.GetString(encoded));
    }

    [Theory]
    [MemberData(nameof(Stems))]
    public void Leshan_bytes_decode_to_the_fixture_pack(string stem)
    {
        var spec = Fixtures.Spec(Format, stem);

        var decoded = SenmlJsonCodec.Decode(Fixtures.Bytes(Format, stem + ".bin"));

        Assert.Equal(SenmlCborOracleTests.Normalise(SenmlFixture.Pack(spec)), SenmlCborOracleTests.Normalise(decoded));
    }

    [Fact]
    public void Has_no_divergent_fixtures()
    {
        Assert.Empty(Directory.GetFiles(Fixtures.Directory(Format), "*.wick.bin"));
    }

    [Fact]
    public void Every_bin_has_a_json_spec()
    {
        var bins = Directory.GetFiles(Fixtures.Directory(Format), "*.bin").Select(f => Path.GetFileName(f)[..^4]);
        Assert.All(bins, stem => Assert.True(Fixtures.Exists(Format, stem + ".json"), stem));
    }
}

// TLV values are bare bytes, so both implementations are given the same declared model; without
// that, two encoders can agree byte for byte on the wrong thing.
public sealed class TlvOracleTests
{
    private const string Format = "tlv";

    public static TheoryData<string> Stems => Fixtures.TheoryStems(Format);

    [Theory]
    [MemberData(nameof(Stems))]
    public void Pack_encoder_matches_Leshan(string stem)
    {
        var spec = Fixtures.Spec(Format, stem);

        var encoded = TlvCodec.Encode(Pack(spec), PathOf(spec), Model(spec));

        Assert.Equal(Hex.Of(Fixtures.Bytes(Format, stem + ".bin")), Hex.Of(encoded));
    }

    [Theory]
    [MemberData(nameof(Stems))]
    public void Pack_decoder_reads_Leshan_bytes_back_to_the_fixture_values(string stem)
    {
        var spec = Fixtures.Spec(Format, stem);

        var decoded = TlvCodec.Decode(Fixtures.Bytes(Format, stem + ".bin"), PathOf(spec), Model(spec));

        Assert.Equal(Flatten(Pack(spec)), Flatten(decoded));
    }

    [Theory]
    [MemberData(nameof(Stems))]
    public void Node_encoder_matches_Leshan(string stem)
    {
        var spec = Fixtures.Spec(Format, stem);

        var encoded = Lwm2mNodeCodec.Encode(Node(spec), PathOf(spec), ContentFormats.Tlv, Model(spec));

        Assert.Equal(Hex.Of(Fixtures.Bytes(Format, stem + ".bin")), Hex.Of(encoded));
    }

    [Theory]
    [MemberData(nameof(Stems))]
    public void Node_decoder_reads_Leshan_bytes_back_to_the_fixture_node(string stem)
    {
        var spec = Fixtures.Spec(Format, stem);

        var decoded = Lwm2mNodeCodec.Decode(Fixtures.Bytes(Format, stem + ".bin"), ContentFormats.Tlv, PathOf(spec), Model(spec));

        Assert.Equal(Node(spec), decoded);
    }

    [Theory]
    [MemberData(nameof(Stems))]
    public void The_fixture_node_survives_every_format_that_can_carry_it(string stem)
    {
        var spec = Fixtures.Spec(Format, stem);
        var node = Node(spec);
        var path = PathOf(spec);
        var model = Model(spec);

        foreach (var format in new[] { ContentFormats.SenmlJson, ContentFormats.SenmlCbor, ContentFormats.Tlv })
        {
            var bytes = Lwm2mNodeCodec.Encode(node, path, format, model);
            Assert.Equal(node, Lwm2mNodeCodec.Decode(bytes, format, path, model));
        }
    }

    [Fact]
    public void Every_bin_has_a_json_spec()
    {
        var bins = Directory.GetFiles(Fixtures.Directory(Format), "*.bin").Select(f => Path.GetFileName(f)[..^4]);
        Assert.All(bins, stem => Assert.True(Fixtures.Exists(Format, stem + ".json"), stem));
    }

    private static Lwm2mPath PathOf(JsonElement spec) => Lwm2mPath.Parse(spec.GetProperty("path").GetString()!);

    private static ObjectRegistry Model(JsonElement spec)
    {
        var resources = spec.GetProperty("resources").EnumerateArray().Select(r => new ResourceModel(
            r.GetProperty("id").GetInt32(),
            $"Resource {r.GetProperty("id").GetInt32()}",
            ResourceOperations.ReadWrite,
            r.TryGetProperty("instances", out _),
            false,
            Type(r.GetProperty("type").GetString()!)));
        var objectId = spec.GetProperty("object_id").GetInt32();
        return ObjectRegistry.From([new ObjectModel(objectId, $"Object {objectId}", true, false, resources)]);
    }

    private static IEnumerable<(string Name, Lwm2mValue Value, int Resource, int? Instance)> Values(JsonElement spec)
    {
        foreach (var r in spec.GetProperty("resources").EnumerateArray())
        {
            var type = Type(r.GetProperty("type").GetString()!);
            var id = r.GetProperty("id").GetInt32();
            if (r.TryGetProperty("instances", out var instances))
            {
                foreach (var instance in instances.EnumerateObject().OrderBy(i => int.Parse(i.Name, System.Globalization.CultureInfo.InvariantCulture)))
                {
                    yield return ($"/{id}/{instance.Name}", Value(type, instance.Value), id, int.Parse(instance.Name, System.Globalization.CultureInfo.InvariantCulture));
                }
            }
            else
            {
                yield return ($"/{id}", Value(type, r.GetProperty("value")), id, null);
            }
        }
    }

    private static SenmlPack Pack(JsonElement spec)
    {
        var path = PathOf(spec);
        var prefix = $"/{spec.GetProperty("object_id").GetInt32()}/{path.ObjectInstanceId ?? 0}";
        return new SenmlPack(Values(spec).Select(v => RecordFor(v.Value) with { Name = prefix + v.Name }));
    }

    private static Lwm2mNode Node(JsonElement spec)
    {
        var path = PathOf(spec);
        var resources = Values(spec)
            .GroupBy(v => v.Resource)
            .Select(g => g.First().Instance is null
                ? (Lwm2mResource)new Lwm2mSingleResource(g.Key, g.First().Value)
                : new Lwm2mMultipleResource(g.Key, g.First().Value.Type, g.Select(v => new Lwm2mResourceInstance(v.Instance!.Value, v.Value))))
            .ToList();

        return path.Depth switch
        {
            1 => new Lwm2mObject(path.ObjectId, new Lwm2mObjectInstance(0, resources)),
            2 => new Lwm2mObjectInstance(path.ObjectInstanceId!.Value, resources),
            _ => resources.Single(),
        };
    }

    private static SenmlRecord RecordFor(Lwm2mValue value) => value.Type switch
    {
        Lwm2mType.String => new SenmlRecord { StringValue = value.AsString() },
        Lwm2mType.CoreLink => new SenmlRecord { StringValue = value.AsCoreLink() },
        Lwm2mType.Opaque => new SenmlRecord { OpaqueValue = value.AsOpaque() },
        Lwm2mType.Boolean => new SenmlRecord { BooleanValue = value.AsBoolean() },
        Lwm2mType.ObjectLink => new SenmlRecord { ObjectLinkValue = value.AsObjectLink().ToString() },
        Lwm2mType.Float => new SenmlRecord { NumberValue = SenmlNumber.FromFloat(value.AsFloat()) },
        Lwm2mType.Integer => new SenmlRecord { NumberValue = value.AsInteger() },
        Lwm2mType.Time => new SenmlRecord { NumberValue = value.AsTime() },
        _ => new SenmlRecord { NumberValue = value.AsUnsignedInteger() },
    };

    private static Lwm2mValue Value(Lwm2mType type, JsonElement v) => type switch
    {
        Lwm2mType.String => Lwm2mValue.FromString(v.GetString()!),
        Lwm2mType.CoreLink => Lwm2mValue.FromCoreLink(v.GetString()!),
        Lwm2mType.Opaque => Lwm2mValue.FromOpaque(Convert.FromHexString(v.GetString()!)),
        Lwm2mType.Boolean => Lwm2mValue.FromBoolean(v.GetBoolean()),
        Lwm2mType.ObjectLink => Lwm2mValue.FromObjectLink(ObjectLink.Parse(v.GetString()!)),
        Lwm2mType.Float => Lwm2mValue.FromFloat(v.GetDouble()),
        Lwm2mType.Integer => Lwm2mValue.FromInteger(v.GetInt64()),
        Lwm2mType.Time => Lwm2mValue.FromTime(v.GetInt64()),
        _ => Lwm2mValue.FromUnsignedInteger(v.GetUInt64()),
    };

    private static Lwm2mType Type(string name) => name switch
    {
        "STRING" => Lwm2mType.String,
        "INTEGER" => Lwm2mType.Integer,
        "UNSIGNED_INTEGER" => Lwm2mType.UnsignedInteger,
        "FLOAT" => Lwm2mType.Float,
        "BOOLEAN" => Lwm2mType.Boolean,
        "OPAQUE" => Lwm2mType.Opaque,
        "TIME" => Lwm2mType.Time,
        "OBJLNK" => Lwm2mType.ObjectLink,
        "CORELINK" => Lwm2mType.CoreLink,
        _ => throw new ArgumentException(name),
    };

    // Name and value only: record order is the encoder's business and already covered by the bytes.
    private static List<string> Flatten(SenmlPack pack) =>
        pack.Records.Select(r => $"{r.Name}={r.ValueKind}:{r.NumberValue}{r.StringValue}{r.BooleanValue}{r.ObjectLinkValue}{(r.OpaqueValue is { } o ? Hex.Of(o) : string.Empty)}")
            .Order(StringComparer.Ordinal)
            .ToList();
}

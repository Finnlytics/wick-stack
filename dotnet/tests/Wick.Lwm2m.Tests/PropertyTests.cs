using System.Globalization;
using System.Text;
using Wick.Lwm2m.Attributes;
using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.Codecs.Internal;
using Wick.Lwm2m.Links;
using Wick.Lwm2m.Model;
using Wick.Lwm2m.Senml;
using Wick.Lwm2m.Tests.Support;

namespace Wick.Lwm2m.Tests;

// Round-trip properties over generated inputs. Each run uses fixed seeds so failures reproduce;
// the seed is in the assertion message.
public sealed class PropertyTests
{
    private const int Runs = 300;

    private static readonly Lwm2mType[] ValueTypes =
    [
        Lwm2mType.String, Lwm2mType.Integer, Lwm2mType.UnsignedInteger, Lwm2mType.Float, Lwm2mType.Boolean,
        Lwm2mType.Opaque, Lwm2mType.Time, Lwm2mType.ObjectLink, Lwm2mType.CoreLink,
    ];

    private static void ForAll(Action<Random, int> property)
    {
        for (int seed = 0; seed < Runs; seed++)
        {
            try
            {
                property(new Random(seed), seed);
            }
            catch (Exception e) when (e is not Xunit.Sdk.XunitException)
            {
                throw new Xunit.Sdk.XunitException($"seed {seed}: {e}");
            }
        }
    }

    [Fact]
    public void Paths_survive_format_and_parse()
    {
        ForAll((random, seed) =>
        {
            var path = Gen.Path(random);

            Assert.Equal(path, Lwm2mPath.Parse(path.ToString()));
            Assert.Equal(path, Lwm2mPath.FromSegments(path.ToSegments()));
        });
    }

    [Fact]
    public void Senml_packs_survive_json_and_cbor()
    {
        ForAll((random, seed) =>
        {
            var pack = Gen.Pack(random);

            Assert.True(pack.Equals(SenmlJsonCodec.Decode(SenmlJsonCodec.Encode(pack, allowNoValue: true))), $"JSON, seed {seed}");
            Assert.True(pack.Equals(SenmlCborCodec.Decode(SenmlCborCodec.Encode(pack, allowNoValue: true))), $"CBOR, seed {seed}");
        });
    }

    [Fact]
    public void Typed_nodes_survive_every_multi_value_format_with_a_model()
    {
        ForAll((random, seed) =>
        {
            // SenML has no way to say "an Instance with no Resources", so every generated Instance has at least one.
            var (model, node) = Gen.ObjectWithModel(random);
            var registry = ObjectRegistry.From([model]);
            var path = new Lwm2mPath(node.Id);

            foreach (var format in new[] { ContentFormats.SenmlJson, ContentFormats.SenmlCbor, ContentFormats.Tlv })
            {
                var bytes = Lwm2mNodeCodec.Encode(node, path, format, registry);
                var back = Lwm2mNodeCodec.Decode(bytes, format, path, registry);
                Assert.True(node.Equals(back), $"format {format}, seed {seed}: {node} became {back}");
            }
        });
    }

    [Fact]
    public void Single_values_survive_every_format_that_carries_them()
    {
        ForAll((random, seed) =>
        {
            var type = ValueTypes[random.Next(ValueTypes.Length)];
            var value = Gen.Value(random, type);
            var model = ObjectRegistry.From([new ObjectModel(9, "Nine", true, false, [new ResourceModel(1, "R", ResourceOperations.ReadWrite, false, false, type)])]);
            var path = Lwm2mPath.Parse("/9/0/1");
            var node = new Lwm2mSingleResource(1, value);

            var formats = new List<int> { ContentFormats.PlainText, ContentFormats.SenmlJson, ContentFormats.SenmlCbor, ContentFormats.Tlv };
            if (type == Lwm2mType.Opaque)
            {
                formats.Add(ContentFormats.Opaque);
            }

            foreach (var format in formats)
            {
                var back = Lwm2mNodeCodec.Decode(Lwm2mNodeCodec.Encode(node, path, format, model), format, path, model);
                Assert.True(node.Equals(back), $"format {format}, seed {seed}: {node} became {back}");
            }
        });
    }

    [Fact]
    public void Tlv_entry_trees_survive_encode_and_decode()
    {
        ForAll((random, seed) =>
        {
            var entries = Enumerable.Range(0, random.Next(0, 4)).Select(_ => Gen.TlvEntry(random, 0)).ToList();
            var bytes = Tlv.Encode(entries);

            Assert.Equal(Hex.Of(bytes), Hex.Of(Tlv.Encode(Tlv.Decode(bytes))));
        });
    }

    [Fact]
    public void Tlv_integers_survive_at_every_width()
    {
        ForAll((random, seed) =>
        {
            long value = random.Next(4) switch
            {
                0 => random.Next(-200, 200),
                1 => random.Next(),
                2 => -random.NextInt64(),
                _ => random.NextInt64(long.MinValue, long.MaxValue),
            };

            Assert.Equal(value, Tlv.DecodeInteger(Tlv.EncodeInteger(value)));
            if (value >= 0)
            {
                Assert.Equal((ulong)value, Tlv.DecodeUnsignedInteger(Tlv.EncodeUnsignedInteger((ulong)value)));
            }
        });
    }

    [Fact]
    public void Cbor_floats_survive_bit_for_bit()
    {
        ForAll((random, seed) =>
        {
            var value = Gen.Double(random);
            var writer = new CborWriter();
            writer.WriteFloat(value);

            var back = Assert.IsType<SenmlNumber>(CborReader.Decode(writer.ToArray()));
            Assert.Equal(BitConverter.DoubleToInt64Bits(value), BitConverter.DoubleToInt64Bits(back.AsDouble));
        });
    }

    [Fact]
    public void Java_double_text_parses_back_to_the_same_double()
    {
        ForAll((random, seed) =>
        {
            var value = Gen.Double(random);
            var text = JavaDouble.Format(value);

            Assert.Equal(value, double.Parse(text, NumberStyles.Float, CultureInfo.InvariantCulture));
            Assert.True(text.Contains('.', StringComparison.Ordinal), text);
        });
    }

    [Fact]
    public void Link_documents_survive_format_and_parse()
    {
        ForAll((random, seed) =>
        {
            var links = Enumerable.Range(0, random.Next(1, 5)).Select(_ => Gen.Link(random)).ToList();
            var text = CoreLinkFormat.Format(links);

            Assert.Equal(links, CoreLinkFormat.Parse(text));
        });
    }

    [Fact]
    public void Attribute_sets_survive_the_query_form()
    {
        ForAll((random, seed) =>
        {
            var attributes = new NotificationAttributes
            {
                Pmin = Gen.Attribute(random, () => (long)random.Next(0, 100000)),
                Pmax = Gen.Attribute(random, () => (long)random.Next(0, 100000)),
                Epmin = Gen.Attribute(random, () => (long)random.Next(0, 100)),
                Epmax = Gen.Attribute(random, () => (long)random.Next(0, 100)),
                Gt = Gen.Attribute(random, () => Gen.Decimal(random)),
                Lt = Gen.Attribute(random, () => Gen.Decimal(random)),
                St = Gen.Attribute(random, () => Math.Abs(Gen.Decimal(random))),
            };

            Assert.Equal(attributes, NotificationAttributes.FromQuery(attributes.ToQuery()));
        });
    }

    [Fact]
    public void Plain_text_survives_for_every_type()
    {
        ForAll((random, seed) =>
        {
            var type = ValueTypes[random.Next(ValueTypes.Length)];
            var value = Gen.Value(random, type);

            Assert.Equal(value, PlainTextCodec.Decode(PlainTextCodec.Encode(value), type));
        });
    }

    private static class Gen
    {
        private const string Alphabet = "abcXYZ019 /:;,.=<>\"'\\é€\u0001\n\t{}[]";

        public static Lwm2mPath Path(Random r) => r.Next(4) switch
        {
            0 => new Lwm2mPath(Id(r)),
            1 => new Lwm2mPath(Id(r), Id(r)),
            2 => new Lwm2mPath(Id(r), Id(r), Id(r)),
            _ => new Lwm2mPath(Id(r), Id(r), Id(r), Id(r)),
        };

        public static int Id(Random r) => r.Next(3) == 0 ? r.Next(0, 65536) : r.Next(0, 300);

        public static string Text(Random r, int max = 12)
        {
            var builder = new StringBuilder();
            for (int i = r.Next(0, max); i > 0; i--)
            {
                builder.Append(Alphabet[r.Next(Alphabet.Length)]);
            }

            return builder.ToString();
        }

        public static byte[] Bytes(Random r)
        {
            var bytes = new byte[r.Next(0, 20)];
            r.NextBytes(bytes);
            return bytes;
        }

        public static double Double(Random r) => r.Next(6) switch
        {
            0 => r.Next(-1000, 1000) / 4.0,
            1 => (r.NextDouble() - 0.5) * Math.Pow(10, r.Next(-30, 30)),
            2 => BitConverter.Int64BitsToDouble(r.NextInt64()) is var d && double.IsFinite(d) ? d : 1.0,
            3 => (float)(r.NextDouble() * 1000),
            4 => r.Next(-100, 100),
            _ => r.NextDouble(),
        };

        public static decimal Decimal(Random r) => Math.Round((decimal)(r.NextDouble() - 0.5) * r.Next(1, 100000), r.Next(0, 6));

        public static SenmlNumber Number(Random r) => r.Next(4) switch
        {
            0 => SenmlNumber.FromFloat(Double(r)),
            1 => (SenmlNumber)r.NextInt64(long.MinValue, long.MaxValue),
            2 => (SenmlNumber)(ulong.MaxValue - (ulong)r.Next(0, 1000)),
            _ => (SenmlNumber)r.Next(-30, 30),
        };

        public static SenmlPack Pack(Random r) => new(Enumerable.Range(0, r.Next(0, 6)).Select(_ =>
        {
            var record = new SenmlRecord
            {
                BaseName = r.Next(3) == 0 ? Text(r) + "x" : null,
                BaseTime = r.Next(4) == 0 ? Number(r) : null,
                Name = r.Next(4) != 0 ? Text(r) + "n" : null,
                Time = r.Next(4) == 0 ? Number(r) : null,
            };

            return r.Next(6) switch
            {
                0 => record with { NumberValue = Number(r) },
                1 => record with { StringValue = Text(r) },
                2 => record with { BooleanValue = r.Next(2) == 0 },
                3 => record with { OpaqueValue = Bytes(r) },
                4 => record with { ObjectLinkValue = $"{r.Next(65536)}:{r.Next(65536)}" },
                _ => record,
            };
        }));

        public static Lwm2mValue Value(Random r, Lwm2mType type) => type switch
        {
            Lwm2mType.String => Lwm2mValue.FromString(Text(r)),
            Lwm2mType.Integer => Lwm2mValue.FromInteger(r.Next(2) == 0 ? r.Next(-300, 300) : r.NextInt64(long.MinValue, long.MaxValue)),
            Lwm2mType.UnsignedInteger => Lwm2mValue.FromUnsignedInteger(r.Next(2) == 0 ? (ulong)r.Next(0, 300) : (ulong)r.NextInt64() * 2 + 1),
            Lwm2mType.Float => Lwm2mValue.FromFloat(Double(r)),
            Lwm2mType.Boolean => Lwm2mValue.FromBoolean(r.Next(2) == 0),
            Lwm2mType.Opaque => Lwm2mValue.FromOpaque(Bytes(r)),
            Lwm2mType.Time => Lwm2mValue.FromTime(r.NextInt64(0, 4_000_000_000)),
            Lwm2mType.ObjectLink => Lwm2mValue.FromObjectLink(new ObjectLink((ushort)r.Next(65536), (ushort)r.Next(65536))),
            _ => Lwm2mValue.FromCoreLink($"</{r.Next(100)}/{r.Next(10)}>"),
        };

        public static (ObjectModel Model, Lwm2mObject Node) ObjectWithModel(Random r)
        {
            int objectId = r.Next(0, 40000);
            var resources = Enumerable.Range(0, r.Next(1, 8))
                .Select(_ => r.Next(0, 70000 % 65536))
                .Distinct()
                .Select(id => new ResourceModel(id, $"R{id}", ResourceOperations.ReadWrite, r.Next(3) == 0, false, ValueTypes[r.Next(ValueTypes.Length)]))
                .ToList();
            var model = new ObjectModel(objectId, "Generated", true, false, resources);

            var instances = Enumerable.Range(0, r.Next(1, 4)).Select(_ => Id(r)).Distinct().Select(instanceId =>
                new Lwm2mObjectInstance(instanceId, resources.Where((_, index) => index == 0 || r.Next(4) != 0).Select(resource => resource.Multiple
                    ? (Lwm2mResource)new Lwm2mMultipleResource(resource.Id, resource.Type, Enumerable.Range(0, r.Next(1, 4)).Select(_ => Id(r)).Distinct()
                        .Select(i => new Lwm2mResourceInstance(i, Value(r, resource.Type))))
                    : new Lwm2mSingleResource(resource.Id, Value(r, resource.Type)))));

            return (model, new Lwm2mObject(objectId, instances));
        }

        public static TlvEntry TlvEntry(Random r, int depth)
        {
            if (depth < 2 && r.Next(3) == 0)
            {
                var type = r.Next(2) == 0 ? TlvEntryType.ObjectInstance : TlvEntryType.MultipleResource;
                return Wick.Lwm2m.Codecs.TlvEntry.WithChildren(type, Id(r), Enumerable.Range(0, r.Next(0, 4)).Select(_ => TlvEntry(r, depth + 1)));
            }

            var bytes = new byte[r.Next(4) == 0 ? r.Next(250, 70000) : r.Next(0, 12)];
            r.NextBytes(bytes);
            return Wick.Lwm2m.Codecs.TlvEntry.WithValue(r.Next(2) == 0 ? TlvEntryType.Resource : TlvEntryType.ResourceInstance, Id(r), bytes);
        }

        public static Link Link(Random r)
        {
            var target = string.Join(string.Empty, Enumerable.Range(0, r.Next(1, 4)).Select(_ => "/" + r.Next(0, 70000)));
            var names = new[] { "rt", "ct", "ver", "pmin", "gt", "obs", "title", "x-ext" };
            var parameters = Enumerable.Range(0, r.Next(0, 4)).Select(_ =>
            {
                var name = names[r.Next(names.Length)];
                return r.Next(4) switch
                {
                    0 => LinkParam.Of(name, null),
                    1 => LinkParam.Of(name, r.Next(0, 100000).ToString(CultureInfo.InvariantCulture)),
                    2 => new LinkParam(name, Text(r), true),
                    _ => LinkParam.Of(name, Text(r)),
                };
            });

            return new Link(target, parameters.Where(p => p.Value is null || p.Quoted || p.Value.Length > 0));
        }

        public static AttributeValue<T> Attribute<T>(Random r, Func<T> value)
            where T : struct => r.Next(3) switch
            {
                0 => AttributeValue<T>.Absent,
                1 => AttributeValue<T>.Cleared,
                _ => value(),
            };
    }
}

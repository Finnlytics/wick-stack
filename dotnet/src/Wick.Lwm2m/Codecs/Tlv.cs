using System.Buffers.Binary;
using System.Collections.Immutable;
using System.Text;
using Wick.Lwm2m.Model;
using Wick.Lwm2m.Senml;

namespace Wick.Lwm2m.Codecs;

/// <summary>The kind of a TLV entry, from bits 7 and 6 of its type byte.</summary>
public enum TlvEntryType
{
    /// <summary>An Object Instance; its children are Resources.</summary>
    ObjectInstance = 0b00,

    /// <summary>One instance of a multiple-instance Resource; it carries a value.</summary>
    ResourceInstance = 0b01,

    /// <summary>A multiple-instance Resource; its children are Resource Instances.</summary>
    MultipleResource = 0b10,

    /// <summary>A single-instance Resource; it carries a value.</summary>
    Resource = 0b11,
}

/// <summary>
/// One TLV entry (OMA LwM2M 1.2 §7.4.3): a type, an identifier, and either a value or children.
/// </summary>
/// <remarks>Object Instance and multiple Resource entries carry children; the other two carry a value.</remarks>
public sealed class TlvEntry
{
    private TlvEntry(TlvEntryType type, int id, byte[]? value, ImmutableArray<TlvEntry> children)
    {
        if (id is < 0 or > ushort.MaxValue)
        {
            throw new ArgumentOutOfRangeException(nameof(id), id, "a TLV identifier is 0 to 65535");
        }

        Type = type;
        Id = id;
        _value = value;
        Children = children;
    }

    private readonly byte[]? _value;

    /// <summary>The entry type.</summary>
    public TlvEntryType Type { get; }

    /// <summary>The identifier: an Object Instance, Resource or Resource Instance ID.</summary>
    public int Id { get; }

    /// <summary>The value bytes of a Resource or Resource Instance entry; empty for container entries.</summary>
    public ReadOnlyMemory<byte> Value => _value ?? ReadOnlyMemory<byte>.Empty;

    /// <summary>The children of an Object Instance or multiple Resource entry; empty otherwise.</summary>
    public ImmutableArray<TlvEntry> Children { get; }

    /// <summary>True for entries that carry children rather than a value.</summary>
    public bool IsContainer => Type is TlvEntryType.ObjectInstance or TlvEntryType.MultipleResource;

    /// <summary>Creates a value entry.</summary>
    /// <param name="type"><see cref="TlvEntryType.Resource"/> or <see cref="TlvEntryType.ResourceInstance"/>.</param>
    /// <param name="id">The identifier.</param>
    /// <param name="value">The value bytes, copied.</param>
    /// <returns>The entry.</returns>
    public static TlvEntry WithValue(TlvEntryType type, int id, ReadOnlySpan<byte> value) =>
        type is TlvEntryType.Resource or TlvEntryType.ResourceInstance
            ? new TlvEntry(type, id, value.ToArray(), [])
            : throw new ArgumentException($"{type} entries carry children, not a value", nameof(type));

    /// <summary>Creates a container entry.</summary>
    /// <param name="type"><see cref="TlvEntryType.ObjectInstance"/> or <see cref="TlvEntryType.MultipleResource"/>.</param>
    /// <param name="id">The identifier.</param>
    /// <param name="children">The child entries.</param>
    /// <returns>The entry.</returns>
    public static TlvEntry WithChildren(TlvEntryType type, int id, IEnumerable<TlvEntry> children) =>
        type is TlvEntryType.ObjectInstance or TlvEntryType.MultipleResource
            ? new TlvEntry(type, id, null, children.ToImmutableArray())
            : throw new ArgumentException($"{type} entries carry a value, not children", nameof(type));
}

/// <summary>
/// The TLV byte format on its own: entry structure and the per-type value encodings, with no LwM2M
/// path or model semantics. <see cref="TlvCodec"/> builds on it.
/// </summary>
/// <remarks>
/// Each entry is a type byte, an 8 or 16-bit identifier, an optional 8, 16 or 24-bit length and
/// the value. Lengths under 8 ride in the type byte itself. Integers use the shortest signed
/// big-endian width of 1, 2, 4 or 8 bytes; floats are written as 8-byte doubles and read in either
/// 4 or 8 bytes, which matches Eclipse Leshan.
/// </remarks>
public static class Tlv
{
    private const int MaxDepth = 4;

    /// <summary>Encodes entries to bytes.</summary>
    /// <param name="entries">The entries.</param>
    /// <returns>The TLV bytes.</returns>
    public static byte[] Encode(IEnumerable<TlvEntry> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        var output = new MemoryStream();
        foreach (var entry in entries)
        {
            WriteEntry(output, entry);
        }

        return output.ToArray();
    }

    /// <summary>Decodes bytes into entries.</summary>
    /// <param name="payload">The TLV bytes.</param>
    /// <returns>The entries.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.MalformedTlv"/> when the input is truncated or inconsistent.</exception>
    public static IReadOnlyList<TlvEntry> Decode(ReadOnlySpan<byte> payload) => DecodeEntries(payload, 0);

    /// <summary>Encodes an integer in the shortest signed big-endian form: 1, 2, 4 or 8 bytes.</summary>
    /// <param name="value">The integer.</param>
    /// <returns>The bytes.</returns>
    public static byte[] EncodeInteger(long value)
    {
        if (value is >= sbyte.MinValue and <= sbyte.MaxValue)
        {
            return [(byte)(sbyte)value];
        }

        if (value is >= short.MinValue and <= short.MaxValue)
        {
            var two = new byte[2];
            BinaryPrimitives.WriteInt16BigEndian(two, (short)value);
            return two;
        }

        if (value is >= int.MinValue and <= int.MaxValue)
        {
            var four = new byte[4];
            BinaryPrimitives.WriteInt32BigEndian(four, (int)value);
            return four;
        }

        var eight = new byte[8];
        BinaryPrimitives.WriteInt64BigEndian(eight, value);
        return eight;
    }

    /// <summary>
    /// Encodes an unsigned integer. Values up to <see cref="long.MaxValue"/> use the signed
    /// encoding, so 200 takes two bytes; larger values use all 8 bytes unsigned.
    /// </summary>
    /// <param name="value">The unsigned integer.</param>
    /// <returns>The bytes.</returns>
    public static byte[] EncodeUnsignedInteger(ulong value)
    {
        if (value <= long.MaxValue)
        {
            return EncodeInteger((long)value);
        }

        var eight = new byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(eight, value);
        return eight;
    }

    /// <summary>Decodes a signed big-endian integer of 1 to 8 bytes. Peers send 3, 5, 6 and 7-byte forms too, so all are read.</summary>
    /// <param name="value">The bytes.</param>
    /// <returns>The integer.</returns>
    /// <exception cref="Lwm2mException">The value is empty or longer than 8 bytes.</exception>
    public static long DecodeInteger(ReadOnlySpan<byte> value)
    {
        if (value.Length is < 1 or > 8)
        {
            throw Malformed($"invalid length for an integer: {value.Length} bytes");
        }

        long result = (sbyte)value[0];
        for (int i = 1; i < value.Length; i++)
        {
            result = (result << 8) | value[i];
        }

        return result;
    }

    /// <summary>
    /// Decodes an unsigned big-endian integer of 1 to 8 bytes. The bytes are read as an unsigned
    /// magnitude, so <c>C8</c> is 200 even though it would be -56 as a signed integer.
    /// </summary>
    /// <param name="value">The bytes.</param>
    /// <returns>The unsigned integer.</returns>
    /// <exception cref="Lwm2mException">The value is empty or longer than 8 bytes.</exception>
    public static ulong DecodeUnsignedInteger(ReadOnlySpan<byte> value)
    {
        if (value.Length is < 1 or > 8)
        {
            throw Malformed($"invalid length for an unsigned integer: {value.Length} bytes");
        }

        ulong result = 0;
        foreach (var b in value)
        {
            result = (result << 8) | b;
        }

        return result;
    }

    /// <summary>Encodes a float as an 8-byte IEEE 754 double.</summary>
    /// <param name="value">The float.</param>
    /// <returns>The bytes.</returns>
    public static byte[] EncodeFloat(double value)
    {
        var bytes = new byte[8];
        BinaryPrimitives.WriteDoubleBigEndian(bytes, value);
        return bytes;
    }

    /// <summary>Decodes a 4 or 8-byte IEEE 754 float.</summary>
    /// <param name="value">The bytes.</param>
    /// <returns>The float.</returns>
    /// <exception cref="Lwm2mException">The length is not 4 or 8.</exception>
    public static double DecodeFloat(ReadOnlySpan<byte> value) => value.Length switch
    {
        4 => BinaryPrimitives.ReadSingleBigEndian(value),
        8 => BinaryPrimitives.ReadDoubleBigEndian(value),
        _ => throw Malformed($"invalid length for a float: {value.Length} bytes"),
    };

    /// <summary>Encodes a boolean as one byte, 0 or 1.</summary>
    /// <param name="value">The boolean.</param>
    /// <returns>The bytes.</returns>
    public static byte[] EncodeBoolean(bool value) => [value ? (byte)1 : (byte)0];

    /// <summary>Decodes a one-byte boolean. Any non-zero byte reads as true.</summary>
    /// <param name="value">The bytes.</param>
    /// <returns>The boolean.</returns>
    /// <exception cref="Lwm2mException">The length is not 1.</exception>
    public static bool DecodeBoolean(ReadOnlySpan<byte> value) => value.Length == 1
        ? value[0] != 0
        : throw Malformed($"invalid length for a boolean: {value.Length} bytes");

    /// <summary>Encodes an Object Link as two 16-bit big-endian identifiers.</summary>
    /// <param name="value">The link.</param>
    /// <returns>The bytes.</returns>
    public static byte[] EncodeObjectLink(ObjectLink value)
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteUInt16BigEndian(bytes, value.ObjectId);
        BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(2), value.ObjectInstanceId);
        return bytes;
    }

    /// <summary>Decodes a 4-byte Object Link.</summary>
    /// <param name="value">The bytes.</param>
    /// <returns>The link.</returns>
    /// <exception cref="Lwm2mException">The length is not 4.</exception>
    public static ObjectLink DecodeObjectLink(ReadOnlySpan<byte> value) => value.Length == 4
        ? new ObjectLink(BinaryPrimitives.ReadUInt16BigEndian(value), BinaryPrimitives.ReadUInt16BigEndian(value[2..]))
        : throw Malformed($"invalid length for an Object Link: {value.Length} bytes");

    private static void WriteEntry(MemoryStream output, TlvEntry entry)
    {
        var body = entry.IsContainer ? Encode(entry.Children) : entry.Value.ToArray();
        var length = body.Length;
        if (length > 0xFFFFFF)
        {
            throw new Lwm2mException(Lwm2mErrorCode.UnencodableValue, $"a TLV value of {length} bytes exceeds the 24-bit length limit");
        }

        int type = (int)entry.Type << 6;
        if (entry.Id > byte.MaxValue)
        {
            type |= 0b0010_0000;
        }

        if (length < 8)
        {
            type |= length;
        }
        else if (length <= byte.MaxValue)
        {
            type |= 0b0000_1000;
        }
        else if (length <= ushort.MaxValue)
        {
            type |= 0b0001_0000;
        }
        else
        {
            type |= 0b0001_1000;
        }

        output.WriteByte((byte)type);
        if (entry.Id > byte.MaxValue)
        {
            output.WriteByte((byte)(entry.Id >> 8));
        }

        output.WriteByte((byte)entry.Id);
        if (length >= 8)
        {
            if (length > ushort.MaxValue)
            {
                output.WriteByte((byte)(length >> 16));
            }

            if (length > byte.MaxValue)
            {
                output.WriteByte((byte)(length >> 8));
            }

            output.WriteByte((byte)length);
        }

        output.Write(body);
    }

    private static List<TlvEntry> DecodeEntries(ReadOnlySpan<byte> input, int depth)
    {
        if (depth > MaxDepth)
        {
            throw Malformed("TLV nesting is deeper than LwM2M allows");
        }

        var entries = new List<TlvEntry>();
        int offset = 0;
        while (offset < input.Length)
        {
            int typeByte = input[offset++];
            var type = (TlvEntryType)(typeByte >> 6);
            bool wideId = (typeByte & 0b0010_0000) != 0;
            int lengthForm = (typeByte >> 3) & 0b11;

            int idBytes = wideId ? 2 : 1;
            if (input.Length - offset < idBytes)
            {
                throw Malformed("truncated identifier");
            }

            int id = wideId ? BinaryPrimitives.ReadUInt16BigEndian(input[offset..]) : input[offset];
            offset += idBytes;

            int length;
            if (lengthForm == 0)
            {
                length = typeByte & 0b111;
            }
            else
            {
                if (input.Length - offset < lengthForm)
                {
                    throw Malformed("truncated length field");
                }

                length = 0;
                for (int i = 0; i < lengthForm; i++)
                {
                    length = (length << 8) | input[offset++];
                }
            }

            if (input.Length - offset < length)
            {
                throw Malformed($"declared length {length} exceeds the {input.Length - offset} bytes remaining");
            }

            var body = input.Slice(offset, length);
            offset += length;
            entries.Add(type is TlvEntryType.Resource or TlvEntryType.ResourceInstance
                ? TlvEntry.WithValue(type, id, body)
                : TlvEntry.WithChildren(type, id, DecodeEntries(body, depth + 1)));
        }

        return entries;
    }

    internal static Lwm2mException Malformed(string message) => new(Lwm2mErrorCode.MalformedTlv, message);
}

/// <summary>
/// TLV, Content-Format 11542, mapped to and from a <see cref="SenmlPack"/> with absolute record names.
/// </summary>
/// <remarks>
/// <para>
/// TLV carries no names, so a payload means something only relative to the request path, and
/// both directions need it. The path depth decides the top-level entries: one Object Instance
/// entry per Instance for an Object path, Resources directly for an Object Instance path, one
/// Resource or multiple Resource entry for a Resource path, and one Resource Instance entry for a
/// Resource Instance path.
/// </para>
/// <para>
/// TLV values are bare bytes, so both directions consult the model. Without one, encoding falls
/// back to the record's own shape (an integral number as an Integer, a fractional one as a
/// Float), and decoding falls back to Opaque, because guessing between Integer and Float from the
/// length alone would return a plausible wrong number.
/// </para>
/// </remarks>
public static class TlvCodec
{
    /// <summary>The CoAP Content-Format number for TLV.</summary>
    public const int ContentFormat = ContentFormats.Tlv;

    /// <summary>Encodes a pack as TLV relative to <paramref name="path"/>.</summary>
    /// <param name="pack">The pack. Record names must resolve to paths at or below <paramref name="path"/>.</param>
    /// <param name="path">The request path.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The TLV bytes.</returns>
    /// <exception cref="Lwm2mException">A record name is not a path under <paramref name="path"/>, or a value cannot be encoded as its type.</exception>
    public static byte[] Encode(SenmlPack pack, Lwm2mPath path, ILwm2mModel? model = null)
    {
        ArgumentNullException.ThrowIfNull(pack);
        ArgumentNullException.ThrowIfNull(path);
        var entries = pack.Resolve().Select(r =>
        {
            var recordPath = Lwm2mPath.Parse(r.Name);
            if (!path.Contains(recordPath) || recordPath.ResourceId is null)
            {
                throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, $"record {r.Name} is not a Resource under {path}");
            }

            return (Path: recordPath, r.Record);
        }).ToList();

        return Tlv.Encode(Build(entries, path, model));
    }

    /// <summary>Decodes TLV relative to <paramref name="path"/> into a pack with absolute record names.</summary>
    /// <param name="payload">The TLV bytes.</param>
    /// <param name="path">The request path.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The pack.</returns>
    /// <exception cref="Lwm2mException">The payload is malformed or a value's length does not fit its declared type.</exception>
    public static SenmlPack Decode(ReadOnlySpan<byte> payload, Lwm2mPath path, ILwm2mModel? model = null)
    {
        ArgumentNullException.ThrowIfNull(path);
        var records = new List<SenmlRecord>();
        foreach (var entry in Tlv.Decode(payload))
        {
            Expand(entry, path, model, records);
        }

        return new SenmlPack(records);
    }

    private static IEnumerable<TlvEntry> Build(List<(Lwm2mPath Path, SenmlRecord Record)> entries, Lwm2mPath path, ILwm2mModel? model)
    {
        if (path.IsObject)
        {
            return entries
                .GroupBy(e => e.Path.ObjectInstanceId!.Value)
                .OrderBy(g => g.Key)
                .Select(g => TlvEntry.WithChildren(TlvEntryType.ObjectInstance, g.Key, ResourceEntries(g, model)))
                .ToList();
        }

        if (path.IsResourceInstance)
        {
            return entries
                .Select(e => TlvEntry.WithValue(TlvEntryType.ResourceInstance, e.Path.ResourceInstanceId!.Value, EncodeValue(e.Record, e.Path, model)))
                .ToList();
        }

        return ResourceEntries(entries, model);
    }

    // A Resource is a multiple Resource exactly when the paths under it name Resource Instances.
    // That is readable from the paths alone, so it needs no model.
    private static List<TlvEntry> ResourceEntries(IEnumerable<(Lwm2mPath Path, SenmlRecord Record)> entries, ILwm2mModel? model) =>
        entries
            .GroupBy(e => e.Path.ResourceId!.Value)
            .OrderBy(g => g.Key)
            .Select(g =>
            {
                var items = g.ToList();
                if (items is [{ Path.ResourceInstanceId: null } single])
                {
                    return TlvEntry.WithValue(TlvEntryType.Resource, g.Key, EncodeValue(single.Record, single.Path, model));
                }

                return TlvEntry.WithChildren(TlvEntryType.MultipleResource, g.Key, items
                    .OrderBy(i => i.Path.ResourceInstanceId ?? 0)
                    .Select(i => TlvEntry.WithValue(TlvEntryType.ResourceInstance, i.Path.ResourceInstanceId ?? 0, EncodeValue(i.Record, i.Path, model))));
            })
            .ToList();

    private static byte[] EncodeValue(SenmlRecord record, Lwm2mPath path, ILwm2mModel? model)
    {
        // An absent value is zero bytes whatever the declared type: that is how an Executable
        // Resource and an unset optional one both appear.
        var declared = model.ResourceType(path);
        return record.ValueKind == SenmlValueKind.None || declared == Lwm2mType.None
            ? []
            : TlvValues.Encode(SenmlValues.ToValue(record, declared, path), path);
    }

    private static void Expand(TlvEntry entry, Lwm2mPath parent, ILwm2mModel? model, List<SenmlRecord> records)
    {
        switch (entry.Type)
        {
            case TlvEntryType.ObjectInstance:
                if (!parent.IsObject)
                {
                    throw Tlv.Malformed($"an Object Instance entry cannot appear under {parent}");
                }

                foreach (var child in entry.Children)
                {
                    Expand(child, parent.Append(entry.Id), model, records);
                }

                break;

            case TlvEntryType.MultipleResource:
            {
                var resourcePath = ResourcePath(parent, entry.Id);
                foreach (var child in entry.Children)
                {
                    if (child.Type != TlvEntryType.ResourceInstance)
                    {
                        throw Tlv.Malformed($"a multiple Resource entry may only contain Resource Instances, found {child.Type}");
                    }

                    Expand(child, resourcePath, model, records);
                }

                break;
            }

            case TlvEntryType.Resource:
                records.Add(ToRecord(entry, ResourcePath(parent, entry.Id), model));
                break;

            default:
                // A Resource Instance sits under a Resource. When the request targeted the Resource,
                // the parent already names it; when it targeted the Instance itself, the ID is the
                // entry's own and must match.
                Lwm2mPath instancePath = parent.Depth switch
                {
                    3 => parent.Append(entry.Id),
                    4 when parent.ResourceInstanceId == entry.Id => parent,
                    _ => throw Tlv.Malformed($"a Resource Instance entry {entry.Id} cannot appear under {parent}"),
                };
                records.Add(ToRecord(entry, instancePath, model));
                break;
        }
    }

    private static Lwm2mPath ResourcePath(Lwm2mPath parent, int id) => parent.Depth switch
    {
        2 => parent.Append(id),
        3 when parent.ResourceId == id => parent,
        _ => throw Tlv.Malformed($"a Resource entry {id} cannot appear under {parent}"),
    };

    private static SenmlRecord ToRecord(TlvEntry entry, Lwm2mPath path, ILwm2mModel? model)
    {
        var type = model.ResourceType(path);
        var value = type is null ? Lwm2mValue.FromOpaque(entry.Value.Span) : TlvValues.Decode(entry.Value.Span, type.Value, path);
        return SenmlValues.ToRecord(value) with { Name = path.ToString() };
    }
}

internal static class TlvValues
{
    public static byte[] Encode(Lwm2mValue value, Lwm2mPath path) => value.Type switch
    {
        Lwm2mType.String => Encoding.UTF8.GetBytes(value.AsString()),
        Lwm2mType.CoreLink => Encoding.UTF8.GetBytes(value.AsCoreLink()),
        Lwm2mType.Opaque => value.AsOpaque().ToArray(),
        Lwm2mType.Integer => Tlv.EncodeInteger(value.AsInteger()),
        Lwm2mType.Time => Tlv.EncodeInteger(value.AsTime()),
        Lwm2mType.UnsignedInteger => Tlv.EncodeUnsignedInteger(value.AsUnsignedInteger()),
        Lwm2mType.Float => Tlv.EncodeFloat(value.AsFloat()),
        Lwm2mType.Boolean => Tlv.EncodeBoolean(value.AsBoolean()),
        Lwm2mType.ObjectLink => Tlv.EncodeObjectLink(value.AsObjectLink()),
        Lwm2mType.None => [],
        _ => throw new Lwm2mException(Lwm2mErrorCode.UnencodableValue, $"{path}: cannot encode {value} as TLV"),
    };

    public static Lwm2mValue Decode(ReadOnlySpan<byte> bytes, Lwm2mType type, Lwm2mPath path)
    {
        try
        {
            return type switch
            {
                Lwm2mType.String => Lwm2mValue.FromString(Utf8(bytes)),
                Lwm2mType.CoreLink => Lwm2mValue.FromCoreLink(Utf8(bytes)),
                Lwm2mType.Opaque => Lwm2mValue.FromOpaque(bytes),
                Lwm2mType.Integer => Lwm2mValue.FromInteger(Tlv.DecodeInteger(bytes)),
                Lwm2mType.Time => Lwm2mValue.FromTime(Tlv.DecodeInteger(bytes)),
                Lwm2mType.UnsignedInteger => Lwm2mValue.FromUnsignedInteger(Tlv.DecodeUnsignedInteger(bytes)),
                Lwm2mType.Float => Lwm2mValue.FromFloat(Tlv.DecodeFloat(bytes)),
                Lwm2mType.Boolean => Lwm2mValue.FromBoolean(Tlv.DecodeBoolean(bytes)),
                Lwm2mType.ObjectLink => Lwm2mValue.FromObjectLink(Tlv.DecodeObjectLink(bytes)),
                _ => bytes.Length == 0 ? Lwm2mValue.None : Lwm2mValue.FromOpaque(bytes),
            };
        }
        catch (Lwm2mException e) when (e.Code == Lwm2mErrorCode.MalformedTlv)
        {
            throw new Lwm2mException(Lwm2mErrorCode.MalformedTlv, $"{path}: {e.Message}", e);
        }
    }

    private static string Utf8(ReadOnlySpan<byte> bytes)
    {
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (DecoderFallbackException e)
        {
            throw new Lwm2mException(Lwm2mErrorCode.MalformedTlv, "a string value is not valid UTF-8", e);
        }
    }
}

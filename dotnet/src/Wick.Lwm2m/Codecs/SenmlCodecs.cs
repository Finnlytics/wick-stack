using System.Text;
using Wick.Lwm2m.Codecs.Internal;
using Wick.Lwm2m.Senml;

namespace Wick.Lwm2m.Codecs;

/// <summary>
/// SenML JSON, Content-Format 110 (RFC 8428 §5 with the LwM2M <c>vlo</c> extension).
/// </summary>
/// <remarks>
/// <para>
/// Fields are written in Eclipse Leshan's order: <c>bn</c>, <c>bt</c>, <c>n</c>, <c>t</c>, then
/// exactly one of <c>v</c>, <c>vs</c>, <c>vb</c>, <c>vd</c> or <c>vlo</c>. JSON leaves key order
/// open, so this is chosen for byte-identical output with Leshan rather than required by the RFC.
/// An empty base name or name is omitted, as Leshan does.
/// </para>
/// <para>
/// Integers are written as plain digits. Floats use Java's <c>Double.toString</c> layout
/// (<c>22.5</c>, <c>30.0</c>, <c>1.0E7</c>), again to match Leshan. Opaque values are standard
/// base64 with padding (RFC 8428 §6).
/// </para>
/// </remarks>
public static class SenmlJsonCodec
{
    /// <summary>The CoAP Content-Format number for SenML JSON.</summary>
    public const int ContentFormat = ContentFormats.SenmlJson;

    /// <summary>Encodes a pack as SenML JSON.</summary>
    /// <param name="pack">The pack.</param>
    /// <param name="allowNoValue">Whether records with no value field are allowed, as in Read-Composite bodies.</param>
    /// <returns>The UTF-8 JSON bytes.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.MissingValue"/> when a record has no value and <paramref name="allowNoValue"/> is false.</exception>
    public static byte[] Encode(SenmlPack pack, bool allowNoValue = false)
    {
        ArgumentNullException.ThrowIfNull(pack);
        SenmlValidation.CheckValues(pack, allowNoValue);
        var builder = new StringBuilder().Append('[');
        for (int i = 0; i < pack.Records.Count; i++)
        {
            if (i > 0)
            {
                builder.Append(',');
            }

            WriteRecord(builder, pack.Records[i]);
        }

        return Encoding.UTF8.GetBytes(builder.Append(']').ToString());
    }

    /// <summary>Decodes SenML JSON into a pack.</summary>
    /// <param name="payload">The UTF-8 JSON bytes.</param>
    /// <returns>The pack.</returns>
    /// <exception cref="Lwm2mException">
    /// <see cref="Lwm2mErrorCode.MalformedJson"/> when the payload is not JSON, or
    /// <see cref="Lwm2mErrorCode.MalformedSenml"/> when it is JSON but not a SenML pack.
    /// </exception>
    public static SenmlPack Decode(ReadOnlySpan<byte> payload)
    {
        if (Json.Parse(payload) is not List<object?> items)
        {
            throw SenmlValidation.Malformed("the top-level JSON value must be an array");
        }

        return new SenmlPack(items.Select(item => item is List<KeyValuePair<object?, object?>> fields
            ? DecodeRecord(fields)
            : throw SenmlValidation.Malformed("each SenML record must be a JSON object")));
    }

    private static SenmlRecord DecodeRecord(List<KeyValuePair<object?, object?>> fields)
    {
        object? Field(string key) => fields.FirstOrDefault(f => (string)f.Key! == key).Value;

        return new SenmlRecord
        {
            BaseName = SenmlValidation.Text(Field("bn"), "bn"),
            BaseTime = SenmlValidation.Number(Field("bt"), "bt"),
            Name = SenmlValidation.Text(Field("n"), "n"),
            Time = SenmlValidation.Number(Field("t"), "t"),
            NumberValue = SenmlValidation.Number(Field("v"), "v"),
            StringValue = SenmlValidation.Text(Field("vs"), "vs"),
            BooleanValue = SenmlValidation.Boolean(Field("vb"), "vb"),
            OpaqueValue = Base64(Field("vd")),
            ObjectLinkValue = SenmlValidation.Text(Field("vlo"), "vlo"),
        };
    }

    private static ReadOnlyMemory<byte>? Base64(object? value)
    {
        if (value is null)
        {
            return null;
        }

        if (value is not string text)
        {
            throw SenmlValidation.Malformed("expected base64 text at key \"vd\"");
        }

        try
        {
            return Convert.FromBase64String(text);
        }
        catch (FormatException e)
        {
            throw new Lwm2mException(Lwm2mErrorCode.MalformedSenml, "invalid base64 in \"vd\"", e);
        }
    }

    private static void WriteRecord(StringBuilder builder, SenmlRecord record)
    {
        builder.Append('{');
        bool first = true;

        void Key(string key)
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            builder.Append('"').Append(key).Append("\":");
        }

        if (!string.IsNullOrEmpty(record.BaseName))
        {
            Key("bn");
            Json.WriteString(builder, record.BaseName);
        }

        if (record.BaseTime is { } baseTime)
        {
            Key("bt");
            Json.WriteNumber(builder, baseTime);
        }

        if (!string.IsNullOrEmpty(record.Name))
        {
            Key("n");
            Json.WriteString(builder, record.Name);
        }

        if (record.Time is { } time)
        {
            Key("t");
            Json.WriteNumber(builder, time);
        }

        switch (record.ValueKind)
        {
            case SenmlValueKind.Number:
                Key("v");
                Json.WriteNumber(builder, record.NumberValue!.Value);
                break;
            case SenmlValueKind.String:
                Key("vs");
                Json.WriteString(builder, record.StringValue!);
                break;
            case SenmlValueKind.Boolean:
                Key("vb");
                builder.Append(record.BooleanValue!.Value ? "true" : "false");
                break;
            case SenmlValueKind.Opaque:
                Key("vd");
                Json.WriteString(builder, Convert.ToBase64String(record.OpaqueValue!.Value.Span));
                break;
            case SenmlValueKind.ObjectLink:
                Key("vlo");
                Json.WriteString(builder, record.ObjectLinkValue!);
                break;
        }

        builder.Append('}');
    }
}

/// <summary>
/// SenML CBOR, Content-Format 112 (RFC 8428 §6 with the LwM2M <c>vlo</c> extension).
/// </summary>
/// <remarks>
/// <para>
/// Each record is a CBOR map using the RFC 8428 integer labels (<c>bn</c> -2, <c>bt</c> -3,
/// <c>n</c> 0, <c>v</c> 2, <c>vs</c> 3, <c>vb</c> 4, <c>t</c> 6, <c>vd</c> 8) and the text key
/// <c>"vlo"</c>. Keys are written in canonical CBOR order (RFC 8949 §4.2.1), which is also the
/// order Eclipse Leshan 2.x emits. Integers use the shortest head; floats use the shortest IEEE
/// 754 width that holds the value exactly.
/// </para>
/// <para>
/// Times (<c>t</c>, <c>bt</c>) are written as plain numbers. Leshan writes them as CBOR tag 4
/// decimal fractions, three bytes longer for the same value; both are valid SenML and the decoder
/// accepts either, so the two interoperate in both directions. This follows the Elixir library's
/// ADR 0003.
/// </para>
/// </remarks>
public static class SenmlCborCodec
{
    /// <summary>The CoAP Content-Format number for SenML CBOR.</summary>
    public const int ContentFormat = ContentFormats.SenmlCbor;

    private enum Field
    {
        BaseName,
        BaseTime,
        Name,
        Time,
        Number,
        String,
        Boolean,
        Opaque,
        ObjectLink,
    }

    private static readonly IReadOnlyDictionary<Field, byte[]> Keys = new Dictionary<Field, byte[]>
    {
        [Field.BaseName] = CborWriter.EncodeKey(-2),
        [Field.BaseTime] = CborWriter.EncodeKey(-3),
        [Field.Name] = CborWriter.EncodeKey(0),
        [Field.Time] = CborWriter.EncodeKey(6),
        [Field.Number] = CborWriter.EncodeKey(2),
        [Field.String] = CborWriter.EncodeKey(3),
        [Field.Boolean] = CborWriter.EncodeKey(4),
        [Field.Opaque] = CborWriter.EncodeKey(8),
        [Field.ObjectLink] = CborWriter.EncodeKey("vlo"),
    };

    /// <summary>Encodes a pack as SenML CBOR.</summary>
    /// <param name="pack">The pack.</param>
    /// <param name="allowNoValue">Whether records with no value field are allowed, as in Read-Composite bodies.</param>
    /// <returns>The CBOR bytes.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.MissingValue"/> when a record has no value and <paramref name="allowNoValue"/> is false.</exception>
    public static byte[] Encode(SenmlPack pack, bool allowNoValue = false)
    {
        ArgumentNullException.ThrowIfNull(pack);
        SenmlValidation.CheckValues(pack, allowNoValue);
        var writer = new CborWriter();
        writer.WriteArrayHead(pack.Records.Count);
        foreach (var record in pack.Records)
        {
            WriteRecord(writer, record);
        }

        return writer.ToArray();
    }

    /// <summary>Decodes SenML CBOR into a pack. Accepts tag 4 decimal fractions for any number.</summary>
    /// <param name="payload">The CBOR bytes.</param>
    /// <returns>The pack.</returns>
    /// <exception cref="Lwm2mException">
    /// <see cref="Lwm2mErrorCode.MalformedCbor"/> when the payload is not CBOR, or
    /// <see cref="Lwm2mErrorCode.MalformedSenml"/> when it is CBOR but not a SenML pack.
    /// </exception>
    public static SenmlPack Decode(ReadOnlySpan<byte> payload)
    {
        if (CborReader.Decode(payload) is not List<object?> items)
        {
            throw SenmlValidation.Malformed("the top-level CBOR value must be an array");
        }

        return new SenmlPack(items.Select(item => item is List<KeyValuePair<object?, object?>> fields
            ? DecodeRecord(fields)
            : throw SenmlValidation.Malformed("each SenML record must be a CBOR map")));
    }

    private static SenmlRecord DecodeRecord(List<KeyValuePair<object?, object?>> fields)
    {
        object? Label(int label) => fields.LastOrDefault(f =>
            f.Key is SenmlNumber number && number.TryGetInt64(out var key) && key == label).Value;

        object? TextKey(string key) => fields.LastOrDefault(f => f.Key is string s && s == key).Value;

        var opaque = Label(8);
        return new SenmlRecord
        {
            BaseName = SenmlValidation.Text(Label(-2), "bn"),
            BaseTime = SenmlValidation.Number(Label(-3), "bt"),
            Name = SenmlValidation.Text(Label(0), "n"),
            Time = SenmlValidation.Number(Label(6), "t"),
            NumberValue = SenmlValidation.Number(Label(2), "v"),
            StringValue = SenmlValidation.Text(Label(3), "vs"),
            BooleanValue = SenmlValidation.Boolean(Label(4), "vb"),
            OpaqueValue = opaque switch
            {
                null => null,
                CborBytes bytes => (ReadOnlyMemory<byte>?)bytes.Value,
                _ => throw SenmlValidation.Malformed("expected a byte string at label 8 (vd)"),
            },
            ObjectLinkValue = SenmlValidation.Text(TextKey("vlo"), "vlo"),
        };
    }

    private static void WriteRecord(CborWriter writer, SenmlRecord record)
    {
        var fields = new List<Field>(5);
        if (!string.IsNullOrEmpty(record.BaseName))
        {
            fields.Add(Field.BaseName);
        }

        if (record.BaseTime is not null)
        {
            fields.Add(Field.BaseTime);
        }

        if (!string.IsNullOrEmpty(record.Name))
        {
            fields.Add(Field.Name);
        }

        if (record.Time is not null)
        {
            fields.Add(Field.Time);
        }

        switch (record.ValueKind)
        {
            case SenmlValueKind.Number: fields.Add(Field.Number); break;
            case SenmlValueKind.String: fields.Add(Field.String); break;
            case SenmlValueKind.Boolean: fields.Add(Field.Boolean); break;
            case SenmlValueKind.Opaque: fields.Add(Field.Opaque); break;
            case SenmlValueKind.ObjectLink: fields.Add(Field.ObjectLink); break;
        }

        // RFC 8949 §4.2.1: shorter encoded keys first, then bytewise.
        fields.Sort((a, b) =>
        {
            var x = Keys[a];
            var y = Keys[b];
            return x.Length != y.Length ? x.Length.CompareTo(y.Length) : x.AsSpan().SequenceCompareTo(y);
        });

        writer.WriteMapHead(fields.Count);
        foreach (var field in fields)
        {
            writer.WriteRaw(Keys[field]);
            switch (field)
            {
                case Field.BaseName: writer.WriteText(record.BaseName!); break;
                case Field.BaseTime: writer.WriteNumber(record.BaseTime!.Value); break;
                case Field.Name: writer.WriteText(record.Name!); break;
                case Field.Time: writer.WriteNumber(record.Time!.Value); break;
                case Field.Number: writer.WriteNumber(record.NumberValue!.Value); break;
                case Field.String: writer.WriteText(record.StringValue!); break;
                case Field.Boolean: writer.WriteBoolean(record.BooleanValue!.Value); break;
                case Field.Opaque: writer.WriteBytes(record.OpaqueValue!.Value.Span); break;
                case Field.ObjectLink: writer.WriteText(record.ObjectLinkValue!); break;
            }
        }
    }
}

internal static class SenmlValidation
{
    public static void CheckValues(SenmlPack pack, bool allowNoValue)
    {
        if (allowNoValue)
        {
            return;
        }

        for (int i = 0; i < pack.Records.Count; i++)
        {
            if (pack.Records[i].ValueKind == SenmlValueKind.None)
            {
                throw new Lwm2mException(Lwm2mErrorCode.MissingValue, $"the record at index {i} has no value field");
            }
        }
    }

    public static string? Text(object? value, string key) => value switch
    {
        null => null,
        string s => s,
        _ => throw Malformed($"expected text at key \"{key}\""),
    };

    public static SenmlNumber? Number(object? value, string key) => value switch
    {
        null => null,
        SenmlNumber n => n,
        _ => throw Malformed($"expected a number at key \"{key}\""),
    };

    public static bool? Boolean(object? value, string key) => value switch
    {
        null => null,
        bool b => b,
        _ => throw Malformed($"expected a boolean at key \"{key}\""),
    };

    public static Lwm2mException Malformed(string message) => new(Lwm2mErrorCode.MalformedSenml, message);
}

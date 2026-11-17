using Wick.Lwm2m.Senml;

namespace Wick.Lwm2m.Codecs;

/// <summary>
/// Conversion between SenML record value fields and typed <see cref="Lwm2mValue"/>s.
/// </summary>
internal static class SenmlValues
{
    /// <summary>The record a typed value becomes, with no name set.</summary>
    public static SenmlRecord ToRecord(Lwm2mValue value) => value.Type switch
    {
        Lwm2mType.String => new SenmlRecord { StringValue = value.AsString() },
        Lwm2mType.CoreLink => new SenmlRecord { StringValue = value.AsCoreLink() },
        Lwm2mType.Integer => new SenmlRecord { NumberValue = value.AsInteger() },
        Lwm2mType.UnsignedInteger => new SenmlRecord { NumberValue = value.AsUnsignedInteger() },
        Lwm2mType.Time => new SenmlRecord { NumberValue = value.AsTime() },
        Lwm2mType.Float => new SenmlRecord { NumberValue = SenmlNumber.FromFloat(value.AsFloat()) },
        Lwm2mType.Boolean => new SenmlRecord { BooleanValue = value.AsBoolean() },
        Lwm2mType.Opaque => new SenmlRecord { OpaqueValue = value.AsOpaque() },
        Lwm2mType.ObjectLink => new SenmlRecord { ObjectLinkValue = value.AsObjectLink().ToString() },
        _ => new SenmlRecord(),
    };

    /// <summary>
    /// The value a record holds, typed as <paramref name="declared"/> when the model supplies a
    /// type, or inferred from the SenML value field when it does not.
    /// </summary>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.TypeMismatch"/> when the value cannot satisfy the declared type.</exception>
    public static Lwm2mValue ToValue(SenmlRecord record, Lwm2mType? declared, Lwm2mPath path)
    {
        return declared is { } type ? Coerce(record, type, path) : Infer(record);
    }

    private static Lwm2mValue Infer(SenmlRecord record)
    {
        switch (record.ValueKind)
        {
            case SenmlValueKind.Number:
                var number = record.NumberValue!.Value;
                if (!number.IsInteger)
                {
                    return Lwm2mValue.FromFloat(number.AsDouble);
                }

                if (number.TryGetInt64(out var signed))
                {
                    return Lwm2mValue.FromInteger(signed);
                }

                return number.TryGetUInt64(out var unsigned)
                    ? Lwm2mValue.FromUnsignedInteger(unsigned)
                    : Lwm2mValue.FromFloat(number.AsDouble);
            case SenmlValueKind.String:
                return Lwm2mValue.FromString(record.StringValue!);
            case SenmlValueKind.Boolean:
                return Lwm2mValue.FromBoolean(record.BooleanValue!.Value);
            case SenmlValueKind.Opaque:
                return Lwm2mValue.FromOpaque(record.OpaqueValue!.Value.Span);
            case SenmlValueKind.ObjectLink:
                return Lwm2mValue.FromObjectLink(ObjectLink.Parse(record.ObjectLinkValue!));
            default:
                return Lwm2mValue.None;
        }
    }

    // The pairs that are not here are the point: a string arriving for an Integer Resource has no
    // sensible reading, and storing it anyway is how a server ends up holding garbage.
    private static Lwm2mValue Coerce(SenmlRecord record, Lwm2mType declared, Lwm2mPath path)
    {
        var kind = record.ValueKind;
        Lwm2mValue? value = (declared, kind) switch
        {
            (Lwm2mType.String, SenmlValueKind.String) => Lwm2mValue.FromString(record.StringValue!),
            (Lwm2mType.CoreLink, SenmlValueKind.String) => Lwm2mValue.FromCoreLink(record.StringValue!),
            (Lwm2mType.Opaque, SenmlValueKind.Opaque) => Lwm2mValue.FromOpaque(record.OpaqueValue!.Value.Span),
            (Lwm2mType.Boolean, SenmlValueKind.Boolean) => Lwm2mValue.FromBoolean(record.BooleanValue!.Value),

            // LwM2M 1.1 defines vlo for Object Links, but Leshan's node encoder writes them as vs.
            (Lwm2mType.ObjectLink, SenmlValueKind.ObjectLink) => ParseLink(record.ObjectLinkValue!, path),
            (Lwm2mType.ObjectLink, SenmlValueKind.String) => ParseLink(record.StringValue!, path),

            (Lwm2mType.Integer, SenmlValueKind.Number) when record.NumberValue!.Value.TryGetInt64(out var i) => Lwm2mValue.FromInteger(i),
            (Lwm2mType.Time, SenmlValueKind.Number) when record.NumberValue!.Value.TryGetInt64(out var t) => Lwm2mValue.FromTime(t),
            (Lwm2mType.UnsignedInteger, SenmlValueKind.Number) when record.NumberValue!.Value.TryGetUInt64(out var u) => Lwm2mValue.FromUnsignedInteger(u),

            // SenML writes 22 rather than 22.0 when a Float happens to be whole, so widening is allowed.
            (Lwm2mType.Float, SenmlValueKind.Number) => Lwm2mValue.FromFloat(record.NumberValue!.Value.AsDouble),
            (Lwm2mType.None, SenmlValueKind.None) => Lwm2mValue.None,
            _ => null,
        };

        return value ?? throw new Lwm2mException(
            Lwm2mErrorCode.TypeMismatch,
            $"{path} is declared {declared} but the record carries {Describe(record)}");
    }

    private static Lwm2mValue ParseLink(string text, Lwm2mPath path)
    {
        try
        {
            return Lwm2mValue.FromObjectLink(ObjectLink.Parse(text));
        }
        catch (Lwm2mException e)
        {
            throw new Lwm2mException(Lwm2mErrorCode.TypeMismatch, $"{path}: {e.Message}", e);
        }
    }

    private static string Describe(SenmlRecord record) => record.ValueKind switch
    {
        SenmlValueKind.Number => $"the number {record.NumberValue}",
        SenmlValueKind.String => "a string",
        SenmlValueKind.Boolean => "a boolean",
        SenmlValueKind.Opaque => "opaque bytes",
        SenmlValueKind.ObjectLink => "an Object Link",
        _ => "no value",
    };
}

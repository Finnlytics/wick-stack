namespace Wick.Lwm2m.Senml;

/// <summary>Which value field a <see cref="SenmlRecord"/> carries.</summary>
public enum SenmlValueKind
{
    /// <summary>No value field. Read-Composite request bodies are made of these.</summary>
    None,

    /// <summary>A number (<c>v</c>).</summary>
    Number,

    /// <summary>A string (<c>vs</c>).</summary>
    String,

    /// <summary>A boolean (<c>vb</c>).</summary>
    Boolean,

    /// <summary>Opaque bytes (<c>vd</c>).</summary>
    Opaque,

    /// <summary>An LwM2M Object Link (<c>vlo</c>), the LwM2M 1.1 extension to SenML.</summary>
    ObjectLink,
}

/// <summary>
/// One SenML record (RFC 8428 §4), with the LwM2M <c>vlo</c> extension.
/// </summary>
/// <remarks>
/// <para>
/// A record normally sets exactly one value field. This type does not enforce that: the encoders
/// do, and Read-Composite bodies legitimately carry records with no value at all. When several
/// value fields are set, <see cref="ValueKind"/> picks one in Eclipse Leshan's precedence:
/// boolean, number, Object Link, string, opaque.
/// </para>
/// <para>Base fields (<see cref="BaseName"/>, <see cref="BaseTime"/>) apply to this record and every later one in the pack until overridden.</para>
/// </remarks>
public sealed record SenmlRecord
{
    private readonly ReadOnlyMemory<byte>? _opaque;

    /// <summary>The base name (<c>bn</c>), or <see langword="null"/>.</summary>
    public string? BaseName { get; init; }

    /// <summary>The base time (<c>bt</c>), or <see langword="null"/>.</summary>
    public SenmlNumber? BaseTime { get; init; }

    /// <summary>The name (<c>n</c>), or <see langword="null"/>.</summary>
    public string? Name { get; init; }

    /// <summary>The time (<c>t</c>), or <see langword="null"/>.</summary>
    public SenmlNumber? Time { get; init; }

    /// <summary>The numeric value (<c>v</c>), or <see langword="null"/>.</summary>
    public SenmlNumber? NumberValue { get; init; }

    /// <summary>The string value (<c>vs</c>), or <see langword="null"/>.</summary>
    public string? StringValue { get; init; }

    /// <summary>The boolean value (<c>vb</c>), or <see langword="null"/>.</summary>
    public bool? BooleanValue { get; init; }

    /// <summary>The opaque value (<c>vd</c>), or <see langword="null"/>. Bytes are copied on assignment.</summary>
    public ReadOnlyMemory<byte>? OpaqueValue
    {
        get => _opaque;
        init => _opaque = Copy(value);
    }

    // A null literal converts to ReadOnlyMemory<byte> through its implicit conversion from byte[],
    // so a conditional expression here would turn "absent" into "empty". Branch explicitly.
    private static ReadOnlyMemory<byte>? Copy(ReadOnlyMemory<byte>? value)
    {
        if (value is null)
        {
            return null;
        }

        return value.Value.ToArray();
    }

    /// <summary>The Object Link value (<c>vlo</c>) in <c>object:instance</c> form, or <see langword="null"/>.</summary>
    public string? ObjectLinkValue { get; init; }

    /// <summary>Which value field the record carries, using Leshan's precedence when more than one is set.</summary>
    public SenmlValueKind ValueKind =>
        BooleanValue is not null ? SenmlValueKind.Boolean :
        NumberValue is not null ? SenmlValueKind.Number :
        ObjectLinkValue is not null ? SenmlValueKind.ObjectLink :
        StringValue is not null ? SenmlValueKind.String :
        OpaqueValue is not null ? SenmlValueKind.Opaque :
        SenmlValueKind.None;

    /// <inheritdoc/>
    public bool Equals(SenmlRecord? other) =>
        other is not null &&
        BaseName == other.BaseName && Nullable.Equals(BaseTime, other.BaseTime) &&
        Name == other.Name && Nullable.Equals(Time, other.Time) &&
        Nullable.Equals(NumberValue, other.NumberValue) && StringValue == other.StringValue &&
        BooleanValue == other.BooleanValue && ObjectLinkValue == other.ObjectLinkValue &&
        (OpaqueValue is null ? other.OpaqueValue is null :
            other.OpaqueValue is not null && OpaqueValue.Value.Span.SequenceEqual(other.OpaqueValue.Value.Span));

    /// <inheritdoc/>
    public override int GetHashCode() =>
        HashCode.Combine(BaseName, BaseTime, Name, Time, NumberValue, StringValue, BooleanValue, ObjectLinkValue);
}

/// <summary>A record's name and time after the pack's base fields have been applied.</summary>
/// <param name="Name">The full name: the base name in scope followed by the record's name.</param>
/// <param name="Time">The base time in scope plus the record's time, or <see langword="null"/> when neither is set.</param>
/// <param name="Record">The record itself.</param>
public sealed record ResolvedSenmlRecord(string Name, SenmlNumber? Time, SenmlRecord Record);

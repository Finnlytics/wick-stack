using System.Globalization;

namespace Wick.Lwm2m;

/// <summary>
/// The LwM2M Resource data types (OMA LwM2M 1.2 §7.4 and Appendix C).
/// </summary>
public enum Lwm2mType
{
    /// <summary>No value. Executable Resources declare this.</summary>
    None,

    /// <summary>A UTF-8 string.</summary>
    String,

    /// <summary>A signed 64-bit integer.</summary>
    Integer,

    /// <summary>An unsigned 64-bit integer (LwM2M 1.1 and later).</summary>
    UnsignedInteger,

    /// <summary>An IEEE 754 double-precision float.</summary>
    Float,

    /// <summary>A boolean.</summary>
    Boolean,

    /// <summary>Raw bytes.</summary>
    Opaque,

    /// <summary>A point in time, carried on the wire as whole seconds since the Unix epoch.</summary>
    Time,

    /// <summary>A reference to an Object Instance, written <c>object:instance</c>.</summary>
    ObjectLink,

    /// <summary>A CoRE Link Format string (RFC 6690), LwM2M 1.1 and later.</summary>
    CoreLink,
}

/// <summary>
/// An LwM2M Object Link (Objlnk) value: an Object ID and an Object Instance ID.
/// </summary>
/// <param name="ObjectId">The Object ID, 0 to 65535.</param>
/// <param name="ObjectInstanceId">The Object Instance ID, 0 to 65535.</param>
public readonly record struct ObjectLink(ushort ObjectId, ushort ObjectInstanceId)
{
    /// <summary>The null link <c>65535:65535</c>, which OMA LwM2M uses for "no Instance".</summary>
    public static ObjectLink Null => new(ushort.MaxValue, ushort.MaxValue);

    /// <summary>True for the null link <c>65535:65535</c>.</summary>
    public bool IsNull => ObjectId == ushort.MaxValue && ObjectInstanceId == ushort.MaxValue;

    /// <summary>Parses the <c>object:instance</c> text form used by plain text and SenML.</summary>
    /// <param name="text">Text such as <c>1:0</c>.</param>
    /// <returns>The link.</returns>
    /// <exception cref="Lwm2mException">The text is not two integers in range separated by a colon.</exception>
    public static ObjectLink Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var parts = text.Split(':');
        if (parts.Length == 2 &&
            ushort.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var objectId) &&
            ushort.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var instanceId))
        {
            return new ObjectLink(objectId, instanceId);
        }

        throw new Lwm2mException(Lwm2mErrorCode.TypeMismatch, $"\"{text}\" is not an Object Link; expected object:instance");
    }

    /// <summary>Formats the link as <c>object:instance</c>.</summary>
    /// <returns>The text form.</returns>
    public override string ToString() =>
        string.Create(CultureInfo.InvariantCulture, $"{ObjectId}:{ObjectInstanceId}");
}

/// <summary>
/// A Resource value tagged with its LwM2M type.
/// </summary>
/// <remarks>
/// <para>
/// The tag matters because the wire often cannot carry it: the number 42 could be an Integer, an
/// Unsigned Integer, a Float or a Time, and a byte string could be a String or Opaque. Holding the
/// type alongside the value means encoding never has to guess.
/// </para>
/// <para>
/// Time is held as whole seconds since the Unix epoch, which is what every LwM2M format carries.
/// <see cref="AsDateTimeOffset"/> converts at the caller's boundary.
/// </para>
/// <para>Values are immutable. Opaque bytes are copied on the way in and exposed read-only.</para>
/// </remarks>
public sealed class Lwm2mValue : IEquatable<Lwm2mValue>
{
    private readonly object? _value;

    private Lwm2mValue(Lwm2mType type, object? value)
    {
        Type = type;
        _value = value;
    }

    /// <summary>The value's LwM2M type.</summary>
    public Lwm2mType Type { get; }

    /// <summary>The empty value carried by an Executable Resource.</summary>
    public static Lwm2mValue None { get; } = new(Lwm2mType.None, null);

    /// <summary>Creates a String value.</summary>
    /// <param name="value">The string.</param>
    /// <returns>The tagged value.</returns>
    public static Lwm2mValue FromString(string value) => new(Lwm2mType.String, value ?? throw new ArgumentNullException(nameof(value)));

    /// <summary>Creates an Integer value.</summary>
    /// <param name="value">The integer.</param>
    /// <returns>The tagged value.</returns>
    public static Lwm2mValue FromInteger(long value) => new(Lwm2mType.Integer, value);

    /// <summary>Creates an Unsigned Integer value.</summary>
    /// <param name="value">The unsigned integer.</param>
    /// <returns>The tagged value.</returns>
    public static Lwm2mValue FromUnsignedInteger(ulong value) => new(Lwm2mType.UnsignedInteger, value);

    /// <summary>Creates a Float value.</summary>
    /// <param name="value">The float.</param>
    /// <returns>The tagged value.</returns>
    public static Lwm2mValue FromFloat(double value) => new(Lwm2mType.Float, value);

    /// <summary>Creates a Boolean value.</summary>
    /// <param name="value">The boolean.</param>
    /// <returns>The tagged value.</returns>
    public static Lwm2mValue FromBoolean(bool value) => new(Lwm2mType.Boolean, value);

    /// <summary>Creates an Opaque value. The bytes are copied.</summary>
    /// <param name="value">The bytes.</param>
    /// <returns>The tagged value.</returns>
    public static Lwm2mValue FromOpaque(ReadOnlySpan<byte> value) => new(Lwm2mType.Opaque, value.ToArray());

    /// <summary>Creates a Time value from whole seconds since the Unix epoch.</summary>
    /// <param name="secondsSinceEpoch">Seconds since 1970-01-01T00:00:00Z.</param>
    /// <returns>The tagged value.</returns>
    public static Lwm2mValue FromTime(long secondsSinceEpoch) => new(Lwm2mType.Time, secondsSinceEpoch);

    /// <summary>Creates a Time value. Sub-second precision is truncated, since no LwM2M format carries it.</summary>
    /// <param name="value">The point in time.</param>
    /// <returns>The tagged value.</returns>
    public static Lwm2mValue FromTime(DateTimeOffset value) => new(Lwm2mType.Time, value.ToUnixTimeSeconds());

    /// <summary>Creates an Object Link value.</summary>
    /// <param name="value">The link.</param>
    /// <returns>The tagged value.</returns>
    public static Lwm2mValue FromObjectLink(ObjectLink value) => new(Lwm2mType.ObjectLink, value);

    /// <summary>Creates a CoRE Link value from its RFC 6690 text.</summary>
    /// <param name="value">The link-format text.</param>
    /// <returns>The tagged value.</returns>
    public static Lwm2mValue FromCoreLink(string value) => new(Lwm2mType.CoreLink, value ?? throw new ArgumentNullException(nameof(value)));

    /// <summary>The String value.</summary>
    /// <returns>The string.</returns>
    /// <exception cref="InvalidOperationException">The value is not a String.</exception>
    public string AsString() => As<string>(Lwm2mType.String);

    /// <summary>The Integer value.</summary>
    /// <returns>The integer.</returns>
    /// <exception cref="InvalidOperationException">The value is not an Integer.</exception>
    public long AsInteger() => As<long>(Lwm2mType.Integer);

    /// <summary>The Unsigned Integer value.</summary>
    /// <returns>The unsigned integer.</returns>
    /// <exception cref="InvalidOperationException">The value is not an Unsigned Integer.</exception>
    public ulong AsUnsignedInteger() => As<ulong>(Lwm2mType.UnsignedInteger);

    /// <summary>The Float value.</summary>
    /// <returns>The float.</returns>
    /// <exception cref="InvalidOperationException">The value is not a Float.</exception>
    public double AsFloat() => As<double>(Lwm2mType.Float);

    /// <summary>The Boolean value.</summary>
    /// <returns>The boolean.</returns>
    /// <exception cref="InvalidOperationException">The value is not a Boolean.</exception>
    public bool AsBoolean() => As<bool>(Lwm2mType.Boolean);

    /// <summary>The Opaque value.</summary>
    /// <returns>The bytes, read-only.</returns>
    /// <exception cref="InvalidOperationException">The value is not Opaque.</exception>
    public ReadOnlyMemory<byte> AsOpaque() => As<byte[]>(Lwm2mType.Opaque);

    /// <summary>The Time value as whole seconds since the Unix epoch.</summary>
    /// <returns>The seconds.</returns>
    /// <exception cref="InvalidOperationException">The value is not a Time.</exception>
    public long AsTime() => As<long>(Lwm2mType.Time);

    /// <summary>The Time value as a <see cref="DateTimeOffset"/> in UTC.</summary>
    /// <returns>The point in time.</returns>
    /// <exception cref="InvalidOperationException">The value is not a Time.</exception>
    public DateTimeOffset AsDateTimeOffset() => DateTimeOffset.FromUnixTimeSeconds(AsTime());

    /// <summary>The Object Link value.</summary>
    /// <returns>The link.</returns>
    /// <exception cref="InvalidOperationException">The value is not an Object Link.</exception>
    public ObjectLink AsObjectLink() => As<ObjectLink>(Lwm2mType.ObjectLink);

    /// <summary>The CoRE Link value as its RFC 6690 text.</summary>
    /// <returns>The link-format text.</returns>
    /// <exception cref="InvalidOperationException">The value is not a CoRE Link.</exception>
    public string AsCoreLink() => As<string>(Lwm2mType.CoreLink);

    /// <inheritdoc/>
    public bool Equals(Lwm2mValue? other)
    {
        if (other is null || other.Type != Type)
        {
            return false;
        }

        return Type switch
        {
            Lwm2mType.None => true,
            Lwm2mType.Opaque => ((byte[])_value!).AsSpan().SequenceEqual((byte[])other._value!),
            Lwm2mType.Float => ((double)_value!).Equals((double)other._value!),
            _ => Equals(_value, other._value),
        };
    }

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is Lwm2mValue other && Equals(other);

    /// <inheritdoc/>
    public override int GetHashCode()
    {
        if (Type == Lwm2mType.Opaque)
        {
            var hash = new HashCode();
            hash.Add(Type);
            hash.AddBytes((byte[])_value!);
            return hash.ToHashCode();
        }

        return HashCode.Combine(Type, _value);
    }

    /// <summary>A readable rendering such as <c>Integer(87)</c>, for logs and test failures.</summary>
    /// <returns>The rendering.</returns>
    public override string ToString() => Type switch
    {
        Lwm2mType.None => "None",
        Lwm2mType.Opaque => $"Opaque({Convert.ToHexString((byte[])_value!)})",
        Lwm2mType.Float => $"Float({((double)_value!).ToString("R", CultureInfo.InvariantCulture)})",
        _ => $"{Type}({Convert.ToString(_value, CultureInfo.InvariantCulture)})",
    };

    /// <summary>Compares two values by type and content.</summary>
    /// <param name="left">The first value.</param>
    /// <param name="right">The second value.</param>
    /// <returns>Whether they are equal.</returns>
    public static bool operator ==(Lwm2mValue? left, Lwm2mValue? right) => left is null ? right is null : left.Equals(right);

    /// <summary>Compares two values by type and content.</summary>
    /// <param name="left">The first value.</param>
    /// <param name="right">The second value.</param>
    /// <returns>Whether they differ.</returns>
    public static bool operator !=(Lwm2mValue? left, Lwm2mValue? right) => !(left == right);

    private T As<T>(Lwm2mType expected) => Type == expected
        ? (T)_value!
        : throw new InvalidOperationException($"the value is {Type}, not {expected}");
}

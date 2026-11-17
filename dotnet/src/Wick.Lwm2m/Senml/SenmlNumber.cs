using System.Globalization;

namespace Wick.Lwm2m.Senml;

/// <summary>
/// A number as SenML carries it: either an integer or a floating-point value.
/// </summary>
/// <remarks>
/// Both JSON and CBOR distinguish <c>22</c> from <c>22.0</c> on the wire, and LwM2M relies on it:
/// an Integer Resource sent as <c>22.0</c> is a type error, while a Float Resource sent as <c>22</c>
/// is acceptable. Integers cover the full range CBOR can carry, from -2^64 to 2^64-1, so an
/// Unsigned Integer above <see cref="long.MaxValue"/> survives a round trip.
/// </remarks>
public readonly struct SenmlNumber : IEquatable<SenmlNumber>
{
    /// <summary>The smallest integer CBOR can encode, -2^64.</summary>
    public static readonly Int128 MinInteger = -(Int128.One << 64);

    /// <summary>The largest integer CBOR can encode, 2^64-1.</summary>
    public static readonly Int128 MaxInteger = (Int128.One << 64) - 1;

    private readonly Int128 _integer;
    private readonly double _float;

    private SenmlNumber(Int128 integer, double value, bool isInteger)
    {
        _integer = integer;
        _float = value;
        IsInteger = isInteger;
    }

    /// <summary>True when the number is an integer; false when it is floating point.</summary>
    public bool IsInteger { get; }

    /// <summary>Creates an integer number.</summary>
    /// <param name="value">The value, between -2^64 and 2^64-1.</param>
    /// <returns>The number.</returns>
    /// <exception cref="ArgumentOutOfRangeException">The value is outside the CBOR integer range.</exception>
    public static SenmlNumber FromInteger(Int128 value) => value < MinInteger || value > MaxInteger
        ? throw new ArgumentOutOfRangeException(nameof(value), "SenML integers range from -2^64 to 2^64-1")
        : new SenmlNumber(value, 0, true);

    /// <summary>Creates a floating-point number.</summary>
    /// <param name="value">The value.</param>
    /// <returns>The number.</returns>
    public static SenmlNumber FromFloat(double value) => new(0, value, false);

    /// <summary>Converts a 32-bit integer.</summary>
    /// <param name="value">The value.</param>
    public static implicit operator SenmlNumber(int value) => new(value, 0, true);

    /// <summary>Converts a signed integer.</summary>
    /// <param name="value">The value.</param>
    public static implicit operator SenmlNumber(long value) => new(value, 0, true);

    /// <summary>Converts an unsigned integer.</summary>
    /// <param name="value">The value.</param>
    public static implicit operator SenmlNumber(ulong value) => new(value, 0, true);

    /// <summary>Converts a double.</summary>
    /// <param name="value">The value.</param>
    public static implicit operator SenmlNumber(double value) => FromFloat(value);

    /// <summary>The integer value.</summary>
    /// <exception cref="InvalidOperationException">The number is floating point.</exception>
    public Int128 Integer => IsInteger ? _integer : throw new InvalidOperationException("the number is not an integer");

    /// <summary>The value as a double, converting an integer if necessary.</summary>
    public double AsDouble => IsInteger ? (double)_integer : _float;

    /// <summary>Gets the value as a <see cref="long"/> when it is an integer in range.</summary>
    /// <param name="value">The value.</param>
    /// <returns>Whether the number is an integer that fits.</returns>
    public bool TryGetInt64(out long value)
    {
        if (IsInteger && _integer >= long.MinValue && _integer <= long.MaxValue)
        {
            value = (long)_integer;
            return true;
        }

        value = 0;
        return false;
    }

    /// <summary>Gets the value as a <see cref="ulong"/> when it is a non-negative integer in range.</summary>
    /// <param name="value">The value.</param>
    /// <returns>Whether the number is an integer that fits.</returns>
    public bool TryGetUInt64(out ulong value)
    {
        if (IsInteger && _integer >= 0 && _integer <= ulong.MaxValue)
        {
            value = (ulong)_integer;
            return true;
        }

        value = 0;
        return false;
    }

    /// <summary>Adds two numbers, staying integral when both are. Used to resolve SenML base time.</summary>
    /// <param name="left">The first number.</param>
    /// <param name="right">The second number.</param>
    /// <returns>The sum.</returns>
    public static SenmlNumber operator +(SenmlNumber left, SenmlNumber right) =>
        left.IsInteger && right.IsInteger
            ? FromInteger(Int128.Clamp(left._integer + right._integer, MinInteger, MaxInteger))
            : FromFloat(left.AsDouble + right.AsDouble);

    /// <inheritdoc/>
    public bool Equals(SenmlNumber other) =>
        IsInteger == other.IsInteger && (IsInteger ? _integer == other._integer : _float.Equals(other._float));

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is SenmlNumber other && Equals(other);

    /// <inheritdoc/>
    public override int GetHashCode() => IsInteger ? HashCode.Combine(true, _integer) : HashCode.Combine(false, _float);

    /// <summary>Compares two numbers for equality, including whether each is integral.</summary>
    /// <param name="left">The first number.</param>
    /// <param name="right">The second number.</param>
    /// <returns>Whether they are equal.</returns>
    public static bool operator ==(SenmlNumber left, SenmlNumber right) => left.Equals(right);

    /// <summary>Compares two numbers for inequality.</summary>
    /// <param name="left">The first number.</param>
    /// <param name="right">The second number.</param>
    /// <returns>Whether they differ.</returns>
    public static bool operator !=(SenmlNumber left, SenmlNumber right) => !left.Equals(right);

    /// <inheritdoc/>
    public override string ToString() => IsInteger
        ? _integer.ToString(CultureInfo.InvariantCulture)
        : _float.ToString("R", CultureInfo.InvariantCulture);
}

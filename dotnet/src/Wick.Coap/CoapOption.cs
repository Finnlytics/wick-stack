using System.Buffers.Binary;
using System.Text;

namespace Wick.Coap;

/// <summary>
/// One CoAP option: an absolute option number and its raw value (RFC 7252 section 3.1).
/// Deltas exist only on the wire; in memory every option carries its full number.
/// Two options are equal when their numbers and value bytes are equal.
/// </summary>
public readonly struct CoapOption : IEquatable<CoapOption>
{
    private readonly byte[]? _value;

    /// <summary>Creates an option with a raw value.</summary>
    /// <param name="number">The option number, 0 to 65535.</param>
    /// <param name="value">The value bytes. The array is used as given, not copied.</param>
    /// <exception cref="ArgumentOutOfRangeException">The number is out of range.</exception>
    public CoapOption(int number, byte[]? value = null)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(number);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(number, 65535);
        Number = number;
        _value = value is { Length: > 0 } ? value : null;
    }

    /// <summary>The option number.</summary>
    public int Number { get; }

    /// <summary>The raw value bytes.</summary>
    public ReadOnlyMemory<byte> Value => _value ?? ReadOnlyMemory<byte>.Empty;

    /// <summary>The length of the value in bytes.</summary>
    public int Length => _value?.Length ?? 0;

    /// <summary>Creates an option whose value is a UTF-8 string.</summary>
    /// <param name="number">The option number.</param>
    /// <param name="value">The string value.</param>
    /// <returns>The option.</returns>
    public static CoapOption FromString(int number, string value) => new(number, Encoding.UTF8.GetBytes(value));

    /// <summary>
    /// Creates an option whose value is an unsigned integer in the shortest big-endian form,
    /// so zero is an empty value (RFC 7252 section 3.2).
    /// </summary>
    /// <param name="number">The option number.</param>
    /// <param name="value">The integer value.</param>
    /// <returns>The option.</returns>
    public static CoapOption FromUInt(int number, uint value) => new(number, EncodeUInt(value));

    /// <summary>Reads the value as a UTF-8 string.</summary>
    /// <returns>The decoded string.</returns>
    public string GetString() => _value is null ? string.Empty : Encoding.UTF8.GetString(_value);

    /// <summary>
    /// Reads the value as a big-endian unsigned integer. An empty value is zero.
    /// </summary>
    /// <returns>The integer value.</returns>
    /// <exception cref="FormatException">The value is longer than four bytes.</exception>
    public uint GetUInt()
    {
        if (_value is null) return 0;
        if (_value.Length > 4) throw new FormatException($"Option {Number} value is {_value.Length} bytes; an unsigned integer option holds at most 4.");
        uint result = 0;
        foreach (var b in _value) result = (result << 8) | b;
        return result;
    }

    /// <summary>Encodes an unsigned integer in the shortest big-endian form; zero encodes as no bytes.</summary>
    /// <param name="value">The value to encode.</param>
    /// <returns>Between zero and four bytes.</returns>
    public static byte[] EncodeUInt(uint value)
    {
        if (value == 0) return [];
        Span<byte> buffer = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(buffer, value);
        int skip = 0;
        while (buffer[skip] == 0) skip++;
        return buffer[skip..].ToArray();
    }

    /// <inheritdoc />
    public bool Equals(CoapOption other) => Number == other.Number && Value.Span.SequenceEqual(other.Value.Span);

    /// <inheritdoc />
    public override bool Equals(object? obj) => obj is CoapOption other && Equals(other);

    /// <inheritdoc />
    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Number);
        hash.AddBytes(Value.Span);
        return hash.ToHashCode();
    }

    /// <summary>Compares two options for equality.</summary>
    /// <param name="left">The first option.</param>
    /// <param name="right">The second option.</param>
    /// <returns>True when equal.</returns>
    public static bool operator ==(CoapOption left, CoapOption right) => left.Equals(right);

    /// <summary>Compares two options for inequality.</summary>
    /// <param name="left">The first option.</param>
    /// <param name="right">The second option.</param>
    /// <returns>True when not equal.</returns>
    public static bool operator !=(CoapOption left, CoapOption right) => !left.Equals(right);

    /// <summary>Formats the option for diagnostics.</summary>
    /// <returns>The option name and value.</returns>
    public override string ToString()
    {
        string name = CoapOptionNumber.NameOf(Number);
        if (OptionDefinitions.TryGet(Number, out var definition))
        {
            return definition.Format switch
            {
                OptionFormat.String => $"{name}: \"{GetString()}\"",
                OptionFormat.UInt when Length <= 4 => $"{name}: {GetUInt()}",
                OptionFormat.Empty => name,
                _ => $"{name}: 0x{Convert.ToHexString(Value.Span)}",
            };
        }
        return $"{name}: 0x{Convert.ToHexString(Value.Span)}";
    }
}

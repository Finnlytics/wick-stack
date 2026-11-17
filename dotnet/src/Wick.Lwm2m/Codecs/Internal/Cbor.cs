using System.Buffers.Binary;
using System.Text;
using Wick.Lwm2m.Senml;

namespace Wick.Lwm2m.Codecs.Internal;

/// <summary>A CBOR byte string, kept distinct from a text string in the decoded tree.</summary>
internal sealed record CborBytes(byte[] Value);

/// <summary>A CBOR tag other than tag 4, which the decoder resolves to a number.</summary>
internal sealed record CborTag(ulong Tag, object? Value);

/// <summary>
/// The subset of CBOR (RFC 8949) that SenML needs, written by hand so the output bytes are fully
/// under Wick's control.
/// </summary>
/// <remarks>
/// Integers and lengths use the shortest head. Floats use the shortest IEEE 754 width that holds
/// the value exactly (RFC 8949 §4.2.1). The decoder accepts definite-length items only and
/// resolves tag 4 (decimal fraction), which Leshan uses for SenML time fields.
/// </remarks>
internal sealed class CborWriter
{
    private readonly MemoryStream _buffer = new();

    public byte[] ToArray() => _buffer.ToArray();

    public void WriteInteger(Int128 value)
    {
        if (value >= 0)
        {
            WriteHead(0, (ulong)value);
        }
        else
        {
            WriteHead(1, (ulong)(-1 - value));
        }
    }

    public void WriteNumber(SenmlNumber number)
    {
        if (number.IsInteger)
        {
            WriteInteger(number.Integer);
        }
        else
        {
            WriteFloat(number.AsDouble);
        }
    }

    public void WriteText(string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        WriteHead(3, (ulong)bytes.Length);
        _buffer.Write(bytes);
    }

    public void WriteBytes(ReadOnlySpan<byte> value)
    {
        WriteHead(2, (ulong)value.Length);
        _buffer.Write(value);
    }

    public void WriteBoolean(bool value) => _buffer.WriteByte(value ? (byte)0xF5 : (byte)0xF4);

    public void WriteArrayHead(int length) => WriteHead(4, (ulong)length);

    public void WriteMapHead(int pairs) => WriteHead(5, (ulong)pairs);

    public void WriteFloat(double value)
    {
        Span<byte> scratch = stackalloc byte[8];
        if (double.IsNaN(value))
        {
            // The canonical quiet NaN, in half precision.
            _buffer.WriteByte(0xF9);
            _buffer.WriteByte(0x7E);
            _buffer.WriteByte(0x00);
            return;
        }

        var half = (Half)value;
        if ((double)half == value)
        {
            _buffer.WriteByte(0xF9);
            BinaryPrimitives.WriteUInt16BigEndian(scratch, BitConverter.HalfToUInt16Bits(half));
            _buffer.Write(scratch[..2]);
            return;
        }

        var single = (float)value;
        if ((double)single == value)
        {
            _buffer.WriteByte(0xFA);
            BinaryPrimitives.WriteSingleBigEndian(scratch, single);
            _buffer.Write(scratch[..4]);
            return;
        }

        _buffer.WriteByte(0xFB);
        BinaryPrimitives.WriteDoubleBigEndian(scratch, value);
        _buffer.Write(scratch);
    }

    /// <summary>The encoded form of an integer map key, used to sort keys canonically.</summary>
    public static byte[] EncodeKey(int key)
    {
        var writer = new CborWriter();
        writer.WriteInteger(key);
        return writer.ToArray();
    }

    /// <summary>The encoded form of a text map key, used to sort keys canonically.</summary>
    public static byte[] EncodeKey(string key)
    {
        var writer = new CborWriter();
        writer.WriteText(key);
        return writer.ToArray();
    }

    public void WriteRaw(ReadOnlySpan<byte> bytes) => _buffer.Write(bytes);

    private void WriteHead(int majorType, ulong value)
    {
        var major = (byte)(majorType << 5);
        Span<byte> scratch = stackalloc byte[8];
        if (value < 24)
        {
            _buffer.WriteByte((byte)(major | (byte)value));
        }
        else if (value <= byte.MaxValue)
        {
            _buffer.WriteByte((byte)(major | 24));
            _buffer.WriteByte((byte)value);
        }
        else if (value <= ushort.MaxValue)
        {
            _buffer.WriteByte((byte)(major | 25));
            BinaryPrimitives.WriteUInt16BigEndian(scratch, (ushort)value);
            _buffer.Write(scratch[..2]);
        }
        else if (value <= uint.MaxValue)
        {
            _buffer.WriteByte((byte)(major | 26));
            BinaryPrimitives.WriteUInt32BigEndian(scratch, (uint)value);
            _buffer.Write(scratch[..4]);
        }
        else
        {
            _buffer.WriteByte((byte)(major | 27));
            BinaryPrimitives.WriteUInt64BigEndian(scratch, value);
            _buffer.Write(scratch);
        }
    }
}

/// <summary>
/// Decodes CBOR into a small tree: <see cref="SenmlNumber"/> for numbers, <see cref="string"/>,
/// <see cref="CborBytes"/>, <see cref="bool"/>, <see langword="null"/>, <see cref="List{T}"/> of
/// items for arrays, <see cref="List{T}"/> of key and value pairs for maps, and <see cref="CborTag"/>.
/// </summary>
internal ref struct CborReader
{
    private const int MaxDepth = 64;

    private readonly ReadOnlySpan<byte> _input;
    private int _offset;

    private CborReader(ReadOnlySpan<byte> input)
    {
        _input = input;
        _offset = 0;
    }

    /// <summary>Decodes exactly one CBOR item filling the whole input.</summary>
    public static object? Decode(ReadOnlySpan<byte> input)
    {
        var reader = new CborReader(input);
        var value = reader.ReadItem(0);
        if (reader._offset != input.Length)
        {
            throw Malformed($"{input.Length - reader._offset} trailing bytes after the CBOR item");
        }

        return value;
    }

    private object? ReadItem(int depth)
    {
        if (depth > MaxDepth)
        {
            throw Malformed("CBOR nesting is too deep");
        }

        var initial = ReadByte();
        int major = initial >> 5;
        int additional = initial & 0x1F;

        switch (major)
        {
            case 0:
                return SenmlNumber.FromInteger(ReadArgument(additional));
            case 1:
                return SenmlNumber.FromInteger(-1 - (Int128)ReadArgument(additional));
            case 2:
                return new CborBytes(Take(ReadLength(additional)).ToArray());
            case 3:
                return DecodeText(Take(ReadLength(additional)));
            case 4:
            {
                var length = ReadLength(additional);
                var items = new List<object?>(Math.Min(length, 256));
                for (int i = 0; i < length; i++)
                {
                    items.Add(ReadItem(depth + 1));
                }

                return items;
            }

            case 5:
            {
                var length = ReadLength(additional);
                var pairs = new List<KeyValuePair<object?, object?>>(Math.Min(length, 64));
                for (int i = 0; i < length; i++)
                {
                    var key = ReadItem(depth + 1);
                    var value = ReadItem(depth + 1);
                    pairs.Add(KeyValuePair.Create(key, value));
                }

                return pairs;
            }

            case 6:
            {
                var tag = ReadArgument(additional);
                var content = ReadItem(depth + 1);
                return tag == 4 ? ResolveDecimalFraction(content) : new CborTag(tag, content);
            }

            default:
                return ReadSimple(additional);
        }
    }

    private object? ReadSimple(int additional)
    {
        switch (additional)
        {
            case 20:
                return false;
            case 21:
                return true;
            case 22:
            case 23:
                return null;
            case 25:
                return SenmlNumber.FromFloat((double)BitConverter.UInt16BitsToHalf(BinaryPrimitives.ReadUInt16BigEndian(Take(2))));
            case 26:
                return SenmlNumber.FromFloat(BinaryPrimitives.ReadSingleBigEndian(Take(4)));
            case 27:
                return SenmlNumber.FromFloat(BinaryPrimitives.ReadDoubleBigEndian(Take(8)));
            case 31:
                throw Malformed("indefinite-length items are not supported");
            default:
                throw Malformed($"unsupported simple value {additional}");
        }
    }

    // RFC 8949 §3.4.4: tag 4 wraps [exponent, mantissa], meaning mantissa * 10^exponent.
    private static SenmlNumber ResolveDecimalFraction(object? content)
    {
        if (content is List<object?> { Count: 2 } parts &&
            parts[0] is SenmlNumber { IsInteger: true } exponent &&
            parts[1] is SenmlNumber { IsInteger: true } mantissa &&
            exponent.TryGetInt64(out var e) && e is >= -400 and <= 400)
        {
            if (e >= 0)
            {
                Int128 value = mantissa.Integer;
                for (long i = 0; i < e; i++)
                {
                    value *= 10;
                    if (value > SenmlNumber.MaxInteger || value < SenmlNumber.MinInteger)
                    {
                        return SenmlNumber.FromFloat((double)mantissa.Integer * Math.Pow(10, e));
                    }
                }

                return SenmlNumber.FromInteger(value);
            }

            return SenmlNumber.FromFloat(double.Parse(
                $"{mantissa.Integer}E{e}", System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture));
        }

        throw Malformed("malformed tag 4 (decimal fraction)");
    }

    private ulong ReadArgument(int additional) => additional switch
    {
        < 24 => (ulong)additional,
        24 => ReadByte(),
        25 => BinaryPrimitives.ReadUInt16BigEndian(Take(2)),
        26 => BinaryPrimitives.ReadUInt32BigEndian(Take(4)),
        27 => BinaryPrimitives.ReadUInt64BigEndian(Take(8)),
        31 => throw Malformed("indefinite-length items are not supported"),
        _ => throw Malformed($"reserved additional information {additional}"),
    };

    private int ReadLength(int additional)
    {
        var length = ReadArgument(additional);
        return length > (ulong)(_input.Length - _offset)
            ? throw Malformed($"declared length {length} exceeds the {_input.Length - _offset} bytes remaining")
            : (int)length;
    }

    private byte ReadByte()
    {
        if (_offset >= _input.Length)
        {
            throw Malformed("unexpected end of input");
        }

        return _input[_offset++];
    }

    private ReadOnlySpan<byte> Take(int count)
    {
        if (count > _input.Length - _offset)
        {
            throw Malformed("unexpected end of input");
        }

        var slice = _input.Slice(_offset, count);
        _offset += count;
        return slice;
    }

    private static string DecodeText(ReadOnlySpan<byte> bytes)
    {
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (DecoderFallbackException e)
        {
            throw new Lwm2mException(Lwm2mErrorCode.MalformedCbor, "a CBOR text string is not valid UTF-8", e);
        }
    }

    private static Lwm2mException Malformed(string message) => new(Lwm2mErrorCode.MalformedCbor, message);
}

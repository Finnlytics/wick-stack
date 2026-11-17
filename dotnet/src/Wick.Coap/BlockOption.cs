namespace Wick.Coap;

/// <summary>
/// The value of a Block1 or Block2 option (RFC 7959 section 2.2): a block number, a
/// more flag and a size exponent, packed into an unsigned integer of up to three bytes as
/// <c>NUM &lt;&lt; 4 | M &lt;&lt; 3 | SZX</c>.
/// </summary>
public readonly record struct BlockOption
{
    /// <summary>The largest block number a three-byte value can carry.</summary>
    public const int MaxNumber = 0xFFFFF;

    /// <summary>Creates a block value.</summary>
    /// <param name="number">The block number, 0 to 1048575.</param>
    /// <param name="more">True when more blocks follow.</param>
    /// <param name="sizeExponent">The size exponent, 0 to 6; the block size is <c>2^(SZX + 4)</c>.</param>
    /// <exception cref="ArgumentOutOfRangeException">A field is out of range. SZX 7 is reserved.</exception>
    public BlockOption(int number, bool more, int sizeExponent)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(number);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(number, MaxNumber);
        ArgumentOutOfRangeException.ThrowIfNegative(sizeExponent);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(sizeExponent, 6);
        Number = number;
        More = more;
        SizeExponent = sizeExponent;
    }

    /// <summary>The block number, counted from zero.</summary>
    public int Number { get; }

    /// <summary>True when more blocks follow this one.</summary>
    public bool More { get; }

    /// <summary>The size exponent, 0 to 6.</summary>
    public int SizeExponent { get; }

    /// <summary>The block size in bytes, 16 to 1024.</summary>
    public int Size => SizeOf(SizeExponent);

    /// <summary>The byte offset of this block in the whole body.</summary>
    public long Offset => (long)Number * Size;

    /// <summary>The block size in bytes for a size exponent.</summary>
    /// <param name="sizeExponent">The size exponent, 0 to 6.</param>
    /// <returns>The size, <c>2^(SZX + 4)</c>.</returns>
    /// <exception cref="ArgumentOutOfRangeException">The exponent is not 0 to 6.</exception>
    public static int SizeOf(int sizeExponent)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(sizeExponent);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(sizeExponent, 6);
        return 1 << (sizeExponent + 4);
    }

    /// <summary>The size exponent for a block size.</summary>
    /// <param name="size">A power of two from 16 to 1024.</param>
    /// <returns>The size exponent.</returns>
    /// <exception cref="ArgumentOutOfRangeException">The size is not a valid block size.</exception>
    public static int ExponentOf(int size)
    {
        for (int szx = 0; szx <= 6; szx++)
            if (SizeOf(szx) == size) return szx;
        throw new ArgumentOutOfRangeException(nameof(size), size, "Block size must be a power of two from 16 to 1024.");
    }

    /// <summary>Encodes the value in the shortest form that holds the block number. Zero encodes as an empty value.</summary>
    /// <returns>Zero to three bytes.</returns>
    public byte[] Encode() => CoapOption.EncodeUInt(((uint)Number << 4) | (More ? 0x08u : 0u) | (uint)SizeExponent);

    /// <summary>Decodes a block value.</summary>
    /// <param name="value">Zero to three bytes. An empty value is block 0, no more, SZX 0.</param>
    /// <param name="block">The decoded value when successful.</param>
    /// <returns>False when the value is longer than three bytes or uses the reserved SZX 7.</returns>
    public static bool TryDecode(ReadOnlySpan<byte> value, out BlockOption block)
    {
        block = default;
        if (value.Length > 3) return false;
        uint raw = 0;
        foreach (var b in value) raw = (raw << 8) | b;
        int szx = (int)(raw & 0x07);
        if (szx == 7) return false;
        block = new BlockOption((int)(raw >> 4), (raw & 0x08) != 0, szx);
        return true;
    }

    /// <summary>Formats the value as <c>NUM/M/SIZE</c>, the notation RFC 7959 uses.</summary>
    /// <returns>The formatted value.</returns>
    public override string ToString() => $"{Number}/{(More ? 1 : 0)}/{Size}";
}

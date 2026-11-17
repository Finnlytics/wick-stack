namespace Wick.Coap;

/// <summary>
/// Splits a body into blocks for a block-wise transfer (RFC 7959 section 2). It only does
/// the chunking; whether the blocks travel in requests (Block1) or responses (Block2) is up
/// to the caller. The block size may change between blocks, as RFC 7959 section 2.5 allows
/// when the peer asks for smaller blocks.
/// </summary>
public sealed class BlockSender
{
    private readonly ReadOnlyMemory<byte> _body;

    /// <summary>Creates a sender.</summary>
    /// <param name="body">The whole body.</param>
    /// <param name="sizeExponent">The size exponent, 0 to 6. Default 6 (1024 bytes).</param>
    public BlockSender(ReadOnlyMemory<byte> body, int sizeExponent = 6)
    {
        _body = body;
        SizeExponent = sizeExponent;
        _ = BlockOption.SizeOf(sizeExponent);
    }

    /// <summary>The current size exponent.</summary>
    public int SizeExponent { get; private set; }

    /// <summary>The current block size in bytes.</summary>
    public int BlockSize => BlockOption.SizeOf(SizeExponent);

    /// <summary>The current block number at the current size.</summary>
    public int Number { get; private set; }

    /// <summary>The number of blocks at the current size. An empty body is one block.</summary>
    public int TotalBlocks => Math.Max(1, (int)((_body.Length + BlockSize - 1) / BlockSize));

    /// <summary>True when the current block is not the last.</summary>
    public bool More => (long)(Number + 1) * BlockSize < _body.Length;

    /// <summary>The current block and the option value describing it.</summary>
    /// <returns>The chunk and its block option.</returns>
    public (ReadOnlyMemory<byte> Chunk, BlockOption Block) Current() => Slice(_body, Number, SizeExponent);

    /// <summary>Moves to the next block.</summary>
    /// <returns>False when the current block is already the last.</returns>
    public bool Advance()
    {
        if (!More) return false;
        Number++;
        return true;
    }

    /// <summary>
    /// Moves to the block after the current one once the peer has acknowledged it, switching
    /// to the peer's size exponent if it is smaller. As in RFC 7959 section 2.5 (figure 4),
    /// the next block starts where the one just sent ended, renumbered for the new size.
    /// </summary>
    /// <param name="acknowledged">The block option the peer echoed.</param>
    /// <returns>False when the block just sent was the last.</returns>
    public bool AdvanceAfter(BlockOption acknowledged)
    {
        long nextOffset = (long)(Number + 1) * BlockSize;
        if (nextOffset >= _body.Length) return false;
        SizeExponent = Math.Min(acknowledged.SizeExponent, SizeExponent);
        Number = (int)(nextOffset / BlockSize);
        return true;
    }

    /// <summary>Returns block <paramref name="number"/> of <paramref name="body"/> at a size.</summary>
    /// <param name="body">The whole body.</param>
    /// <param name="number">The block number.</param>
    /// <param name="sizeExponent">The size exponent.</param>
    /// <returns>The chunk, empty past the end, and its block option.</returns>
    public static (ReadOnlyMemory<byte> Chunk, BlockOption Block) Slice(ReadOnlyMemory<byte> body, int number, int sizeExponent)
    {
        int size = BlockOption.SizeOf(sizeExponent);
        long offset = (long)number * size;
        ReadOnlyMemory<byte> chunk = offset >= body.Length
            ? ReadOnlyMemory<byte>.Empty
            : body.Slice((int)offset, (int)Math.Min(size, body.Length - offset));
        bool more = offset + size < body.Length;
        return (chunk, new BlockOption(number, more, sizeExponent));
    }
}

/// <summary>The outcome of adding a block to a <see cref="BlockReceiver"/>.</summary>
public enum BlockReceiveStatus
{
    /// <summary>The block was accepted and more are expected.</summary>
    Continue,

    /// <summary>The final block arrived and the body is complete.</summary>
    Complete,

    /// <summary>The block repeats one already received; nothing changed.</summary>
    Duplicate,

    /// <summary>The block does not start where the previous one ended.</summary>
    OutOfOrder,

    /// <summary>A block other than the last is not exactly the block size.</summary>
    WrongSize,

    /// <summary>The body would exceed the configured maximum.</summary>
    TooLarge,
}

/// <summary>
/// Reassembles a body from blocks (RFC 7959 section 2). Blocks must arrive in order, which
/// is what RFC 7959 section 2.3 lets a server require; a block may use a smaller size than
/// the previous one as long as it starts where that one ended. The body is capped.
/// </summary>
public sealed class BlockReceiver
{
    private readonly int _maxBodySize;
    private byte[] _buffer = [];
    private int _length;

    /// <summary>Creates a receiver.</summary>
    /// <param name="maxBodySize">The largest body accepted, in bytes.</param>
    public BlockReceiver(int maxBodySize = 1 << 20)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maxBodySize, 0);
        _maxBodySize = maxBodySize;
    }

    /// <summary>Bytes received so far.</summary>
    public int Length => _length;

    /// <summary>True once the final block has been received.</summary>
    public bool IsComplete { get; private set; }

    /// <summary>The size exponent of the last accepted block, or null before the first.</summary>
    public int? SizeExponent { get; private set; }

    /// <summary>The body received so far.</summary>
    public ReadOnlyMemory<byte> Body => _buffer.AsMemory(0, _length);

    /// <summary>Adds a block.</summary>
    /// <param name="block">The block option.</param>
    /// <param name="chunk">The block payload.</param>
    /// <returns>What happened.</returns>
    public BlockReceiveStatus Add(BlockOption block, ReadOnlySpan<byte> chunk)
    {
        long offset = block.Offset;
        if (offset < _length)
        {
            // A block wholly inside what we already have is a repeat.
            return offset + chunk.Length <= _length ? BlockReceiveStatus.Duplicate : BlockReceiveStatus.OutOfOrder;
        }
        if (IsComplete || offset != _length) return BlockReceiveStatus.OutOfOrder;
        if (block.More && chunk.Length != block.Size) return BlockReceiveStatus.WrongSize;
        if (!block.More && chunk.Length > block.Size) return BlockReceiveStatus.WrongSize;
        if ((long)_length + chunk.Length > _maxBodySize) return BlockReceiveStatus.TooLarge;

        EnsureCapacity(_length + chunk.Length);
        chunk.CopyTo(_buffer.AsSpan(_length));
        _length += chunk.Length;
        SizeExponent = block.SizeExponent;
        if (!block.More)
        {
            IsComplete = true;
            return BlockReceiveStatus.Complete;
        }
        return BlockReceiveStatus.Continue;
    }

    private void EnsureCapacity(int needed)
    {
        if (_buffer.Length >= needed) return;
        int size = Math.Max(needed, Math.Min(_maxBodySize, Math.Max(256, _buffer.Length * 2)));
        Array.Resize(ref _buffer, size);
    }
}

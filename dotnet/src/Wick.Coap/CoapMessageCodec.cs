using System.Buffers.Binary;

namespace Wick.Coap;

/// <summary>Why a datagram could not be decoded as a CoAP message.</summary>
public enum CoapDecodeError
{
    /// <summary>The message decoded without error.</summary>
    None = 0,

    /// <summary>Fewer than the four header bytes are present.</summary>
    TruncatedHeader,

    /// <summary>The version field is not 1. RFC 7252 section 3 says such messages are silently ignored.</summary>
    UnsupportedVersion,

    /// <summary>The token length is 9 to 15, which RFC 7252 section 3 reserves.</summary>
    ReservedTokenLength,

    /// <summary>The datagram ends inside the token.</summary>
    TruncatedToken,

    /// <summary>The datagram ends inside an option header, extension or value.</summary>
    TruncatedOption,

    /// <summary>An option delta or length nibble is 15 outside the payload marker.</summary>
    ReservedOptionNibble,

    /// <summary>An option number exceeds 65535 after applying the delta.</summary>
    OptionNumberOutOfRange,

    /// <summary>A payload marker is followed by no payload (RFC 7252 section 3).</summary>
    EmptyPayloadAfterMarker,

    /// <summary>An empty message (code 0.00) carries a token, options or payload (RFC 7252 section 4.1).</summary>
    MalformedEmptyMessage,
}

/// <summary>Raised when a message cannot be encoded or decoded.</summary>
public sealed class CoapFormatException : FormatException
{
    /// <summary>Creates the exception.</summary>
    /// <param name="error">The decode error, or <see cref="CoapDecodeError.None"/> for an encoding problem.</param>
    /// <param name="message">A description of the problem.</param>
    public CoapFormatException(CoapDecodeError error, string message) : base(message) => Error = error;

    /// <summary>The decode error, or <see cref="CoapDecodeError.None"/> when encoding failed.</summary>
    public CoapDecodeError Error { get; }
}

/// <summary>
/// The CoAP wire format (RFC 7252 section 3): a four-byte header, a token of up to eight
/// bytes, delta-encoded options and an optional payload behind a 0xFF marker.
/// The codec is pure: no state, no I/O.
/// </summary>
public static class CoapMessageCodec
{
    /// <summary>The largest option delta or length the extended encodings can carry: 65535 plus 269.</summary>
    internal const int MaxExtendedValue = 65535 + 269;

    /// <summary>Encodes a message. Options are written in ascending number order; options with the same number keep their relative order.</summary>
    /// <param name="message">The message to encode.</param>
    /// <returns>The datagram bytes.</returns>
    /// <exception cref="CoapFormatException">The token is longer than eight bytes, or an option value is too long to encode.</exception>
    public static byte[] Encode(CoapMessage message)
    {
        ArgumentNullException.ThrowIfNull(message);
        var token = message.Token;
        if (token.Length > 8)
            throw new CoapFormatException(CoapDecodeError.None, $"Token is {token.Length} bytes; RFC 7252 allows at most 8.");

        var options = SortedOptions(message.Options);
        int size = 4 + token.Length;
        int previous = 0;
        foreach (var option in options)
        {
            if (option.Length > MaxExtendedValue)
                throw new CoapFormatException(CoapDecodeError.None, $"Option {option.Number} value is {option.Length} bytes; the most CoAP can encode is {MaxExtendedValue}.");
            size += 1 + ExtensionSize(option.Number - previous) + ExtensionSize(option.Length) + option.Length;
            previous = option.Number;
        }
        if (!message.Payload.IsEmpty) size += 1 + message.Payload.Length;

        var buffer = new byte[size];
        buffer[0] = (byte)(0x40 | ((int)message.Type << 4) | token.Length);
        buffer[1] = message.Code.Value;
        BinaryPrimitives.WriteUInt16BigEndian(buffer.AsSpan(2), message.MessageId);
        token.CopyTo(buffer.AsSpan(4));
        int offset = 4 + token.Length;

        previous = 0;
        foreach (var option in options)
        {
            int delta = option.Number - previous;
            int length = option.Length;
            int head = offset++;
            buffer[head] = (byte)((Nibble(delta) << 4) | Nibble(length));
            offset = WriteExtension(buffer, offset, delta);
            offset = WriteExtension(buffer, offset, length);
            option.Value.Span.CopyTo(buffer.AsSpan(offset));
            offset += length;
            previous = option.Number;
        }

        if (!message.Payload.IsEmpty)
        {
            buffer[offset++] = 0xFF;
            message.Payload.Span.CopyTo(buffer.AsSpan(offset));
        }

        return buffer;
    }

    /// <summary>Decodes a datagram.</summary>
    /// <param name="datagram">The datagram bytes.</param>
    /// <returns>The decoded message.</returns>
    /// <exception cref="CoapFormatException">The datagram is not a well-formed CoAP message.</exception>
    public static CoapMessage Decode(ReadOnlySpan<byte> datagram)
    {
        if (TryDecode(datagram, out var message, out var error)) return message;
        throw new CoapFormatException(error, $"Malformed CoAP message: {error}.");
    }

    /// <summary>Decodes a datagram without throwing.</summary>
    /// <param name="datagram">The datagram bytes.</param>
    /// <param name="message">The decoded message when successful.</param>
    /// <param name="error">Why decoding failed, or <see cref="CoapDecodeError.None"/>.</param>
    /// <returns>True when the datagram is a well-formed message.</returns>
    public static bool TryDecode(ReadOnlySpan<byte> datagram, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out CoapMessage? message, out CoapDecodeError error)
    {
        message = null;
        if (datagram.Length < 4) { error = CoapDecodeError.TruncatedHeader; return false; }

        int version = datagram[0] >> 6;
        if (version != 1) { error = CoapDecodeError.UnsupportedVersion; return false; }

        var type = (CoapMessageType)((datagram[0] >> 4) & 0x03);
        int tokenLength = datagram[0] & 0x0F;
        if (tokenLength > 8) { error = CoapDecodeError.ReservedTokenLength; return false; }

        var code = new CoapCode(datagram[1]);
        ushort messageId = BinaryPrimitives.ReadUInt16BigEndian(datagram[2..]);

        if (code.IsEmpty && (tokenLength != 0 || datagram.Length != 4))
        {
            error = CoapDecodeError.MalformedEmptyMessage;
            return false;
        }

        if (datagram.Length < 4 + tokenLength) { error = CoapDecodeError.TruncatedToken; return false; }
        byte[] token = datagram.Slice(4, tokenLength).ToArray();

        var options = new List<CoapOption>();
        int offset = 4 + tokenLength;
        int number = 0;
        ReadOnlyMemory<byte> payload = ReadOnlyMemory<byte>.Empty;

        while (offset < datagram.Length)
        {
            byte head = datagram[offset++];
            if (head == 0xFF)
            {
                if (offset == datagram.Length) { error = CoapDecodeError.EmptyPayloadAfterMarker; return false; }
                payload = datagram[offset..].ToArray();
                break;
            }

            int deltaNibble = head >> 4;
            int lengthNibble = head & 0x0F;
            if (deltaNibble == 15 || lengthNibble == 15) { error = CoapDecodeError.ReservedOptionNibble; return false; }

            if (!TryReadExtension(datagram, ref offset, deltaNibble, out int delta) ||
                !TryReadExtension(datagram, ref offset, lengthNibble, out int length))
            {
                error = CoapDecodeError.TruncatedOption;
                return false;
            }

            number += delta;
            if (number > 65535) { error = CoapDecodeError.OptionNumberOutOfRange; return false; }
            if (datagram.Length - offset < length) { error = CoapDecodeError.TruncatedOption; return false; }

            options.Add(new CoapOption(number, datagram.Slice(offset, length).ToArray()));
            offset += length;
        }

        message = new CoapMessage(options)
        {
            Type = type,
            Code = code,
            MessageId = messageId,
            Token = token,
            Payload = payload,
        };
        error = CoapDecodeError.None;
        return true;
    }

    /// <summary>
    /// Reads the type and message id from a datagram whose header is intact, even if the rest
    /// is malformed. Used to reject a malformed confirmable message with a matching Reset
    /// (RFC 7252 section 4.2).
    /// </summary>
    /// <param name="datagram">The datagram bytes.</param>
    /// <param name="type">The message type.</param>
    /// <param name="messageId">The message id.</param>
    /// <returns>True when a version 1 header is present.</returns>
    public static bool TryReadHeader(ReadOnlySpan<byte> datagram, out CoapMessageType type, out ushort messageId)
    {
        type = default;
        messageId = 0;
        if (datagram.Length < 4 || datagram[0] >> 6 != 1) return false;
        type = (CoapMessageType)((datagram[0] >> 4) & 0x03);
        messageId = BinaryPrimitives.ReadUInt16BigEndian(datagram[2..]);
        return true;
    }

    private static List<CoapOption> SortedOptions(IReadOnlyList<CoapOption> options)
    {
        var list = new List<CoapOption>(options);
        for (int i = 1; i < list.Count; i++)
        {
            if (list[i].Number < list[i - 1].Number)
            {
                // OrderBy is a stable sort, so repeated options keep their order.
                return [.. list.OrderBy(o => o.Number)];
            }
        }
        return list;
    }

    private static int Nibble(int value) => value <= 12 ? value : value <= 268 ? 13 : 14;

    private static int ExtensionSize(int value) => value <= 12 ? 0 : value <= 268 ? 1 : 2;

    private static int WriteExtension(byte[] buffer, int offset, int value)
    {
        if (value <= 12) return offset;
        if (value <= 268)
        {
            buffer[offset] = (byte)(value - 13);
            return offset + 1;
        }
        BinaryPrimitives.WriteUInt16BigEndian(buffer.AsSpan(offset), (ushort)(value - 269));
        return offset + 2;
    }

    private static bool TryReadExtension(ReadOnlySpan<byte> datagram, ref int offset, int nibble, out int value)
    {
        switch (nibble)
        {
            case <= 12:
                value = nibble;
                return true;
            case 13:
                if (offset + 1 > datagram.Length) { value = 0; return false; }
                value = datagram[offset] + 13;
                offset += 1;
                return true;
            default:
                if (offset + 2 > datagram.Length) { value = 0; return false; }
                value = BinaryPrimitives.ReadUInt16BigEndian(datagram[offset..]) + 269;
                offset += 2;
                return true;
        }
    }
}

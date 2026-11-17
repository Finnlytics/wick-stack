using System.Text;

namespace Wick.Coap;

/// <summary>
/// A CoAP message (RFC 7252 section 3): type, code, message id, token, options and payload.
/// The same type carries requests, responses and empty messages. It is a plain mutable
/// value holder; the endpoint fills in the message id and token on outbound messages.
/// </summary>
public sealed class CoapMessage
{
    private byte[] _token = [];

    /// <summary>Creates an empty confirmable message with code 0.00.</summary>
    public CoapMessage() => Options = [];

    internal CoapMessage(List<CoapOption> options) => Options = options;

    /// <summary>The message type.</summary>
    public CoapMessageType Type { get; set; } = CoapMessageType.Confirmable;

    /// <summary>The method or response code.</summary>
    public CoapCode Code { get; set; }

    /// <summary>The 16-bit message id used for deduplication and for matching acknowledgements.</summary>
    public ushort MessageId { get; set; }

    /// <summary>The token, 0 to 8 bytes, used to match responses to requests.</summary>
    /// <exception cref="ArgumentException">The token is longer than 8 bytes.</exception>
    public byte[] Token
    {
        get => _token;
        set
        {
            ArgumentNullException.ThrowIfNull(value);
            if (value.Length > 8) throw new ArgumentException("A CoAP token is at most 8 bytes.", nameof(value));
            _token = value;
        }
    }

    /// <summary>The options in the order they were added. Encoding sorts them by number.</summary>
    public List<CoapOption> Options { get; }

    /// <summary>The payload. Empty when the message has none.</summary>
    public ReadOnlyMemory<byte> Payload { get; set; }

    /// <summary>True when the code is a request method.</summary>
    public bool IsRequest => Code.IsRequest;

    /// <summary>True when the code is a response code.</summary>
    public bool IsResponse => Code.IsResponse;

    /// <summary>True for an empty message, code 0.00.</summary>
    public bool IsEmpty => Code.IsEmpty;

    /// <summary>Creates a request.</summary>
    /// <param name="method">The method code.</param>
    /// <param name="path">An optional path such as <c>/rd/abc</c>; each segment becomes a Uri-Path option.</param>
    /// <param name="type">Confirmable (the default) or non-confirmable.</param>
    /// <returns>The request.</returns>
    public static CoapMessage CreateRequest(CoapCode method, string? path = null, CoapMessageType type = CoapMessageType.Confirmable)
    {
        if (!method.IsRequest) throw new ArgumentException($"{method} is not a request method.", nameof(method));
        var message = new CoapMessage { Type = type, Code = method };
        if (path is not null) message.SetUriPath(path);
        return message;
    }

    /// <summary>Creates a response with a code and optional payload. The endpoint sets type, message id and token.</summary>
    /// <param name="code">The response code.</param>
    /// <param name="payload">An optional payload.</param>
    /// <param name="contentFormat">An optional Content-Format for the payload.</param>
    /// <returns>The response.</returns>
    public static CoapMessage CreateResponse(CoapCode code, ReadOnlyMemory<byte> payload = default, int? contentFormat = null)
    {
        if (!code.IsResponse) throw new ArgumentException($"{code} is not a response code.", nameof(code));
        var message = new CoapMessage { Code = code, Payload = payload };
        if (contentFormat is int format) message.ContentFormat = format;
        return message;
    }

    /// <summary>Returns a copy whose option list and token are independent of this one. The payload memory is shared.</summary>
    /// <returns>The copy.</returns>
    public CoapMessage Clone() => new([.. Options])
    {
        Type = Type,
        Code = Code,
        MessageId = MessageId,
        Token = (byte[])Token.Clone(),
        Payload = Payload,
    };

    /// <summary>Encodes the message to its wire form.</summary>
    /// <returns>The datagram bytes.</returns>
    public byte[] Encode() => CoapMessageCodec.Encode(this);

    /// <summary>Decodes a datagram.</summary>
    /// <param name="datagram">The datagram bytes.</param>
    /// <returns>The message.</returns>
    /// <exception cref="CoapFormatException">The datagram is malformed.</exception>
    public static CoapMessage Decode(ReadOnlySpan<byte> datagram) => CoapMessageCodec.Decode(datagram);

    /// <summary>Returns the first option with a number, if any.</summary>
    /// <param name="number">The option number.</param>
    /// <returns>The option, or null.</returns>
    public CoapOption? GetOption(int number)
    {
        foreach (var option in Options)
            if (option.Number == number) return option;
        return null;
    }

    /// <summary>Returns every option with a number, in order.</summary>
    /// <param name="number">The option number.</param>
    /// <returns>The matching options.</returns>
    public IEnumerable<CoapOption> GetOptions(int number) => Options.Where(o => o.Number == number);

    /// <summary>True when at least one option with the number is present.</summary>
    /// <param name="number">The option number.</param>
    /// <returns>True when present.</returns>
    public bool HasOption(int number) => Options.Exists(o => o.Number == number);

    /// <summary>Removes every option with a number.</summary>
    /// <param name="number">The option number.</param>
    /// <returns>The message, for chaining.</returns>
    public CoapMessage RemoveOptions(int number)
    {
        Options.RemoveAll(o => o.Number == number);
        return this;
    }

    /// <summary>Adds an option, keeping any existing ones with the same number.</summary>
    /// <param name="option">The option.</param>
    /// <returns>The message, for chaining.</returns>
    public CoapMessage AddOption(CoapOption option)
    {
        Options.Add(option);
        return this;
    }

    /// <summary>Replaces every option with the option's number by this one.</summary>
    /// <param name="option">The option.</param>
    /// <returns>The message, for chaining.</returns>
    public CoapMessage SetOption(CoapOption option)
    {
        RemoveOptions(option.Number);
        Options.Add(option);
        return this;
    }

    /// <summary>The Uri-Path segments, in order.</summary>
    public IReadOnlyList<string> UriPath => StringOptions(CoapOptionNumber.UriPath);

    /// <summary>The Uri-Query arguments, in order, for example <c>ep=device1</c>.</summary>
    public IReadOnlyList<string> UriQuery => StringOptions(CoapOptionNumber.UriQuery);

    /// <summary>The Location-Path segments, in order.</summary>
    public IReadOnlyList<string> LocationPath => StringOptions(CoapOptionNumber.LocationPath);

    /// <summary>The Location-Query arguments, in order.</summary>
    public IReadOnlyList<string> LocationQuery => StringOptions(CoapOptionNumber.LocationQuery);

    /// <summary>The Uri-Path joined with slashes and a leading slash, for example <c>/rd/abc</c>.</summary>
    public string UriPathString => "/" + string.Join('/', UriPath);

    /// <summary>Replaces the Uri-Path options with the segments of a slash-separated path.</summary>
    /// <param name="path">A path such as <c>/3/0/1</c>. Empty segments are dropped; <c>/</c> means no segments.</param>
    /// <returns>The message, for chaining.</returns>
    public CoapMessage SetUriPath(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        RemoveOptions(CoapOptionNumber.UriPath);
        foreach (var segment in path.Split('/', StringSplitOptions.RemoveEmptyEntries))
            Options.Add(CoapOption.FromString(CoapOptionNumber.UriPath, segment));
        return this;
    }

    /// <summary>Replaces the Uri-Path options with the given segments.</summary>
    /// <param name="segments">The segments, which may contain slashes.</param>
    /// <returns>The message, for chaining.</returns>
    public CoapMessage SetUriPath(IEnumerable<string> segments)
    {
        RemoveOptions(CoapOptionNumber.UriPath);
        foreach (var segment in segments)
            Options.Add(CoapOption.FromString(CoapOptionNumber.UriPath, segment));
        return this;
    }

    /// <summary>Adds one Uri-Query argument.</summary>
    /// <param name="argument">The argument, for example <c>lt=300</c>.</param>
    /// <returns>The message, for chaining.</returns>
    public CoapMessage AddUriQuery(string argument)
    {
        Options.Add(CoapOption.FromString(CoapOptionNumber.UriQuery, argument));
        return this;
    }

    /// <summary>Replaces the Location-Path options with the given segments.</summary>
    /// <param name="segments">The segments.</param>
    /// <returns>The message, for chaining.</returns>
    public CoapMessage SetLocationPath(IEnumerable<string> segments)
    {
        RemoveOptions(CoapOptionNumber.LocationPath);
        foreach (var segment in segments)
            Options.Add(CoapOption.FromString(CoapOptionNumber.LocationPath, segment));
        return this;
    }

    /// <summary>The Content-Format, or null when absent.</summary>
    public int? ContentFormat
    {
        get => UIntOption(CoapOptionNumber.ContentFormat) is uint v ? (int)v : null;
        set => SetUIntOption(CoapOptionNumber.ContentFormat, value is int v ? (uint)v : null);
    }

    /// <summary>The Accept option, or null when absent.</summary>
    public int? Accept
    {
        get => UIntOption(CoapOptionNumber.Accept) is uint v ? (int)v : null;
        set => SetUIntOption(CoapOptionNumber.Accept, value is int v ? (uint)v : null);
    }

    /// <summary>The Observe option value, or null when absent (RFC 7641 section 2).</summary>
    public uint? Observe
    {
        get => UIntOption(CoapOptionNumber.Observe);
        set => SetUIntOption(CoapOptionNumber.Observe, value);
    }

    /// <summary>The Max-Age in seconds, or null when absent (the RFC default is then 60).</summary>
    public uint? MaxAge
    {
        get => UIntOption(CoapOptionNumber.MaxAge);
        set => SetUIntOption(CoapOptionNumber.MaxAge, value);
    }

    /// <summary>The Size1 option, or null when absent.</summary>
    public uint? Size1
    {
        get => UIntOption(CoapOptionNumber.Size1);
        set => SetUIntOption(CoapOptionNumber.Size1, value);
    }

    /// <summary>The Size2 option, or null when absent.</summary>
    public uint? Size2
    {
        get => UIntOption(CoapOptionNumber.Size2);
        set => SetUIntOption(CoapOptionNumber.Size2, value);
    }

    /// <summary>The first ETag, or null when absent.</summary>
    public byte[]? ETag
    {
        get => GetOption(CoapOptionNumber.ETag) is CoapOption o ? o.Value.ToArray() : null;
        set
        {
            RemoveOptions(CoapOptionNumber.ETag);
            if (value is not null) Options.Add(new CoapOption(CoapOptionNumber.ETag, value));
        }
    }

    /// <summary>The Block1 option, or null when absent or malformed.</summary>
    public BlockOption? Block1
    {
        get => BlockValue(CoapOptionNumber.Block1);
        set => SetBlock(CoapOptionNumber.Block1, value);
    }

    /// <summary>The Block2 option, or null when absent or malformed.</summary>
    public BlockOption? Block2
    {
        get => BlockValue(CoapOptionNumber.Block2);
        set => SetBlock(CoapOptionNumber.Block2, value);
    }

    /// <summary>The payload decoded as UTF-8.</summary>
    /// <returns>The payload text.</returns>
    public string PayloadAsString() => Encoding.UTF8.GetString(Payload.Span);

    /// <summary>Formats the message for diagnostics.</summary>
    /// <returns>A one-line summary.</returns>
    public override string ToString()
    {
        var builder = new StringBuilder();
        builder.Append(Type switch
        {
            CoapMessageType.Confirmable => "CON",
            CoapMessageType.NonConfirmable => "NON",
            CoapMessageType.Acknowledgement => "ACK",
            _ => "RST",
        });
        builder.Append(' ').Append(Code).Append(" mid=").Append(MessageId);
        if (Token.Length > 0) builder.Append(" token=").Append(Convert.ToHexString(Token));
        foreach (var option in Options) builder.Append(" [").Append(option).Append(']');
        if (!Payload.IsEmpty) builder.Append(" payload=").Append(Payload.Length).Append(" bytes");
        return builder.ToString();
    }

    private List<string> StringOptions(int number)
    {
        var list = new List<string>();
        foreach (var option in Options)
            if (option.Number == number) list.Add(option.GetString());
        return list;
    }

    private uint? UIntOption(int number)
    {
        var option = GetOption(number);
        if (option is not CoapOption o || o.Length > 4) return null;
        return o.GetUInt();
    }

    private void SetUIntOption(int number, uint? value)
    {
        RemoveOptions(number);
        if (value is uint v) Options.Add(CoapOption.FromUInt(number, v));
    }

    private BlockOption? BlockValue(int number)
    {
        var option = GetOption(number);
        if (option is not CoapOption o) return null;
        return BlockOption.TryDecode(o.Value.Span, out var block) ? block : null;
    }

    private void SetBlock(int number, BlockOption? value)
    {
        RemoveOptions(number);
        if (value is BlockOption block) Options.Add(new CoapOption(number, block.Encode()));
    }
}

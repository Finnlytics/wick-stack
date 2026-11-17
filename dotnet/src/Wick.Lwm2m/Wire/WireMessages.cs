using System.Buffers.Binary;
using System.Collections.Immutable;
using System.Text;

namespace Wick.Lwm2m.Wire;

/// <summary>One Uri-Query parameter: <c>key=value</c>, or a bare <c>key</c> when <see cref="Value"/> is <see langword="null"/>.</summary>
/// <param name="Key">The key.</param>
/// <param name="Value">The value, or <see langword="null"/> for a bare flag such as <c>Q</c>.</param>
public sealed record QueryParameter(string Key, string? Value)
{
    /// <summary>Parses one Uri-Query option value, splitting at the first <c>=</c>.</summary>
    /// <param name="text">The option value, such as <c>ep=device-1</c> or <c>Q</c>.</param>
    /// <returns>The parameter.</returns>
    public static QueryParameter Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var equals = text.IndexOf('=');
        return equals < 0 ? new QueryParameter(text, null) : new QueryParameter(text[..equals], text[(equals + 1)..]);
    }

    /// <summary>The Uri-Query option value: <c>key=value</c>, or <c>key</c> for a flag.</summary>
    /// <returns>The text.</returns>
    public override string ToString() => Value is null ? Key : $"{Key}={Value}";
}

/// <summary>
/// A request in transport-neutral form: what a CoAP layer sends or received, without any CoAP library types.
/// </summary>
/// <remarks>
/// <para>
/// Wick builds these for server-to-client operations and parses them for client-to-server ones.
/// A CoAP adapter maps <see cref="Method"/> to the request code, each <see cref="Path"/> segment to a
/// Uri-Path option (11), each <see cref="Query"/> parameter to a Uri-Query option (15),
/// <see cref="ContentFormat"/> to option 12, <see cref="Accept"/> to option 17, <see cref="Observe"/>
/// to option 6, and carries <see cref="Token"/> and <see cref="Payload"/> as they are.
/// <see cref="CoapOptions"/> does the option mapping in both directions.
/// </para>
/// <para>
/// An empty token means "let the transport choose". For Observe the caller should set one, since
/// the token is what correlates later notifications with the relation.
/// </para>
/// </remarks>
public sealed record WireRequest
{
    private readonly ImmutableArray<string> _path = [];
    private readonly ImmutableArray<QueryParameter> _query = [];
    private readonly ReadOnlyMemory<byte> _payload = ReadOnlyMemory<byte>.Empty;
    private readonly ReadOnlyMemory<byte> _token = ReadOnlyMemory<byte>.Empty;

    /// <summary>Creates a request.</summary>
    /// <param name="method">The request method.</param>
    public WireRequest(Method method)
    {
        Method = method;
    }

    /// <summary>The request method.</summary>
    public Method Method { get; init; }

    /// <summary>The Uri-Path segments, in order. Empty for the LwM2M root.</summary>
    public IReadOnlyList<string> Path
    {
        get => _path;
        init => _path = value?.ToImmutableArray() ?? throw new ArgumentNullException(nameof(value));
    }

    /// <summary>The Uri-Query parameters, in order.</summary>
    public IReadOnlyList<QueryParameter> Query
    {
        get => _query;
        init => _query = value?.ToImmutableArray() ?? throw new ArgumentNullException(nameof(value));
    }

    /// <summary>The Content-Format of the payload, or <see langword="null"/> when there is none.</summary>
    public int? ContentFormat { get; init; }

    /// <summary>The Accept option: the Content-Format wanted in the response, or <see langword="null"/>.</summary>
    public int? Accept { get; init; }

    /// <summary>The Observe option: 0 registers, 1 deregisters, <see langword="null"/> omits it.</summary>
    public uint? Observe { get; init; }

    /// <summary>The payload. Bytes are copied on assignment.</summary>
    public ReadOnlyMemory<byte> Payload
    {
        get => _payload;
        init => _payload = value.ToArray();
    }

    /// <summary>The CoAP token, up to 8 bytes. Empty lets the transport choose. Bytes are copied on assignment.</summary>
    public ReadOnlyMemory<byte> Token
    {
        get => _token;
        init => _token = value.Length <= 8 ? value.ToArray() : throw new ArgumentException("a CoAP token is at most 8 bytes", nameof(value));
    }

    /// <summary>The value of the first query parameter called <paramref name="key"/>.</summary>
    /// <param name="key">The key.</param>
    /// <param name="value">The value, <see langword="null"/> for a bare flag.</param>
    /// <returns>Whether the parameter is present.</returns>
    public bool TryGetQuery(string key, out string? value)
    {
        foreach (var parameter in _query)
        {
            if (parameter.Key == key)
            {
                value = parameter.Value;
                return true;
            }
        }

        value = null;
        return false;
    }

    /// <inheritdoc/>
    public bool Equals(WireRequest? other) =>
        other is not null && Method == other.Method && _path.SequenceEqual(other._path) && _query.SequenceEqual(other._query) &&
        ContentFormat == other.ContentFormat && Accept == other.Accept && Observe == other.Observe &&
        _payload.Span.SequenceEqual(other._payload.Span) && _token.Span.SequenceEqual(other._token.Span);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Method, _path.Length, _query.Length, ContentFormat, Accept, Observe, _payload.Length);

    /// <summary>A readable rendering such as <c>GET /3/0/9 accept=112</c>.</summary>
    /// <returns>The rendering.</returns>
    public override string ToString()
    {
        var builder = new StringBuilder().Append(Method.ToString().ToUpperInvariant()).Append(" /").AppendJoin('/', _path);
        if (_query.Length > 0)
        {
            builder.Append('?').AppendJoin('&', _query);
        }

        if (ContentFormat is { } cf)
        {
            builder.Append(" cf=").Append(cf);
        }

        if (Accept is { } accept)
        {
            builder.Append(" accept=").Append(accept);
        }

        if (Observe is { } observe)
        {
            builder.Append(" observe=").Append(observe);
        }

        if (_payload.Length > 0)
        {
            builder.Append(" payload=").Append(_payload.Length).Append('B');
        }

        return builder.ToString();
    }
}

/// <summary>
/// A response in transport-neutral form, the counterpart of <see cref="WireRequest"/>.
/// </summary>
/// <remarks>
/// A CoAP adapter maps <see cref="Code"/> to the response code, each <see cref="LocationPath"/>
/// segment to a Location-Path option (8), <see cref="ContentFormat"/> to option 12 and
/// <see cref="Observe"/> to option 6. A notification is a response whose <see cref="Observe"/> is set.
/// </remarks>
public sealed record WireResponse
{
    private readonly ImmutableArray<string> _locationPath = [];
    private readonly ReadOnlyMemory<byte> _payload = ReadOnlyMemory<byte>.Empty;
    private readonly ReadOnlyMemory<byte> _token = ReadOnlyMemory<byte>.Empty;

    /// <summary>Creates a response.</summary>
    /// <param name="code">The response code.</param>
    public WireResponse(ResponseCode code)
    {
        Code = code;
    }

    /// <summary>The response code.</summary>
    public ResponseCode Code { get; init; }

    /// <summary>The Location-Path segments, such as <c>["rd", "a1b2"]</c> for a Register or <c>["3303", "1"]</c> for a Create.</summary>
    public IReadOnlyList<string> LocationPath
    {
        get => _locationPath;
        init => _locationPath = value?.ToImmutableArray() ?? throw new ArgumentNullException(nameof(value));
    }

    /// <summary>The Content-Format of the payload, or <see langword="null"/>.</summary>
    public int? ContentFormat { get; init; }

    /// <summary>The Observe option: the notification sequence number, or <see langword="null"/>.</summary>
    public uint? Observe { get; init; }

    /// <summary>The payload. Bytes are copied on assignment.</summary>
    public ReadOnlyMemory<byte> Payload
    {
        get => _payload;
        init => _payload = value.ToArray();
    }

    /// <summary>The CoAP token, up to 8 bytes. Bytes are copied on assignment.</summary>
    public ReadOnlyMemory<byte> Token
    {
        get => _token;
        init => _token = value.Length <= 8 ? value.ToArray() : throw new ArgumentException("a CoAP token is at most 8 bytes", nameof(value));
    }

    /// <summary>The payload as UTF-8 text, the form CoAP diagnostic payloads on error responses take.</summary>
    public string PayloadText => Encoding.UTF8.GetString(_payload.Span);

    /// <inheritdoc/>
    public bool Equals(WireResponse? other) =>
        other is not null && Code == other.Code && _locationPath.SequenceEqual(other._locationPath) &&
        ContentFormat == other.ContentFormat && Observe == other.Observe &&
        _payload.Span.SequenceEqual(other._payload.Span) && _token.Span.SequenceEqual(other._token.Span);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Code, _locationPath.Length, ContentFormat, Observe, _payload.Length);

    /// <summary>A readable rendering such as <c>2.05 cf=112 payload=13B</c>.</summary>
    /// <returns>The rendering.</returns>
    public override string ToString()
    {
        var builder = new StringBuilder().Append(Code);
        if (_locationPath.Length > 0)
        {
            builder.Append(" location=/").AppendJoin('/', _locationPath);
        }

        if (ContentFormat is { } cf)
        {
            builder.Append(" cf=").Append(cf);
        }

        if (Observe is { } observe)
        {
            builder.Append(" observe=").Append(observe);
        }

        if (_payload.Length > 0)
        {
            builder.Append(" payload=").Append(_payload.Length).Append('B');
        }

        return builder.ToString();
    }
}

/// <summary>A CoAP option as a number and its raw value bytes.</summary>
/// <param name="Number">The option number.</param>
/// <param name="Value">The value bytes.</param>
public readonly record struct CoapOption(int Number, ReadOnlyMemory<byte> Value);

/// <summary>
/// Maps <see cref="WireRequest"/> and <see cref="WireResponse"/> to and from CoAP option numbers,
/// so an adapter to any CoAP library is a loop over options rather than per-operation code.
/// </summary>
public static class CoapOptions
{
    /// <summary>Observe (RFC 7641).</summary>
    public const int Observe = 6;

    /// <summary>Location-Path (RFC 7252).</summary>
    public const int LocationPath = 8;

    /// <summary>Uri-Path (RFC 7252).</summary>
    public const int UriPath = 11;

    /// <summary>Content-Format (RFC 7252).</summary>
    public const int ContentFormat = 12;

    /// <summary>Uri-Query (RFC 7252).</summary>
    public const int UriQuery = 15;

    /// <summary>Accept (RFC 7252).</summary>
    public const int Accept = 17;

    /// <summary>
    /// The request's options in ascending number order, repeated options keeping their relative
    /// order. Unsigned integer options use the shortest big-endian form, so zero is empty.
    /// </summary>
    /// <param name="request">The request.</param>
    /// <returns>The options.</returns>
    public static IReadOnlyList<CoapOption> ToOptions(WireRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var options = new List<CoapOption>();
        if (request.Observe is { } observe)
        {
            options.Add(new CoapOption(Observe, EncodeUInt(observe)));
        }

        options.AddRange(request.Path.Select(s => new CoapOption(UriPath, Encoding.UTF8.GetBytes(s))));
        if (request.ContentFormat is { } cf)
        {
            options.Add(new CoapOption(ContentFormat, EncodeUInt((uint)cf)));
        }

        options.AddRange(request.Query.Select(q => new CoapOption(UriQuery, Encoding.UTF8.GetBytes(q.ToString()))));
        if (request.Accept is { } accept)
        {
            options.Add(new CoapOption(Accept, EncodeUInt((uint)accept)));
        }

        return options;
    }

    /// <summary>The response's options in ascending number order.</summary>
    /// <param name="response">The response.</param>
    /// <returns>The options.</returns>
    public static IReadOnlyList<CoapOption> ToOptions(WireResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        var options = new List<CoapOption>();
        if (response.Observe is { } observe)
        {
            options.Add(new CoapOption(Observe, EncodeUInt(observe)));
        }

        options.AddRange(response.LocationPath.Select(s => new CoapOption(LocationPath, Encoding.UTF8.GetBytes(s))));
        if (response.ContentFormat is { } cf)
        {
            options.Add(new CoapOption(ContentFormat, EncodeUInt((uint)cf)));
        }

        return options;
    }

    /// <summary>Builds a request from a method, CoAP options, payload and token. Options LwM2M does not use are ignored.</summary>
    /// <param name="method">The method.</param>
    /// <param name="options">The options, in any order.</param>
    /// <param name="payload">The payload.</param>
    /// <param name="token">The token.</param>
    /// <returns>The request.</returns>
    public static WireRequest ToRequest(Method method, IEnumerable<CoapOption> options, ReadOnlyMemory<byte> payload = default, ReadOnlyMemory<byte> token = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        var list = options.ToList();
        return new WireRequest(method)
        {
            Path = Strings(list, UriPath),
            Query = Strings(list, UriQuery).Select(QueryParameter.Parse).ToList(),
            ContentFormat = (int?)FirstUInt(list, ContentFormat),
            Accept = (int?)FirstUInt(list, Accept),
            Observe = FirstUInt(list, Observe),
            Payload = payload,
            Token = token,
        };
    }

    /// <summary>Builds a response from a code, CoAP options, payload and token. Options LwM2M does not use are ignored.</summary>
    /// <param name="code">The response code.</param>
    /// <param name="options">The options, in any order.</param>
    /// <param name="payload">The payload.</param>
    /// <param name="token">The token.</param>
    /// <returns>The response.</returns>
    public static WireResponse ToResponse(ResponseCode code, IEnumerable<CoapOption> options, ReadOnlyMemory<byte> payload = default, ReadOnlyMemory<byte> token = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        var list = options.ToList();
        return new WireResponse(code)
        {
            LocationPath = Strings(list, LocationPath),
            ContentFormat = (int?)FirstUInt(list, ContentFormat),
            Observe = FirstUInt(list, Observe),
            Payload = payload,
            Token = token,
        };
    }

    /// <summary>Encodes an unsigned integer option value in the shortest big-endian form; zero is empty.</summary>
    /// <param name="value">The value.</param>
    /// <returns>The bytes.</returns>
    public static byte[] EncodeUInt(uint value)
    {
        var bytes = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(bytes, value);
        int skip = 0;
        while (skip < 4 && bytes[skip] == 0)
        {
            skip++;
        }

        return bytes[skip..];
    }

    /// <summary>Decodes an unsigned integer option value of up to 4 bytes; empty is zero.</summary>
    /// <param name="value">The bytes.</param>
    /// <returns>The value.</returns>
    /// <exception cref="ArgumentException">The value is longer than 4 bytes.</exception>
    public static uint DecodeUInt(ReadOnlySpan<byte> value)
    {
        if (value.Length > 4)
        {
            throw new ArgumentException("an unsigned integer option is at most 4 bytes", nameof(value));
        }

        uint result = 0;
        foreach (var b in value)
        {
            result = (result << 8) | b;
        }

        return result;
    }

    private static List<string> Strings(List<CoapOption> options, int number) =>
        options.Where(o => o.Number == number).Select(o => Encoding.UTF8.GetString(o.Value.Span)).ToList();

    private static uint? FirstUInt(List<CoapOption> options, int number)
    {
        foreach (var option in options)
        {
            if (option.Number == number)
            {
                return DecodeUInt(option.Value.Span);
            }
        }

        return null;
    }
}

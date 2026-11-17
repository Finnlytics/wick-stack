using System.Collections.Immutable;
using System.Text;
using Wick.Lwm2m.Codecs;

namespace Wick.Lwm2m.Links;

/// <summary>One link parameter, such as <c>ct=11543</c> or <c>rt="oma.lwm2m"</c>.</summary>
/// <param name="Name">The parameter name.</param>
/// <param name="Value">The value, or <see langword="null"/> for a bare parameter with no <c>=</c>.</param>
/// <param name="Quoted">Whether the value is written as a quoted string rather than a bare token.</param>
public sealed record LinkParam(string Name, string? Value, bool Quoted)
{
    // Parameters whose RFC 6690 and LwM2M grammar is a quoted string, whatever their content.
    private static readonly ImmutableHashSet<string> QuotedByDefinition =
        ImmutableHashSet.Create(StringComparer.Ordinal, "rt", "if", "title", "anchor", "uri");

    /// <summary>
    /// Creates a parameter, quoting the value when its name is defined as a quoted string
    /// (<c>rt</c>, <c>if</c>, <c>title</c>, <c>anchor</c>, <c>uri</c>) or when it is not a valid bare token.
    /// </summary>
    /// <param name="name">The parameter name.</param>
    /// <param name="value">The value, or <see langword="null"/> for a bare parameter.</param>
    /// <returns>The parameter.</returns>
    public static LinkParam Of(string name, string? value)
    {
        ArgumentNullException.ThrowIfNull(name);
        return new LinkParam(name, value, value is not null && (QuotedByDefinition.Contains(name) || !CoreLinkFormat.IsPToken(value)));
    }
}

/// <summary>
/// One CoRE link (RFC 6690 §2): a target URI reference and its parameters, in order.
/// </summary>
public sealed class Link : IEquatable<Link>
{
    /// <summary>Creates a link.</summary>
    /// <param name="target">The URI reference inside the angle brackets, such as <c>/3/0</c>.</param>
    /// <param name="parameters">The parameters, in the order they are written.</param>
    public Link(string target, IEnumerable<LinkParam> parameters)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(parameters);
        if (target.Contains('>'))
        {
            throw new ArgumentException("a link target cannot contain '>'", nameof(target));
        }

        Target = target;
        Parameters = parameters.ToImmutableArray();
    }

    /// <summary>Creates a link.</summary>
    /// <param name="target">The URI reference.</param>
    /// <param name="parameters">The parameters.</param>
    public Link(string target, params LinkParam[] parameters)
        : this(target, (IEnumerable<LinkParam>)parameters)
    {
    }

    /// <summary>The target URI reference, without the angle brackets.</summary>
    public string Target { get; }

    /// <summary>The parameters, in written order.</summary>
    public IReadOnlyList<LinkParam> Parameters { get; }

    /// <summary>True when the link has a parameter called <paramref name="name"/>.</summary>
    /// <param name="name">The parameter name.</param>
    /// <returns>Whether it is present.</returns>
    public bool Has(string name) => Parameters.Any(p => p.Name == name);

    /// <summary>The value of the first parameter called <paramref name="name"/>.</summary>
    /// <param name="name">The parameter name.</param>
    /// <returns>The value, or <see langword="null"/> when absent or bare.</returns>
    public string? Get(string name) => Parameters.FirstOrDefault(p => p.Name == name)?.Value;

    /// <summary>The target as an LwM2M path, or <see langword="null"/> when it is not one (such as <c>/</c>).</summary>
    public Lwm2mPath? Path => Lwm2mPath.TryParse(Target, out var path) ? path : null;

    /// <inheritdoc/>
    public bool Equals(Link? other) => other is not null && other.Target == Target && other.Parameters.SequenceEqual(Parameters);

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is Link other && Equals(other);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Target, Parameters.Count);

    /// <summary>The link in RFC 6690 form.</summary>
    /// <returns>The text.</returns>
    public override string ToString() => CoreLinkFormat.Format([this]);
}

/// <summary>
/// CoRE Link Format (RFC 6690), Content-Format 40: the payload of Register, Update and Discover.
/// </summary>
/// <remarks>
/// The parser is lenient with whitespace between tokens and accepts a bare parameter with no
/// value, but is strict about the angle-bracketed target and quoted strings. Parameter order is
/// preserved in both directions.
/// </remarks>
public static class CoreLinkFormat
{
    /// <summary>The CoAP Content-Format number for <c>application/link-format</c>.</summary>
    public const int ContentFormat = ContentFormats.LinkFormat;

    /// <summary>Formats links as RFC 6690 text.</summary>
    /// <param name="links">The links.</param>
    /// <returns>The text.</returns>
    public static string Format(IEnumerable<Link> links)
    {
        ArgumentNullException.ThrowIfNull(links);
        var builder = new StringBuilder();
        bool first = true;
        foreach (var link in links)
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            builder.Append('<').Append(link.Target).Append('>');
            foreach (var param in link.Parameters)
            {
                builder.Append(';').Append(param.Name);
                if (param.Value is null)
                {
                    continue;
                }

                builder.Append('=');
                if (param.Quoted)
                {
                    builder.Append('"');
                    foreach (var c in param.Value)
                    {
                        if (c is '"' or '\\')
                        {
                            builder.Append('\\');
                        }

                        builder.Append(c);
                    }

                    builder.Append('"');
                }
                else
                {
                    builder.Append(param.Value);
                }
            }
        }

        return builder.ToString();
    }

    /// <summary>Formats links as UTF-8 bytes, ready for a payload with Content-Format 40.</summary>
    /// <param name="links">The links.</param>
    /// <returns>The bytes.</returns>
    public static byte[] Encode(IEnumerable<Link> links) => Encoding.UTF8.GetBytes(Format(links));

    /// <summary>Parses RFC 6690 text.</summary>
    /// <param name="text">The text. An empty or whitespace-only document yields no links.</param>
    /// <returns>The links, in order.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.MalformedLinkFormat"/> when the text is malformed.</exception>
    public static IReadOnlyList<Link> Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var links = new List<Link>();
        int i = SkipWhitespace(text, 0);
        while (i < text.Length)
        {
            if (text[i] != '<')
            {
                throw Malformed($"expected '<' at offset {i}");
            }

            var close = text.IndexOf('>', i + 1);
            if (close < 0)
            {
                throw Malformed("unterminated target: missing '>'");
            }

            var target = text[(i + 1)..close];
            i = close + 1;
            var parameters = new List<LinkParam>();
            while (true)
            {
                i = SkipWhitespace(text, i);
                if (i >= text.Length || text[i] != ';')
                {
                    break;
                }

                i = SkipWhitespace(text, i + 1);
                int nameStart = i;
                while (i < text.Length && IsTokenChar(text[i]))
                {
                    i++;
                }

                if (i == nameStart)
                {
                    throw Malformed($"expected a parameter name at offset {i}");
                }

                var name = text[nameStart..i];
                i = SkipWhitespace(text, i);
                if (i < text.Length && text[i] == '=')
                {
                    i = SkipWhitespace(text, i + 1);
                    if (i < text.Length && text[i] == '"')
                    {
                        var value = new StringBuilder();
                        i++;
                        while (true)
                        {
                            if (i >= text.Length)
                            {
                                throw Malformed("unterminated quoted string");
                            }

                            var c = text[i++];
                            if (c == '"')
                            {
                                break;
                            }

                            if (c == '\\')
                            {
                                if (i >= text.Length)
                                {
                                    throw Malformed("unterminated quoted string");
                                }

                                c = text[i++];
                            }

                            value.Append(c);
                        }

                        parameters.Add(new LinkParam(name, value.ToString(), true));
                    }
                    else
                    {
                        int valueStart = i;
                        while (i < text.Length && IsPTokenChar(text[i]))
                        {
                            i++;
                        }

                        parameters.Add(new LinkParam(name, text[valueStart..i], false));
                    }
                }
                else
                {
                    parameters.Add(new LinkParam(name, null, false));
                }
            }

            links.Add(new Link(target, parameters));
            i = SkipWhitespace(text, i);
            if (i >= text.Length)
            {
                break;
            }

            if (text[i] != ',')
            {
                throw Malformed($"expected ',' between links at offset {i}");
            }

            i = SkipWhitespace(text, i + 1);
            if (i >= text.Length)
            {
                throw Malformed("trailing ',' with no link after it");
            }
        }

        return links;
    }

    /// <summary>Parses UTF-8 RFC 6690 bytes.</summary>
    /// <param name="payload">The bytes.</param>
    /// <returns>The links, in order.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.MalformedLinkFormat"/> when the payload is malformed.</exception>
    public static IReadOnlyList<Link> Decode(ReadOnlySpan<byte> payload)
    {
        try
        {
            return Parse(new UTF8Encoding(false, true).GetString(payload));
        }
        catch (DecoderFallbackException e)
        {
            throw new Lwm2mException(Lwm2mErrorCode.MalformedLinkFormat, "the payload is not valid UTF-8", e);
        }
    }

    /// <summary>True when <paramref name="value"/> is a non-empty RFC 6690 <c>ptoken</c> and can be written unquoted.</summary>
    /// <param name="value">The value.</param>
    /// <returns>Whether it is a valid bare token.</returns>
    public static bool IsPToken(string value) => value.Length > 0 && value.All(IsPTokenChar);

    // RFC 7230 tchar, used for parameter names.
    private static bool IsTokenChar(char c) =>
        char.IsAsciiLetterOrDigit(c) || c is '!' or '#' or '$' or '%' or '&' or '\'' or '*' or '+' or '-' or '.' or '^' or '_' or '`' or '|' or '~';

    // RFC 6690 ptokenchar: tchar plus a set of URI characters, used for bare values.
    private static bool IsPTokenChar(char c) =>
        IsTokenChar(c) || c is '(' or ')' or '/' or ':' or '<' or '=' or '>' or '?' or '@' or '[' or ']' or '{' or '}';

    private static int SkipWhitespace(string text, int i)
    {
        while (i < text.Length && text[i] is ' ' or '\t' or '\r' or '\n')
        {
            i++;
        }

        return i;
    }

    private static Lwm2mException Malformed(string message) => new(Lwm2mErrorCode.MalformedLinkFormat, message);
}

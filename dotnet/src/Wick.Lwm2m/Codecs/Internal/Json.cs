using System.Globalization;
using System.Text;
using Wick.Lwm2m.Senml;

namespace Wick.Lwm2m.Codecs.Internal;

/// <summary>
/// The subset of JSON (RFC 8259) SenML needs: writing with caller-controlled key order, and a
/// strict reader into a small tree.
/// </summary>
/// <remarks>
/// The reader produces <see cref="SenmlNumber"/> for numbers (integral when the literal has no
/// fraction or exponent), <see cref="string"/>, <see cref="bool"/>, <see langword="null"/>,
/// <see cref="List{T}"/> of items for arrays and <see cref="List{T}"/> of key and value pairs for
/// objects. A duplicate key keeps the last value, as most JSON parsers do.
/// </remarks>
internal static class Json
{
    private const int MaxDepth = 64;

    public static void WriteString(StringBuilder builder, string value)
    {
        builder.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '"':
                    builder.Append("\\\"");
                    break;
                case '\\':
                    builder.Append("\\\\");
                    break;
                case '\b':
                    builder.Append("\\b");
                    break;
                case '\f':
                    builder.Append("\\f");
                    break;
                case '\n':
                    builder.Append("\\n");
                    break;
                case '\r':
                    builder.Append("\\r");
                    break;
                case '\t':
                    builder.Append("\\t");
                    break;
                case < ' ':
                    builder.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    break;
                default:
                    builder.Append(c);
                    break;
            }
        }

        builder.Append('"');
    }

    public static void WriteNumber(StringBuilder builder, SenmlNumber number)
    {
        if (number.IsInteger)
        {
            builder.Append(number.Integer.ToString(CultureInfo.InvariantCulture));
            return;
        }

        var value = number.AsDouble;
        if (!double.IsFinite(value))
        {
            throw new Lwm2mException(Lwm2mErrorCode.UnencodableValue, $"JSON cannot represent {value}");
        }

        builder.Append(JavaDouble.Format(value));
    }

    public static object? Parse(ReadOnlySpan<byte> utf8)
    {
        string text;
        try
        {
            text = new UTF8Encoding(false, true).GetString(utf8);
        }
        catch (DecoderFallbackException e)
        {
            throw new Lwm2mException(Lwm2mErrorCode.MalformedJson, "the payload is not valid UTF-8", e);
        }

        var parser = new Parser(text);
        parser.SkipWhitespace();
        var value = parser.ParseValue(0);
        parser.SkipWhitespace();
        if (!parser.AtEnd)
        {
            throw Malformed($"unexpected content at offset {parser.Position}");
        }

        return value;
    }

    private static Lwm2mException Malformed(string message) => new(Lwm2mErrorCode.MalformedJson, message);

    private sealed class Parser(string text)
    {
        private int _position;

        public bool AtEnd => _position >= text.Length;

        public int Position => _position;

        public void SkipWhitespace()
        {
            while (_position < text.Length && text[_position] is ' ' or '\t' or '\n' or '\r')
            {
                _position++;
            }
        }

        public object? ParseValue(int depth)
        {
            if (depth > MaxDepth)
            {
                throw Malformed("JSON nesting is too deep");
            }

            if (AtEnd)
            {
                throw Malformed("unexpected end of input");
            }

            switch (text[_position])
            {
                case '{':
                    return ParseObject(depth);
                case '[':
                    return ParseArray(depth);
                case '"':
                    return ParseString();
                case 't':
                    Expect("true");
                    return true;
                case 'f':
                    Expect("false");
                    return false;
                case 'n':
                    Expect("null");
                    return null;
                case '-' or (>= '0' and <= '9'):
                    return ParseNumber();
                default:
                    throw Malformed($"unexpected character '{text[_position]}' at offset {_position}");
            }
        }

        private void Expect(string literal)
        {
            if (string.CompareOrdinal(text, _position, literal, 0, literal.Length) != 0)
            {
                throw Malformed($"invalid literal at offset {_position}");
            }

            _position += literal.Length;
        }

        private List<KeyValuePair<object?, object?>> ParseObject(int depth)
        {
            _position++;
            var pairs = new List<KeyValuePair<object?, object?>>();
            SkipWhitespace();
            if (!AtEnd && text[_position] == '}')
            {
                _position++;
                return pairs;
            }

            while (true)
            {
                SkipWhitespace();
                if (AtEnd || text[_position] != '"')
                {
                    throw Malformed($"expected a string key at offset {_position}");
                }

                var key = ParseString();
                SkipWhitespace();
                if (AtEnd || text[_position] != ':')
                {
                    throw Malformed($"expected ':' at offset {_position}");
                }

                _position++;
                SkipWhitespace();
                var value = ParseValue(depth + 1);
                pairs.RemoveAll(p => (string)p.Key! == key);
                pairs.Add(KeyValuePair.Create<object?, object?>(key, value));
                SkipWhitespace();
                if (AtEnd)
                {
                    throw Malformed("unterminated object");
                }

                if (text[_position] == ',')
                {
                    _position++;
                    continue;
                }

                if (text[_position] == '}')
                {
                    _position++;
                    return pairs;
                }

                throw Malformed($"expected ',' or '}}' at offset {_position}");
            }
        }

        private List<object?> ParseArray(int depth)
        {
            _position++;
            var items = new List<object?>();
            SkipWhitespace();
            if (!AtEnd && text[_position] == ']')
            {
                _position++;
                return items;
            }

            while (true)
            {
                SkipWhitespace();
                items.Add(ParseValue(depth + 1));
                SkipWhitespace();
                if (AtEnd)
                {
                    throw Malformed("unterminated array");
                }

                if (text[_position] == ',')
                {
                    _position++;
                    continue;
                }

                if (text[_position] == ']')
                {
                    _position++;
                    return items;
                }

                throw Malformed($"expected ',' or ']' at offset {_position}");
            }
        }

        private string ParseString()
        {
            _position++;
            var builder = new StringBuilder();
            while (true)
            {
                if (AtEnd)
                {
                    throw Malformed("unterminated string");
                }

                var c = text[_position++];
                if (c == '"')
                {
                    return builder.ToString();
                }

                if (c < ' ')
                {
                    throw Malformed("unescaped control character in string");
                }

                if (c != '\\')
                {
                    builder.Append(c);
                    continue;
                }

                if (AtEnd)
                {
                    throw Malformed("unterminated escape");
                }

                var escape = text[_position++];
                switch (escape)
                {
                    case '"': builder.Append('"'); break;
                    case '\\': builder.Append('\\'); break;
                    case '/': builder.Append('/'); break;
                    case 'b': builder.Append('\b'); break;
                    case 'f': builder.Append('\f'); break;
                    case 'n': builder.Append('\n'); break;
                    case 'r': builder.Append('\r'); break;
                    case 't': builder.Append('\t'); break;
                    case 'u':
                        if (_position + 4 > text.Length ||
                            !ushort.TryParse(text.AsSpan(_position, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var code))
                        {
                            throw Malformed("invalid \\u escape");
                        }

                        _position += 4;
                        builder.Append((char)code);
                        break;
                    default:
                        throw Malformed($"invalid escape '\\{escape}'");
                }
            }
        }

        private SenmlNumber ParseNumber()
        {
            int start = _position;
            if (text[_position] == '-')
            {
                _position++;
            }

            if (AtEnd || !char.IsAsciiDigit(text[_position]))
            {
                throw Malformed($"invalid number at offset {start}");
            }

            if (text[_position] == '0')
            {
                _position++;
            }
            else
            {
                SkipDigits();
            }

            bool integral = true;
            if (!AtEnd && text[_position] == '.')
            {
                integral = false;
                _position++;
                RequireDigits(start);
            }

            if (!AtEnd && text[_position] is 'e' or 'E')
            {
                integral = false;
                _position++;
                if (!AtEnd && text[_position] is '+' or '-')
                {
                    _position++;
                }

                RequireDigits(start);
            }

            var literal = text.AsSpan(start, _position - start);
            if (integral && Int128.TryParse(literal, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var integer) &&
                integer >= SenmlNumber.MinInteger && integer <= SenmlNumber.MaxInteger)
            {
                return SenmlNumber.FromInteger(integer);
            }

            return SenmlNumber.FromFloat(double.Parse(literal, NumberStyles.Float, CultureInfo.InvariantCulture));
        }

        private void SkipDigits()
        {
            while (!AtEnd && char.IsAsciiDigit(text[_position]))
            {
                _position++;
            }
        }

        private void RequireDigits(int start)
        {
            if (AtEnd || !char.IsAsciiDigit(text[_position]))
            {
                throw Malformed($"invalid number at offset {start}");
            }

            SkipDigits();
        }
    }
}

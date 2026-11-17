using System.Globalization;
using System.Text;
using Wick.Lwm2m.Codecs.Internal;

namespace Wick.Lwm2m.Codecs;

/// <summary>
/// Plain text, Content-Format 0: a single Resource or Resource Instance value as text
/// (OMA LwM2M 1.2 §7.4.1).
/// </summary>
/// <remarks>
/// <para>
/// Integers, Unsigned Integers and Times are decimal digits (Time as seconds since the Unix
/// epoch). Floats use Java's <c>Double.toString</c> layout, as Eclipse Leshan does. Booleans are
/// <c>1</c> and <c>0</c>, Object Links are <c>object:instance</c>, Opaque is base64 with padding,
/// and Strings and CoRE Links are their UTF-8 text.
/// </para>
/// <para>Text is not self-describing, so decoding needs the type. With none, the value is read as a String, which is Leshan's fallback.</para>
/// </remarks>
public static class PlainTextCodec
{
    /// <summary>The CoAP Content-Format number for plain text.</summary>
    public const int ContentFormat = ContentFormats.PlainText;

    /// <summary>Encodes a value as plain text.</summary>
    /// <param name="value">The value.</param>
    /// <returns>The UTF-8 bytes.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.UnencodableValue"/> for <see cref="Lwm2mType.None"/>.</exception>
    public static byte[] Encode(Lwm2mValue value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var text = value.Type switch
        {
            Lwm2mType.String => value.AsString(),
            Lwm2mType.CoreLink => value.AsCoreLink(),
            Lwm2mType.Integer => value.AsInteger().ToString(CultureInfo.InvariantCulture),
            Lwm2mType.UnsignedInteger => value.AsUnsignedInteger().ToString(CultureInfo.InvariantCulture),
            Lwm2mType.Time => value.AsTime().ToString(CultureInfo.InvariantCulture),
            Lwm2mType.Float => JavaDouble.Format(value.AsFloat()),
            Lwm2mType.Boolean => value.AsBoolean() ? "1" : "0",
            Lwm2mType.ObjectLink => value.AsObjectLink().ToString(),
            Lwm2mType.Opaque => Convert.ToBase64String(value.AsOpaque().Span),
            _ => throw new Lwm2mException(Lwm2mErrorCode.UnencodableValue, "a value-less Resource cannot be encoded as plain text"),
        };
        return Encoding.UTF8.GetBytes(text);
    }

    /// <summary>Decodes plain text as <paramref name="type"/>, or as a String when no type is known.</summary>
    /// <param name="payload">The UTF-8 bytes.</param>
    /// <param name="type">The declared type, or <see langword="null"/>.</param>
    /// <returns>The value.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.MalformedText"/> when the text does not parse as the type.</exception>
    public static Lwm2mValue Decode(ReadOnlySpan<byte> payload, Lwm2mType? type)
    {
        string text;
        try
        {
            text = new UTF8Encoding(false, true).GetString(payload);
        }
        catch (DecoderFallbackException e)
        {
            throw new Lwm2mException(Lwm2mErrorCode.MalformedText, "the payload is not valid UTF-8", e);
        }

        var target = type ?? Lwm2mType.String;
        Lwm2mValue? value = target switch
        {
            Lwm2mType.String => Lwm2mValue.FromString(text),
            Lwm2mType.CoreLink => Lwm2mValue.FromCoreLink(text),
            Lwm2mType.Integer when long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var i) => Lwm2mValue.FromInteger(i),
            Lwm2mType.Time when long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var t) => Lwm2mValue.FromTime(t),
            Lwm2mType.UnsignedInteger when ulong.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var u) => Lwm2mValue.FromUnsignedInteger(u),
            Lwm2mType.Float when IsDecimal(text) && double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var f) => Lwm2mValue.FromFloat(f),
            Lwm2mType.Boolean when text == "1" => Lwm2mValue.FromBoolean(true),
            Lwm2mType.Boolean when text == "0" => Lwm2mValue.FromBoolean(false),
            Lwm2mType.ObjectLink => TryLink(text),
            Lwm2mType.Opaque => TryBase64(text),
            _ => null,
        };

        return value ?? throw new Lwm2mException(Lwm2mErrorCode.MalformedText, $"\"{Truncate(text)}\" is not a valid {target}");
    }

    // Java's Double.valueOf also takes NaN and Infinity; LwM2M text floats are decimal numbers.
    private static bool IsDecimal(string text) => text.Length > 0 && text.All(c => char.IsAsciiDigit(c) || c is '.' or '-' or '+' or 'e' or 'E');

    private static Lwm2mValue? TryLink(string text)
    {
        try
        {
            return Lwm2mValue.FromObjectLink(ObjectLink.Parse(text));
        }
        catch (Lwm2mException)
        {
            return null;
        }
    }

    private static Lwm2mValue? TryBase64(string text)
    {
        var buffer = new byte[(text.Length * 3 / 4) + 3];
        return Convert.TryFromBase64String(text, buffer, out var written) && text.Length % 4 == 0
            ? Lwm2mValue.FromOpaque(buffer.AsSpan(0, written))
            : null;
    }

    private static string Truncate(string text) => text.Length <= 40 ? text : text[..40] + "...";
}

/// <summary>
/// Opaque, Content-Format 42: the raw bytes of a single Opaque Resource or Resource Instance.
/// </summary>
public static class OpaqueCodec
{
    /// <summary>The CoAP Content-Format number for <c>application/octet-stream</c>.</summary>
    public const int ContentFormat = ContentFormats.Opaque;

    /// <summary>Encodes an Opaque value as its bytes.</summary>
    /// <param name="value">The value, which must be <see cref="Lwm2mType.Opaque"/>.</param>
    /// <returns>The bytes.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.UnencodableValue"/> when the value is not Opaque.</exception>
    public static byte[] Encode(Lwm2mValue value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return value.Type == Lwm2mType.Opaque
            ? value.AsOpaque().ToArray()
            : throw new Lwm2mException(Lwm2mErrorCode.UnencodableValue, $"only Opaque values can use Content-Format 42, not {value.Type}");
    }

    /// <summary>Decodes bytes as an Opaque value.</summary>
    /// <param name="payload">The bytes.</param>
    /// <returns>The value.</returns>
    public static Lwm2mValue Decode(ReadOnlySpan<byte> payload) => Lwm2mValue.FromOpaque(payload);
}

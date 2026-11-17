namespace Wick.Coap;

/// <summary>
/// Registered CoAP option numbers used by this library (RFC 7252 section 5.10, RFC 7641,
/// RFC 7959, RFC 7967).
/// </summary>
public static class CoapOptionNumber
{
    /// <summary>If-Match, opaque, 0 to 8 bytes, repeatable (RFC 7252 section 5.10.8.1).</summary>
    public const int IfMatch = 1;

    /// <summary>Uri-Host, string, 1 to 255 bytes (RFC 7252 section 5.10.1).</summary>
    public const int UriHost = 3;

    /// <summary>ETag, opaque, 1 to 8 bytes, repeatable in requests (RFC 7252 section 5.10.6).</summary>
    public const int ETag = 4;

    /// <summary>If-None-Match, empty (RFC 7252 section 5.10.8.2).</summary>
    public const int IfNoneMatch = 5;

    /// <summary>Observe, uint, 0 to 3 bytes (RFC 7641 section 2).</summary>
    public const int Observe = 6;

    /// <summary>Uri-Port, uint, 0 to 2 bytes (RFC 7252 section 5.10.1).</summary>
    public const int UriPort = 7;

    /// <summary>Location-Path, string, 0 to 255 bytes, repeatable (RFC 7252 section 5.10.7).</summary>
    public const int LocationPath = 8;

    /// <summary>Uri-Path, string, 0 to 255 bytes, repeatable (RFC 7252 section 5.10.1).</summary>
    public const int UriPath = 11;

    /// <summary>Content-Format, uint, 0 to 2 bytes (RFC 7252 section 5.10.3).</summary>
    public const int ContentFormat = 12;

    /// <summary>Max-Age, uint, 0 to 4 bytes (RFC 7252 section 5.10.5).</summary>
    public const int MaxAge = 14;

    /// <summary>Uri-Query, string, 0 to 255 bytes, repeatable (RFC 7252 section 5.10.1).</summary>
    public const int UriQuery = 15;

    /// <summary>Accept, uint, 0 to 2 bytes (RFC 7252 section 5.10.4).</summary>
    public const int Accept = 17;

    /// <summary>Location-Query, string, 0 to 255 bytes, repeatable (RFC 7252 section 5.10.7).</summary>
    public const int LocationQuery = 20;

    /// <summary>Block2, uint, 0 to 3 bytes (RFC 7959 section 2.1).</summary>
    public const int Block2 = 23;

    /// <summary>Block1, uint, 0 to 3 bytes (RFC 7959 section 2.1).</summary>
    public const int Block1 = 27;

    /// <summary>Size2, uint, 0 to 4 bytes (RFC 7959 section 4).</summary>
    public const int Size2 = 28;

    /// <summary>Proxy-Uri, string, 1 to 1034 bytes (RFC 7252 section 5.10.2).</summary>
    public const int ProxyUri = 35;

    /// <summary>Proxy-Scheme, string, 1 to 255 bytes (RFC 7252 section 5.10.2).</summary>
    public const int ProxyScheme = 39;

    /// <summary>Size1, uint, 0 to 4 bytes (RFC 7252 section 5.10.9).</summary>
    public const int Size1 = 60;

    /// <summary>No-Response, uint, 0 to 1 byte (RFC 7967).</summary>
    public const int NoResponse = 258;

    /// <summary>
    /// True when the option is critical: odd option numbers are critical, and a recipient
    /// that does not recognise one must reject the message (RFC 7252 section 5.4.1).
    /// </summary>
    /// <param name="number">The option number.</param>
    /// <returns>True for a critical option.</returns>
    public static bool IsCritical(int number) => (number & 1) != 0;

    /// <summary>True when the option is unsafe to forward (RFC 7252 section 5.4.2).</summary>
    /// <param name="number">The option number.</param>
    /// <returns>True for an unsafe option.</returns>
    public static bool IsUnsafe(int number) => (number & 2) != 0;

    /// <summary>Returns the registered name of an option, or the number as text if it is not registered here.</summary>
    /// <param name="number">The option number.</param>
    /// <returns>The option name.</returns>
    public static string NameOf(int number) =>
        OptionDefinitions.TryGet(number, out var definition) ? definition.Name : number.ToString(System.Globalization.CultureInfo.InvariantCulture);
}

/// <summary>The value format of an option (RFC 7252 section 3.2).</summary>
internal enum OptionFormat
{
    Empty,
    Opaque,
    UInt,
    String,
}

/// <summary>Format, length limits and repeatability for one recognised option.</summary>
internal readonly record struct OptionDefinition(int Number, string Name, OptionFormat Format, int MinLength, int MaxLength, bool Repeatable);

/// <summary>The table of options this library recognises.</summary>
internal static class OptionDefinitions
{
    private static readonly Dictionary<int, OptionDefinition> Table = new OptionDefinition[]
    {
        new(CoapOptionNumber.IfMatch, "If-Match", OptionFormat.Opaque, 0, 8, true),
        new(CoapOptionNumber.UriHost, "Uri-Host", OptionFormat.String, 1, 255, false),
        new(CoapOptionNumber.ETag, "ETag", OptionFormat.Opaque, 1, 8, true),
        new(CoapOptionNumber.IfNoneMatch, "If-None-Match", OptionFormat.Empty, 0, 0, false),
        new(CoapOptionNumber.Observe, "Observe", OptionFormat.UInt, 0, 3, false),
        new(CoapOptionNumber.UriPort, "Uri-Port", OptionFormat.UInt, 0, 2, false),
        new(CoapOptionNumber.LocationPath, "Location-Path", OptionFormat.String, 0, 255, true),
        new(CoapOptionNumber.UriPath, "Uri-Path", OptionFormat.String, 0, 255, true),
        new(CoapOptionNumber.ContentFormat, "Content-Format", OptionFormat.UInt, 0, 2, false),
        new(CoapOptionNumber.MaxAge, "Max-Age", OptionFormat.UInt, 0, 4, false),
        new(CoapOptionNumber.UriQuery, "Uri-Query", OptionFormat.String, 0, 255, true),
        new(CoapOptionNumber.Accept, "Accept", OptionFormat.UInt, 0, 2, false),
        new(CoapOptionNumber.LocationQuery, "Location-Query", OptionFormat.String, 0, 255, true),
        new(CoapOptionNumber.Block2, "Block2", OptionFormat.UInt, 0, 3, false),
        new(CoapOptionNumber.Block1, "Block1", OptionFormat.UInt, 0, 3, false),
        new(CoapOptionNumber.Size2, "Size2", OptionFormat.UInt, 0, 4, false),
        new(CoapOptionNumber.ProxyUri, "Proxy-Uri", OptionFormat.String, 1, 1034, false),
        new(CoapOptionNumber.ProxyScheme, "Proxy-Scheme", OptionFormat.String, 1, 255, false),
        new(CoapOptionNumber.Size1, "Size1", OptionFormat.UInt, 0, 4, false),
        new(CoapOptionNumber.NoResponse, "No-Response", OptionFormat.UInt, 0, 1, false),
    }.ToDictionary(d => d.Number);

    public static bool TryGet(int number, out OptionDefinition definition) => Table.TryGetValue(number, out definition);
}

namespace Wick.Lwm2m.Codecs;

/// <summary>
/// The CoAP Content-Format numbers LwM2M uses (IANA CoAP Content-Formats registry).
/// </summary>
public static class ContentFormats
{
    /// <summary><c>text/plain;charset=utf-8</c>, a single Resource value as text.</summary>
    public const int PlainText = 0;

    /// <summary><c>application/link-format</c> (RFC 6690), for Register, Update and Discover.</summary>
    public const int LinkFormat = 40;

    /// <summary><c>application/octet-stream</c>, a single Opaque Resource value.</summary>
    public const int Opaque = 42;

    /// <summary><c>application/senml+json</c> (RFC 8428), LwM2M 1.1 and later.</summary>
    public const int SenmlJson = 110;

    /// <summary><c>application/senml+cbor</c> (RFC 8428), LwM2M 1.1 and later.</summary>
    public const int SenmlCbor = 112;

    /// <summary><c>application/vnd.oma.lwm2m+tlv</c>, the format mandatory in LwM2M 1.0.</summary>
    public const int Tlv = 11542;

    /// <summary><c>application/vnd.oma.lwm2m+json</c>, the LwM2M 1.0 JSON format. Recognised but not implemented.</summary>
    public const int Lwm2mJson = 11543;

    /// <summary><c>application/vnd.oma.lwm2m+cbor</c>, LwM2M 1.2. Recognised but not implemented.</summary>
    public const int Lwm2mCbor = 11544;

    /// <summary>The Content-Formats Wick can encode and decode LwM2M nodes in, ascending.</summary>
    public static IReadOnlyList<int> Supported { get; } = [PlainText, Opaque, SenmlJson, SenmlCbor, Tlv];

    /// <summary>True for the two SenML formats, the only ones that carry Composite and Send payloads.</summary>
    /// <param name="contentFormat">The Content-Format, or <see langword="null"/>.</param>
    /// <returns>Whether it is SenML JSON or SenML CBOR.</returns>
    public static bool IsSenml(int? contentFormat) => contentFormat is SenmlJson or SenmlCbor;
}

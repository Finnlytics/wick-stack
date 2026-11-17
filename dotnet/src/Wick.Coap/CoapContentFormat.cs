namespace Wick.Coap;

/// <summary>
/// Registered Content-Format identifiers (RFC 7252 section 12.3 and the IANA CoAP
/// Content-Formats registry), including the ones LwM2M uses.
/// </summary>
public static class CoapContentFormat
{
    /// <summary>text/plain; charset=utf-8.</summary>
    public const int TextPlain = 0;

    /// <summary>application/link-format (RFC 6690).</summary>
    public const int LinkFormat = 40;

    /// <summary>application/xml.</summary>
    public const int Xml = 41;

    /// <summary>application/octet-stream.</summary>
    public const int OctetStream = 42;

    /// <summary>application/exi.</summary>
    public const int Exi = 47;

    /// <summary>application/json.</summary>
    public const int Json = 50;

    /// <summary>application/cbor.</summary>
    public const int Cbor = 60;

    /// <summary>application/senml+json (RFC 8428).</summary>
    public const int SenmlJson = 110;

    /// <summary>application/senml+cbor (RFC 8428).</summary>
    public const int SenmlCbor = 112;

    /// <summary>application/vnd.oma.lwm2m+tlv.</summary>
    public const int Lwm2mTlv = 11542;

    /// <summary>application/vnd.oma.lwm2m+json.</summary>
    public const int Lwm2mJson = 11543;

    /// <summary>application/vnd.oma.lwm2m+cbor.</summary>
    public const int Lwm2mCbor = 11544;
}

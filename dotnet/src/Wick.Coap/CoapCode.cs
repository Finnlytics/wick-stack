namespace Wick.Coap;

/// <summary>
/// A CoAP code: a three-bit class and five-bit detail packed into one byte and written
/// <c>c.dd</c> (RFC 7252 section 3). Class 0 holds request methods and the empty code,
/// classes 2, 4 and 5 hold responses. Every byte value is representable, so codes that are
/// not registered still round-trip.
/// </summary>
public readonly record struct CoapCode
{
    /// <summary>Creates a code from its wire byte.</summary>
    /// <param name="value">The code byte as carried in the header.</param>
    public CoapCode(byte value) => Value = value;

    /// <summary>Creates a code from its class and detail.</summary>
    /// <param name="codeClass">The class, 0 to 7.</param>
    /// <param name="detail">The detail, 0 to 31.</param>
    /// <exception cref="ArgumentOutOfRangeException">The class or detail is out of range.</exception>
    public CoapCode(int codeClass, int detail)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(codeClass);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(codeClass, 7);
        ArgumentOutOfRangeException.ThrowIfNegative(detail);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(detail, 31);
        Value = (byte)((codeClass << 5) | detail);
    }

    /// <summary>The code byte as carried in the header.</summary>
    public byte Value { get; }

    /// <summary>The class, the top three bits.</summary>
    public int Class => Value >> 5;

    /// <summary>The detail, the low five bits.</summary>
    public int Detail => Value & 0x1F;

    /// <summary>True for 0.00, the code of an empty message.</summary>
    public bool IsEmpty => Value == 0;

    /// <summary>True for a request method, class 0 other than 0.00.</summary>
    public bool IsRequest => Class == 0 && Value != 0;

    /// <summary>True for a response, classes 2 to 5.</summary>
    public bool IsResponse => Class is >= 2 and <= 5;

    /// <summary>True for a success response, class 2.</summary>
    public bool IsSuccess => Class == 2;

    /// <summary>True for a client or server error response, classes 4 and 5.</summary>
    public bool IsError => Class is 4 or 5;

    /// <summary>
    /// True for the classes RFC 7252 reserves (1, 6 and 7). A message carrying one is a
    /// format error.
    /// </summary>
    public bool IsReserved => Class is 1 or 6 or 7;

    /// <summary>Formats the code as <c>c.dd</c>, for example <c>2.05</c>.</summary>
    /// <returns>The dotted form of the code.</returns>
    public override string ToString() => $"{Class}.{Detail:D2}";

    /// <summary>Converts a wire byte to a code.</summary>
    /// <param name="value">The code byte.</param>
    public static implicit operator CoapCode(byte value) => new(value);

    /// <summary>0.00, the code of an empty message (RFC 7252 section 4.1).</summary>
    public static CoapCode Empty => new(0x00);

    /// <summary>0.01 GET (RFC 7252 section 5.8.1).</summary>
    public static CoapCode Get => new(0x01);

    /// <summary>0.02 POST (RFC 7252 section 5.8.2).</summary>
    public static CoapCode Post => new(0x02);

    /// <summary>0.03 PUT (RFC 7252 section 5.8.3).</summary>
    public static CoapCode Put => new(0x03);

    /// <summary>0.04 DELETE (RFC 7252 section 5.8.4).</summary>
    public static CoapCode Delete => new(0x04);

    /// <summary>0.05 FETCH (RFC 8132).</summary>
    public static CoapCode Fetch => new(0x05);

    /// <summary>0.06 PATCH (RFC 8132).</summary>
    public static CoapCode Patch => new(0x06);

    /// <summary>0.07 iPATCH (RFC 8132).</summary>
    public static CoapCode IPatch => new(0x07);

    /// <summary>2.01 Created.</summary>
    public static CoapCode Created => new(0x41);

    /// <summary>2.02 Deleted.</summary>
    public static CoapCode Deleted => new(0x42);

    /// <summary>2.03 Valid.</summary>
    public static CoapCode Valid => new(0x43);

    /// <summary>2.04 Changed.</summary>
    public static CoapCode Changed => new(0x44);

    /// <summary>2.05 Content.</summary>
    public static CoapCode Content => new(0x45);

    /// <summary>2.31 Continue (RFC 7959 section 2.9.1).</summary>
    public static CoapCode Continue => new(0x5F);

    /// <summary>4.00 Bad Request.</summary>
    public static CoapCode BadRequest => new(0x80);

    /// <summary>4.01 Unauthorized.</summary>
    public static CoapCode Unauthorized => new(0x81);

    /// <summary>4.02 Bad Option.</summary>
    public static CoapCode BadOption => new(0x82);

    /// <summary>4.03 Forbidden.</summary>
    public static CoapCode Forbidden => new(0x83);

    /// <summary>4.04 Not Found.</summary>
    public static CoapCode NotFound => new(0x84);

    /// <summary>4.05 Method Not Allowed.</summary>
    public static CoapCode MethodNotAllowed => new(0x85);

    /// <summary>4.06 Not Acceptable.</summary>
    public static CoapCode NotAcceptable => new(0x86);

    /// <summary>4.08 Request Entity Incomplete (RFC 7959 section 2.9.2).</summary>
    public static CoapCode RequestEntityIncomplete => new(0x88);

    /// <summary>4.09 Conflict (RFC 8132).</summary>
    public static CoapCode Conflict => new(0x89);

    /// <summary>4.12 Precondition Failed.</summary>
    public static CoapCode PreconditionFailed => new(0x8C);

    /// <summary>4.13 Request Entity Too Large.</summary>
    public static CoapCode RequestEntityTooLarge => new(0x8D);

    /// <summary>4.15 Unsupported Content-Format.</summary>
    public static CoapCode UnsupportedContentFormat => new(0x8F);

    /// <summary>4.22 Unprocessable Entity (RFC 8132).</summary>
    public static CoapCode UnprocessableEntity => new(0x96);

    /// <summary>5.00 Internal Server Error.</summary>
    public static CoapCode InternalServerError => new(0xA0);

    /// <summary>5.01 Not Implemented.</summary>
    public static CoapCode NotImplemented => new(0xA1);

    /// <summary>5.02 Bad Gateway.</summary>
    public static CoapCode BadGateway => new(0xA2);

    /// <summary>5.03 Service Unavailable.</summary>
    public static CoapCode ServiceUnavailable => new(0xA3);

    /// <summary>5.04 Gateway Timeout.</summary>
    public static CoapCode GatewayTimeout => new(0xA4);

    /// <summary>5.05 Proxying Not Supported.</summary>
    public static CoapCode ProxyingNotSupported => new(0xA5);
}

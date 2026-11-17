using System.Globalization;

namespace Wick.Lwm2m.Wire;

/// <summary>The CoAP request methods LwM2M uses.</summary>
public enum Method
{
    /// <summary>GET (RFC 7252): Read, Discover, Observe and Cancel Observation.</summary>
    Get,

    /// <summary>POST (RFC 7252): Register, Update, Create, partial Write, Execute and Send.</summary>
    Post,

    /// <summary>PUT (RFC 7252): replacing Write and Write-Attributes.</summary>
    Put,

    /// <summary>DELETE (RFC 7252): Delete and Deregister.</summary>
    Delete,

    /// <summary>FETCH (RFC 8132): Read-Composite and Observe-Composite.</summary>
    Fetch,

    /// <summary>iPATCH (RFC 8132): Write-Composite.</summary>
    IPatch,
}

/// <summary>
/// A CoAP response code: a class and a detail, written <c>class.detail</c> as in <c>2.05</c>.
/// </summary>
/// <remarks>
/// Any code is representable, so a transport can hand over whatever arrived. The named values are
/// the ones LwM2M uses (OMA LwM2M 1.2 §6 and RFC 7252 §5.9).
/// </remarks>
/// <param name="Class">The class, 0 to 7: 2 for success, 4 for client error, 5 for server error.</param>
/// <param name="Detail">The detail, 0 to 31.</param>
public readonly record struct ResponseCode(byte Class, byte Detail)
{
    /// <summary>2.01 Created: Register, Create.</summary>
    public static readonly ResponseCode Created = new(2, 1);

    /// <summary>2.02 Deleted: Delete, Deregister.</summary>
    public static readonly ResponseCode Deleted = new(2, 2);

    /// <summary>2.03 Valid.</summary>
    public static readonly ResponseCode Valid = new(2, 3);

    /// <summary>2.04 Changed: Write, Execute, Update, Write-Attributes.</summary>
    public static readonly ResponseCode Changed = new(2, 4);

    /// <summary>2.05 Content: Read, Discover, Observe and Notify.</summary>
    public static readonly ResponseCode Content = new(2, 5);

    /// <summary>2.31 Continue, used by block-wise transfer.</summary>
    public static readonly ResponseCode Continue = new(2, 31);

    /// <summary>4.00 Bad Request.</summary>
    public static readonly ResponseCode BadRequest = new(4, 0);

    /// <summary>4.01 Unauthorized.</summary>
    public static readonly ResponseCode Unauthorized = new(4, 1);

    /// <summary>4.02 Bad Option.</summary>
    public static readonly ResponseCode BadOption = new(4, 2);

    /// <summary>4.03 Forbidden.</summary>
    public static readonly ResponseCode Forbidden = new(4, 3);

    /// <summary>4.04 Not Found.</summary>
    public static readonly ResponseCode NotFound = new(4, 4);

    /// <summary>4.05 Method Not Allowed.</summary>
    public static readonly ResponseCode MethodNotAllowed = new(4, 5);

    /// <summary>4.06 Not Acceptable.</summary>
    public static readonly ResponseCode NotAcceptable = new(4, 6);

    /// <summary>4.08 Request Entity Incomplete.</summary>
    public static readonly ResponseCode RequestEntityIncomplete = new(4, 8);

    /// <summary>4.09 Conflict.</summary>
    public static readonly ResponseCode Conflict = new(4, 9);

    /// <summary>4.12 Precondition Failed.</summary>
    public static readonly ResponseCode PreconditionFailed = new(4, 12);

    /// <summary>4.13 Request Entity Too Large.</summary>
    public static readonly ResponseCode RequestEntityTooLarge = new(4, 13);

    /// <summary>4.15 Unsupported Content-Format.</summary>
    public static readonly ResponseCode UnsupportedContentFormat = new(4, 15);

    /// <summary>5.00 Internal Server Error.</summary>
    public static readonly ResponseCode InternalServerError = new(5, 0);

    /// <summary>5.01 Not Implemented.</summary>
    public static readonly ResponseCode NotImplemented = new(5, 1);

    /// <summary>5.03 Service Unavailable.</summary>
    public static readonly ResponseCode ServiceUnavailable = new(5, 3);

    /// <summary>True for the 2.xx success class.</summary>
    public bool IsSuccess => Class == 2;

    /// <summary>True for the 4.xx and 5.xx error classes.</summary>
    public bool IsError => Class is 4 or 5;

    /// <summary>The single byte CoAP puts on the wire: <c>class &lt;&lt; 5 | detail</c>.</summary>
    public byte ToByte() => (byte)((Class << 5) | (Detail & 0x1F));

    /// <summary>Recovers a code from its wire byte.</summary>
    /// <param name="value">The byte.</param>
    /// <returns>The code.</returns>
    public static ResponseCode FromByte(byte value) => new((byte)(value >> 5), (byte)(value & 0x1F));

    /// <summary>The code in <c>class.detail</c> form, such as <c>4.04</c>.</summary>
    /// <returns>The text.</returns>
    public override string ToString() => string.Create(CultureInfo.InvariantCulture, $"{Class}.{Detail:00}");
}

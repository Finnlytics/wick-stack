namespace Wick.Lwm2m;

/// <summary>
/// Stable, machine-readable reasons a Wick operation can fail.
/// </summary>
/// <remarks>
/// Callers should branch on the code rather than the message. Messages are for people and may
/// change between versions; codes will not.
/// </remarks>
public enum Lwm2mErrorCode
{
    /// <summary>A path string or segment list is not a valid LwM2M path.</summary>
    InvalidPath,

    /// <summary>A CBOR payload could not be parsed.</summary>
    MalformedCbor,

    /// <summary>A JSON payload could not be parsed.</summary>
    MalformedJson,

    /// <summary>A payload parsed but does not have the SenML shape.</summary>
    MalformedSenml,

    /// <summary>A TLV payload is truncated or inconsistent.</summary>
    MalformedTlv,

    /// <summary>A plain text payload does not parse as the requested type.</summary>
    MalformedText,

    /// <summary>A CoRE Link Format document could not be parsed.</summary>
    MalformedLinkFormat,

    /// <summary>A DDF document is not well-formed XML.</summary>
    MalformedXml,

    /// <summary>A DDF document is well-formed XML but not a valid Object definition.</summary>
    InvalidDdf,

    /// <summary>A SenML record has no value field and no-value records were not allowed.</summary>
    MissingValue,

    /// <summary>A SenML record has no name, so no path can be derived from it.</summary>
    MissingName,

    /// <summary>A value cannot be represented in the requested type or format.</summary>
    UnencodableValue,

    /// <summary>A value on the wire does not satisfy the type the Object model declares.</summary>
    TypeMismatch,

    /// <summary>The content format is not supported for this operation or node.</summary>
    UnsupportedContentFormat,

    /// <summary>A method, path and option combination that LwM2M does not define.</summary>
    UnsupportedOperation,

    /// <summary>A notification attribute value is malformed or the set breaks a rule in OMA LwM2M 1.2 §5.1.</summary>
    InvalidAttribute,

    /// <summary>A response does not carry what the operation requires.</summary>
    InvalidResponse,

    /// <summary>A node is not valid for the path it is being encoded against.</summary>
    InvalidNode,
}

/// <summary>
/// The exception Wick throws for malformed input and invalid arguments in protocol terms.
/// </summary>
/// <remarks>
/// Wick throws this rather than general exceptions so a caller can catch one type at a protocol
/// boundary and map it to a CoAP response, usually 4.00 Bad Request.
/// </remarks>
public sealed class Lwm2mException : Exception
{
    /// <summary>Creates an exception with a code and a human-readable message.</summary>
    /// <param name="code">The stable reason for the failure.</param>
    /// <param name="message">A description of the failure for people.</param>
    public Lwm2mException(Lwm2mErrorCode code, string message)
        : base(message)
    {
        Code = code;
    }

    /// <summary>Creates an exception with a code, a message and the exception that caused it.</summary>
    /// <param name="code">The stable reason for the failure.</param>
    /// <param name="message">A description of the failure for people.</param>
    /// <param name="innerException">The underlying cause.</param>
    public Lwm2mException(Lwm2mErrorCode code, string message, Exception innerException)
        : base(message, innerException)
    {
        Code = code;
    }

    /// <summary>The stable reason for the failure.</summary>
    public Lwm2mErrorCode Code { get; }
}

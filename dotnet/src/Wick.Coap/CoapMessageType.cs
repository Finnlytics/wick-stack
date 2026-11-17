namespace Wick.Coap;

/// <summary>
/// The two-bit message type in the CoAP header (RFC 7252 section 3).
/// </summary>
public enum CoapMessageType : byte
{
    /// <summary>Confirmable: the recipient must acknowledge or reset it, and the sender retransmits until it does.</summary>
    Confirmable = 0,

    /// <summary>Non-confirmable: sent once, never acknowledged.</summary>
    NonConfirmable = 1,

    /// <summary>Acknowledgement of a confirmable message, optionally carrying a piggybacked response.</summary>
    Acknowledgement = 2,

    /// <summary>Reset: the recipient could not process a message, or has no state for it.</summary>
    Reset = 3,
}

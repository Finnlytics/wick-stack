namespace Wick.Coap;

/// <summary>The base type of errors raised by a <see cref="CoapEndpoint"/> exchange.</summary>
public class CoapException : Exception
{
    /// <summary>Creates the exception.</summary>
    /// <param name="message">A description of the error.</param>
    /// <param name="innerException">The cause, if any.</param>
    public CoapException(string message, Exception? innerException = null) : base(message, innerException) { }
}

/// <summary>
/// No acknowledgement arrived after MAX_RETRANSMIT retransmissions, or no response arrived
/// within the response timeout (RFC 7252 section 4.2).
/// </summary>
public sealed class CoapTimeoutException : CoapException
{
    /// <summary>Creates the exception.</summary>
    /// <param name="message">A description of what timed out.</param>
    public CoapTimeoutException(string message) : base(message) { }
}

/// <summary>The peer answered with a Reset message (RFC 7252 section 4.2).</summary>
public sealed class CoapResetException : CoapException
{
    /// <summary>Creates the exception.</summary>
    /// <param name="message">A description of what was reset.</param>
    public CoapResetException(string message) : base(message) { }
}

/// <summary>The peer's session ended while an exchange with it was in progress.</summary>
public sealed class CoapPeerClosedException : CoapException
{
    /// <summary>Creates the exception.</summary>
    /// <param name="message">A description.</param>
    public CoapPeerClosedException(string message) : base(message) { }
}

/// <summary>A block-wise transfer could not be completed (RFC 7959).</summary>
public sealed class CoapBlockwiseException : CoapException
{
    /// <summary>Creates the exception.</summary>
    /// <param name="message">A description of the problem.</param>
    public CoapBlockwiseException(string message) : base(message) { }
}

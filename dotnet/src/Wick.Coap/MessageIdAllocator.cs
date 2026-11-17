using System.Security.Cryptography;

namespace Wick.Coap;

/// <summary>
/// A 16-bit message id counter that wraps (RFC 7252 section 4.4). The start value is random
/// unless given, so a restarted endpoint is unlikely to reuse ids a peer still remembers.
/// Not thread-safe; the endpoint guards it.
/// </summary>
public sealed class MessageIdAllocator
{
    private ushort _next;

    /// <summary>Creates an allocator.</summary>
    /// <param name="initial">The first id to hand out, or null for a random start.</param>
    public MessageIdAllocator(ushort? initial = null) =>
        _next = initial ?? (ushort)RandomNumberGenerator.GetInt32(0, 0x10000);

    /// <summary>Returns the next id and advances, wrapping from 65535 to 0.</summary>
    /// <returns>The id.</returns>
    public ushort Next() => _next++;
}

/// <summary>Generates random tokens (RFC 7252 section 5.3.1, RFC 9175 section 4.2).</summary>
public static class TokenGenerator
{
    /// <summary>Returns a token of random bytes from a cryptographic source.</summary>
    /// <param name="length">The token length, 0 to 8.</param>
    /// <returns>The token.</returns>
    /// <exception cref="ArgumentOutOfRangeException">The length is not 0 to 8.</exception>
    public static byte[] Create(int length = 8)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(length);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(length, 8);
        return RandomNumberGenerator.GetBytes(length);
    }
}

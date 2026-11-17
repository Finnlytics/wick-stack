using System.Collections.Concurrent;
using System.Net;
using System.Text;

namespace Wick.Coap.Dtls;

/// <summary>Looks up pre-shared keys during a DTLS handshake.</summary>
public interface IPskStore
{
    /// <summary>
    /// Returns the key for a PSK identity, or null to refuse the handshake with
    /// unknown_psk_identity.
    /// </summary>
    /// <param name="identity">The identity the client presented, as raw bytes.</param>
    /// <param name="remoteEndPoint">The address the handshake comes from.</param>
    /// <param name="cancellationToken">Cancelled when the lookup takes longer than <see cref="DtlsServerOptions.PskLookupTimeout"/>.</param>
    /// <returns>The key, or null.</returns>
    ValueTask<byte[]?> GetKeyAsync(ReadOnlyMemory<byte> identity, EndPoint remoteEndPoint, CancellationToken cancellationToken);
}

/// <summary>A PSK store held in memory, keyed by identity string. Safe for concurrent use.</summary>
public sealed class InMemoryPskStore : IPskStore
{
    private readonly ConcurrentDictionary<string, byte[]> _keys = new(StringComparer.Ordinal);

    /// <summary>Adds or replaces a key.</summary>
    /// <param name="identity">The identity.</param>
    /// <param name="key">The key.</param>
    /// <returns>The store, for chaining.</returns>
    public InMemoryPskStore Set(string identity, byte[] key)
    {
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentNullException.ThrowIfNull(key);
        _keys[identity] = (byte[])key.Clone();
        return this;
    }

    /// <summary>Removes a key.</summary>
    /// <param name="identity">The identity.</param>
    /// <returns>True when a key was removed.</returns>
    public bool Remove(string identity) => _keys.TryRemove(identity, out _);

    /// <inheritdoc />
    public ValueTask<byte[]?> GetKeyAsync(ReadOnlyMemory<byte> identity, EndPoint remoteEndPoint, CancellationToken cancellationToken)
    {
        var name = Encoding.UTF8.GetString(identity.Span);
        return ValueTask.FromResult(_keys.TryGetValue(name, out var key) ? (byte[]?)key.Clone() : null);
    }
}

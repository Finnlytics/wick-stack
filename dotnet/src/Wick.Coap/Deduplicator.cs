namespace Wick.Coap;

/// <summary>Whether a message id has been seen before.</summary>
public enum DeduplicationResult
{
    /// <summary>First sighting; the message should be processed.</summary>
    New,

    /// <summary>Seen within the window; the message must not be processed again.</summary>
    Duplicate,
}

/// <summary>
/// Message deduplication (RFC 7252 section 4.5) with a cached reply per message. Entries are
/// kept for a fixed lifetime, EXCHANGE_LIFETIME by default, and then expire, and the total
/// number of entries is capped; when the cap is reached the oldest entry is dropped.
/// The type is pure: the caller supplies time and holds any lock.
/// </summary>
/// <typeparam name="TKey">The key, normally the peer and message id.</typeparam>
public sealed class Deduplicator<TKey> where TKey : notnull
{
    private readonly Dictionary<TKey, Entry> _entries = [];
    private readonly LinkedList<TKey> _order = new();
    private readonly TimeSpan _lifetime;
    private readonly int _capacity;

    /// <summary>Creates a deduplicator.</summary>
    /// <param name="lifetime">How long an entry is remembered.</param>
    /// <param name="capacity">The most entries held at once.</param>
    public Deduplicator(TimeSpan lifetime, int capacity = 100_000)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(lifetime, TimeSpan.Zero);
        ArgumentOutOfRangeException.ThrowIfLessThan(capacity, 1);
        _lifetime = lifetime;
        _capacity = capacity;
    }

    /// <summary>The number of entries currently remembered.</summary>
    public int Count => _entries.Count;

    /// <summary>
    /// Records a message id. Returns <see cref="DeduplicationResult.Duplicate"/> with any cached
    /// reply when the key is already present, otherwise remembers it.
    /// </summary>
    /// <param name="key">The key.</param>
    /// <param name="now">The current time.</param>
    /// <param name="cachedReply">The reply recorded for the key with <see cref="SetReply"/>, if any.</param>
    /// <returns>Whether the key was new.</returns>
    public DeduplicationResult Check(TKey key, DateTimeOffset now, out byte[]? cachedReply)
    {
        Purge(now);
        if (_entries.TryGetValue(key, out var existing))
        {
            cachedReply = existing.Reply;
            return DeduplicationResult.Duplicate;
        }

        while (_entries.Count >= _capacity) RemoveOldest();
        var node = _order.AddLast(key);
        _entries[key] = new Entry(now + _lifetime, node, null);
        cachedReply = null;
        return DeduplicationResult.New;
    }

    /// <summary>Records the reply sent for a key, so a duplicate can be answered with the same bytes.</summary>
    /// <param name="key">The key.</param>
    /// <param name="reply">The reply datagram.</param>
    /// <returns>False when the key is no longer remembered.</returns>
    public bool SetReply(TKey key, byte[] reply)
    {
        if (!_entries.TryGetValue(key, out var entry)) return false;
        _entries[key] = entry with { Reply = reply };
        return true;
    }

    /// <summary>True when the key is remembered.</summary>
    /// <param name="key">The key.</param>
    /// <returns>True when present.</returns>
    public bool Contains(TKey key) => _entries.ContainsKey(key);

    /// <summary>Drops every entry whose lifetime has passed.</summary>
    /// <param name="now">The current time.</param>
    public void Purge(DateTimeOffset now)
    {
        while (_order.First is { } first && _entries[first.Value].ExpiresAt <= now)
            RemoveOldest();
    }

    /// <summary>Drops every entry whose key matches a predicate.</summary>
    /// <param name="predicate">Selects the keys to drop.</param>
    public void RemoveWhere(Func<TKey, bool> predicate)
    {
        var node = _order.First;
        while (node is not null)
        {
            var next = node.Next;
            if (predicate(node.Value))
            {
                _entries.Remove(node.Value);
                _order.Remove(node);
            }
            node = next;
        }
    }

    private void RemoveOldest()
    {
        var first = _order.First!;
        _entries.Remove(first.Value);
        _order.RemoveFirst();
    }

    private readonly record struct Entry(DateTimeOffset ExpiresAt, LinkedListNode<TKey> Node, byte[]? Reply);
}

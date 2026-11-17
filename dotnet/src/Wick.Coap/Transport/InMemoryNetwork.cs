using System.Net;

namespace Wick.Coap.Transport;

/// <summary>One datagram in flight on an <see cref="InMemoryNetwork"/>.</summary>
/// <param name="From">The sender's address.</param>
/// <param name="To">The destination address.</param>
/// <param name="Bytes">The datagram.</param>
public sealed record InMemoryDatagram(IPEndPoint From, IPEndPoint To, byte[] Bytes)
{
    /// <summary>The datagram decoded as CoAP, or null if it is not well formed.</summary>
    public CoapMessage? Message => CoapMessageCodec.TryDecode(Bytes, out var message, out _) ? message : null;

    /// <summary>Formats the datagram for diagnostics.</summary>
    /// <returns>Source, destination and decoded message.</returns>
    public override string ToString() => $"{From} -> {To}: {Message?.ToString() ?? Convert.ToHexString(Bytes)}";
}

/// <summary>
/// A simulated datagram network for tests and simulations. Datagrams are queued on send and
/// only delivered when the caller pumps the network, so a test controls ordering, loss and
/// duplication exactly. Nothing here uses real time or sockets.
/// </summary>
public sealed class InMemoryNetwork
{
    private readonly object _gate = new();
    private readonly Dictionary<IPEndPoint, InMemoryTransport> _transports = [];
    private readonly Queue<InMemoryDatagram> _queue = new();
    private readonly List<InMemoryDatagram> _sent = [];
    private TaskCompletionSource _changed = new(TaskCreationOptions.RunContinuationsAsynchronously);

    /// <summary>
    /// Decides how many copies of each datagram to deliver: 0 drops it, 1 delivers it, 2 or more
    /// duplicate it. Evaluated when the datagram is delivered. Null delivers everything once.
    /// </summary>
    public Func<InMemoryDatagram, int>? Fate { get; set; }

    /// <summary>Every datagram sent so far, in order, whatever its fate.</summary>
    public IReadOnlyList<InMemoryDatagram> Sent
    {
        get { lock (_gate) return [.. _sent]; }
    }

    /// <summary>Datagrams queued and not yet delivered.</summary>
    public int Pending
    {
        get { lock (_gate) return _queue.Count; }
    }

    /// <summary>Creates a transport attached to this network at an address.</summary>
    /// <param name="address">The transport's address.</param>
    /// <param name="security">Security details to report for peers this transport sees, to simulate an authenticated transport.</param>
    /// <returns>The transport.</returns>
    public InMemoryTransport CreateTransport(IPEndPoint address, Func<IPEndPoint, CoapPeerSecurity?>? security = null)
    {
        var transport = new InMemoryTransport(this, address, security);
        lock (_gate) _transports.Add(address, transport);
        return transport;
    }

    /// <summary>Forgets every datagram sent so far.</summary>
    public void ClearSent()
    {
        lock (_gate) _sent.Clear();
    }

    /// <summary>Removes and returns every queued datagram without delivering any.</summary>
    /// <returns>The datagrams that were queued.</returns>
    public IReadOnlyList<InMemoryDatagram> TakePending()
    {
        lock (_gate)
        {
            var list = _queue.ToList();
            _queue.Clear();
            return list;
        }
    }

    /// <summary>Queues a datagram as if it had been sent, for example one taken earlier with <see cref="TakePending"/>.</summary>
    /// <param name="datagram">The datagram.</param>
    public void Inject(InMemoryDatagram datagram)
    {
        lock (_gate)
        {
            _queue.Enqueue(datagram);
            SignalLocked();
        }
    }

    /// <summary>Delivers queued datagrams, including ones sent as a result, until the queue is empty.</summary>
    /// <param name="maxDeliveries">A guard against endless ping-pong.</param>
    /// <returns>The number of datagrams taken off the queue.</returns>
    public int RunUntilIdle(int maxDeliveries = 100_000)
    {
        int count = 0;
        while (count < maxDeliveries && TryDeliverOne()) count++;
        return count;
    }

    /// <summary>
    /// Pumps the network until <paramref name="task"/> completes. Waits without a timer for
    /// datagrams sent from other threads, such as continuations of the code under test.
    /// </summary>
    /// <param name="task">The task to drive.</param>
    /// <param name="timeout">A safety limit in real time, so a broken test fails rather than hangs.</param>
    /// <returns>A task that completes when <paramref name="task"/> has.</returns>
    /// <exception cref="TimeoutException">The task did not complete within the safety limit.</exception>
    public async Task RunUntilAsync(Task task, TimeSpan? timeout = null)
    {
        using var limit = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(10));
        var expired = Task.Delay(Timeout.Infinite, limit.Token);
        while (!task.IsCompleted)
        {
            Task changed;
            lock (_gate) changed = _changed.Task;
            RunUntilIdle();
            if (task.IsCompleted) break;
            if (expired.IsCompleted) throw new TimeoutException("The task did not complete while the network was pumped.");
            await Task.WhenAny(task, changed, expired).ConfigureAwait(false);
        }
        RunUntilIdle();
        await task.ConfigureAwait(false);
    }

    /// <summary>
    /// Waits, without delivering anything, until at least <paramref name="count"/> datagrams
    /// have been sent in total. Useful when the code under test sends from another thread.
    /// </summary>
    /// <param name="count">The total to wait for.</param>
    /// <param name="timeout">A safety limit in real time.</param>
    /// <returns>A task that completes once the count is reached.</returns>
    /// <exception cref="TimeoutException">The count was not reached within the safety limit.</exception>
    public async Task WaitForSentAsync(int count, TimeSpan? timeout = null)
    {
        using var limit = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(10));
        var expired = Task.Delay(Timeout.Infinite, limit.Token);
        while (true)
        {
            Task changed;
            lock (_gate)
            {
                if (_sent.Count >= count) return;
                changed = _changed.Task;
            }
            if (expired.IsCompleted) throw new TimeoutException($"Fewer than {count} datagrams were sent.");
            await Task.WhenAny(changed, expired).ConfigureAwait(false);
        }
    }

    internal void Enqueue(InMemoryDatagram datagram)
    {
        lock (_gate)
        {
            _sent.Add(datagram);
            _queue.Enqueue(datagram);
            SignalLocked();
        }
    }

    private void SignalLocked()
    {
        var previous = _changed;
        _changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        previous.TrySetResult();
    }

    internal void Remove(IPEndPoint address)
    {
        lock (_gate) _transports.Remove(address);
    }

    private bool TryDeliverOne()
    {
        InMemoryDatagram datagram;
        InMemoryTransport? target;
        lock (_gate)
        {
            if (!_queue.TryDequeue(out datagram!)) return false;
            _transports.TryGetValue(datagram.To, out target);
        }
        int copies = Fate?.Invoke(datagram) ?? 1;
        for (int i = 0; i < copies && target is not null; i++)
            target.Deliver(datagram.From, datagram.Bytes);
        return true;
    }
}

/// <summary>A transport on an <see cref="InMemoryNetwork"/>.</summary>
public sealed class InMemoryTransport : IDatagramTransport
{
    private readonly InMemoryNetwork _network;
    private readonly IPEndPoint _address;
    private readonly Func<IPEndPoint, CoapPeerSecurity?>? _security;
    private readonly System.Collections.Concurrent.ConcurrentDictionary<IPEndPoint, ICoapPeer> _securePeers = new();
    private IDatagramReceiver? _receiver;

    internal InMemoryTransport(InMemoryNetwork network, IPEndPoint address, Func<IPEndPoint, CoapPeerSecurity?>? security)
    {
        _network = network;
        _address = address;
        _security = security;
    }

    /// <inheritdoc />
    public string Scheme => _security is null ? "coap" : "coaps";

    /// <inheritdoc />
    public EndPoint LocalEndPoint => _address;

    /// <inheritdoc />
    public int MaxMessageSize { get; init; } = 1152;

    /// <inheritdoc />
    public Task StartAsync(IDatagramReceiver receiver, CancellationToken cancellationToken = default)
    {
        _receiver = receiver ?? throw new ArgumentNullException(nameof(receiver));
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public ValueTask SendAsync(ICoapPeer peer, ReadOnlyMemory<byte> datagram, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(peer);
        if (datagram.Length > MaxMessageSize)
            throw new ArgumentException($"Message of {datagram.Length} bytes exceeds the transport limit of {MaxMessageSize}.", nameof(datagram));
        _network.Enqueue(new InMemoryDatagram(_address, (IPEndPoint)peer.RemoteEndPoint, datagram.ToArray()));
        return ValueTask.CompletedTask;
    }

    /// <inheritdoc />
    public bool TryGetPeer(EndPoint remoteEndPoint, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out ICoapPeer? peer)
    {
        peer = PeerFor((IPEndPoint)remoteEndPoint);
        return true;
    }

    /// <summary>Returns the peer object this transport reports for an address.</summary>
    /// <param name="remoteEndPoint">The address.</param>
    /// <returns>The peer.</returns>
    public ICoapPeer PeerFor(IPEndPoint remoteEndPoint) => _security is null
        ? new UdpPeer(remoteEndPoint)
        : _securePeers.GetOrAdd(remoteEndPoint, address => new InMemoryPeer(address, _security(address)));

    /// <summary>Reports a peer as closed to the receiver, as a DTLS transport does when a session ends.</summary>
    /// <param name="remoteEndPoint">The peer's address.</param>
    public void ClosePeer(IPEndPoint remoteEndPoint) => _receiver?.OnPeerClosed(PeerFor(remoteEndPoint));

    /// <inheritdoc />
    public ValueTask DisposeAsync()
    {
        _network.Remove(_address);
        return ValueTask.CompletedTask;
    }

    internal void Deliver(IPEndPoint from, byte[] bytes) => _receiver?.OnDatagram(PeerFor(from), (byte[])bytes.Clone());
}

/// <summary>A peer on an in-memory transport that simulates an authenticated session.</summary>
/// <param name="RemoteEndPoint">The peer's address.</param>
/// <param name="Security">The simulated security details.</param>
public sealed record InMemoryPeer(EndPoint RemoteEndPoint, CoapPeerSecurity? Security) : ICoapPeer;

using System.Threading.Channels;
using Wick.Coap.Transport;

namespace Wick.Coap;

/// <summary>
/// A client-side observation (RFC 7641 section 3): a registration this endpoint made with a
/// remote resource, and the stream of notifications it produces. Notifications that arrive
/// out of order are dropped by the RFC 7641 section 3.4 rule before they reach
/// <see cref="Notifications"/>.
/// </summary>
public sealed class CoapObservation : IAsyncDisposable
{
    private readonly CoapEndpoint _endpoint;
    private readonly Channel<CoapMessage> _channel;
    private readonly TaskCompletionSource _ended = new(TaskCreationOptions.RunContinuationsAsynchronously);

    internal CoapObservation(CoapEndpoint endpoint, ICoapPeer peer, CoapMessage request, int bufferSize)
    {
        _endpoint = endpoint;
        Peer = peer;
        Request = request;
        Token = request.Token;
        _channel = Channel.CreateBounded<CoapMessage>(new BoundedChannelOptions(bufferSize)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleWriter = false,
            SingleReader = false,
        });
    }

    /// <summary>The peer being observed.</summary>
    public ICoapPeer Peer { get; }

    /// <summary>The token of the registration; every notification echoes it.</summary>
    public byte[] Token { get; }

    /// <summary>The registration request as sent, with Observe: 0.</summary>
    public CoapMessage Request { get; }

    /// <summary>The response to the registration, with any Block2 body reassembled.</summary>
    public CoapMessage InitialResponse { get; internal set; } = new();

    /// <summary>
    /// True when the server accepted the registration: the initial response was a success and
    /// carried an Observe option. When false, <see cref="Notifications"/> is already complete.
    /// </summary>
    public bool IsRegistered { get; internal set; }

    /// <summary>
    /// Notifications in the order accepted. The reader completes when the observation ends:
    /// cancelled, rejected by the server, ended with a non-2.xx notification, or because the
    /// peer's session closed.
    /// </summary>
    public ChannelReader<CoapMessage> Notifications => _channel.Reader;

    /// <summary>Completes when the observation has ended.</summary>
    public Task Ended => _ended.Task;

    internal uint? LastSequence { get; set; }

    internal DateTimeOffset LastSequenceAt { get; set; }

    internal bool Active { get; set; }

    /// <summary>
    /// Cancels the observation actively, by sending the registration request again with
    /// Observe: 1 (RFC 7641 section 3.6), and waits for the response.
    /// </summary>
    /// <param name="cancellationToken">Cancels the wait for the response.</param>
    /// <returns>The server's response to the cancellation, or null if the observation had already ended.</returns>
    public Task<CoapMessage?> CancelAsync(CancellationToken cancellationToken = default) =>
        _endpoint.CancelObservationAsync(this, cancellationToken);

    /// <summary>
    /// Forgets the observation locally. The next notification is answered with a Reset, which
    /// ends the relation on the server (RFC 7641 section 3.6).
    /// </summary>
    /// <returns>A completed task.</returns>
    public ValueTask DisposeAsync()
    {
        _endpoint.ForgetObservation(this);
        return ValueTask.CompletedTask;
    }

    internal void Deliver(CoapMessage notification) => _channel.Writer.TryWrite(notification);

    internal void End(CoapMessage? final = null)
    {
        if (final is not null) _channel.Writer.TryWrite(final);
        _channel.Writer.TryComplete();
        _ended.TrySetResult();
    }
}

/// <summary>
/// A server-side observation (RFC 7641 section 4.1): a peer that registered interest in a
/// resource on this endpoint. Observations are keyed by peer and token, so one peer may hold
/// several on the same path, which LwM2M Observe-Composite needs.
/// </summary>
public sealed class ServerObservation
{
    internal ServerObservation(ICoapPeer peer, CoapMessage request, DateTimeOffset now, string requestKey)
    {
        Peer = peer;
        Token = request.Token;
        Request = request;
        RegisteredAt = now;
        LastConfirmableAt = now;
        RequestKey = requestKey;
    }

    /// <summary>The observing peer.</summary>
    public ICoapPeer Peer { get; }

    /// <summary>The token every notification carries.</summary>
    public byte[] Token { get; }

    /// <summary>The registration request, including any FETCH body.</summary>
    public CoapMessage Request { get; internal set; }

    /// <summary>The observed path.</summary>
    public IReadOnlyList<string> UriPath => Request.UriPath;

    /// <summary>When the observation was registered or last refreshed.</summary>
    public DateTimeOffset RegisteredAt { get; internal set; }

    internal uint NextSequence { get; set; } = 1;

    internal DateTimeOffset LastConfirmableAt { get; set; }

    internal CoapEndpoint.OutboundExchange? InFlight { get; set; }

    internal ushort? LastNonMessageId { get; set; }

    internal string RequestKey { get; set; }

    internal uint TakeSequence()
    {
        uint value = NextSequence;
        NextSequence = ObserveSequence.Next(NextSequence);
        return value;
    }
}

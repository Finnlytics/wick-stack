using System.Net;
using Wick.Coap.Transport;

namespace Wick.Coap;

public sealed partial class CoapEndpoint
{
    /// <summary>
    /// Sends a request and waits for the final response. The endpoint assigns a fresh message id
    /// and token, retransmits a confirmable request until it is acknowledged (RFC 7252 section
    /// 4.2), waits for a separate response after an empty acknowledgement, sends a large payload
    /// with Block1 and reassembles a Block2 response (RFC 7959). At most NSTART requests to one
    /// peer are outstanding at once; further ones wait their turn.
    /// </summary>
    /// <param name="peer">The peer.</param>
    /// <param name="request">The request. It is copied, not modified.</param>
    /// <param name="cancellationToken">Abandons the request locally.</param>
    /// <returns>The response, with any block-wise body reassembled.</returns>
    /// <exception cref="CoapTimeoutException">No acknowledgement or no response arrived in time.</exception>
    /// <exception cref="CoapResetException">The peer answered with a Reset.</exception>
    /// <exception cref="CoapPeerClosedException">The peer's session ended.</exception>
    /// <exception cref="CoapBlockwiseException">A block-wise transfer could not be completed.</exception>
    public async Task<CoapMessage> SendAsync(ICoapPeer peer, CoapMessage request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(peer);
        ArgumentNullException.ThrowIfNull(request);
        if (!request.IsRequest) throw new ArgumentException("The message is not a request.", nameof(request));
        if (request.Type is not (CoapMessageType.Confirmable or CoapMessageType.NonConfirmable))
            throw new ArgumentException("A request must be confirmable or non-confirmable.", nameof(request));

        await AcquireSlotAsync(peer, cancellationToken).ConfigureAwait(false);
        try
        {
            return await SendUnthrottledAsync(peer, request.Clone(), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            ReleaseSlot(peer);
        }
    }

    /// <summary>Sends a request to an address. See <see cref="SendAsync(ICoapPeer, CoapMessage, CancellationToken)"/>.</summary>
    /// <param name="remoteEndPoint">The address; the transport must have a peer there.</param>
    /// <param name="request">The request.</param>
    /// <param name="cancellationToken">Abandons the request locally.</param>
    /// <returns>The response.</returns>
    public Task<CoapMessage> SendAsync(EndPoint remoteEndPoint, CoapMessage request, CancellationToken cancellationToken = default) =>
        SendAsync(GetPeer(remoteEndPoint), request, cancellationToken);

    /// <summary>
    /// Sends a CoAP ping, an empty confirmable message, and waits for the Reset that answers it
    /// (RFC 7252 section 4.3). It is retransmitted like any confirmable message.
    /// </summary>
    /// <param name="peer">The peer.</param>
    /// <param name="cancellationToken">Abandons the ping locally.</param>
    /// <returns>A task that completes when the peer answers.</returns>
    /// <exception cref="CoapTimeoutException">The peer did not answer.</exception>
    public async Task PingAsync(ICoapPeer peer, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(peer);
        OutboundExchange exchange;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var ping = new CoapMessage { Type = CoapMessageType.Confirmable, Code = CoapCode.Empty };
            exchange = StartTrackedLocked(OutboundKind.Ping, peer, ping, cancellationToken);
        }
        await exchange.Completion!.Task.ConfigureAwait(false);
    }

    private async Task<CoapMessage> SendUnthrottledAsync(ICoapPeer peer, CoapMessage request, CancellationToken cancellationToken)
    {
        int szx = FitSizeExponent(request, PreferredExponent);
        bool usedBlock1 = false;
        CoapMessage response;
        if (request.Block1 is null && request.Payload.Length > BlockOption.SizeOf(szx))
        {
            usedBlock1 = true;
            response = await SendBlock1Async(peer, request, szx, cancellationToken).ConfigureAwait(false);
        }
        else
        {
            response = await ExchangeAsync(peer, WithFreshToken(request), cancellationToken).ConfigureAwait(false);
        }

        if (response.Block2 is { More: true } && response.Code.IsSuccess)
        {
            var template = request.Clone();
            template.Block1 = null;
            template.RemoveOptions(CoapOptionNumber.Size1);
            if (usedBlock1) template.Payload = ReadOnlyMemory<byte>.Empty;
            response = await CollectBlock2Async(peer, template, response, cancellationToken).ConfigureAwait(false);
        }
        return response;
    }

    private async Task<CoapMessage> SendBlock1Async(ICoapPeer peer, CoapMessage request, int szx, CancellationToken cancellationToken)
    {
        var sender = new BlockSender(request.Payload, szx);
        bool renegotiated = false;
        while (true)
        {
            var (chunk, block) = sender.Current();
            var message = request.Clone();
            message.Payload = chunk;
            message.Block1 = block;
            if (block.Number == 0) message.Size1 = (uint)request.Payload.Length;
            var response = await ExchangeAsync(peer, WithFreshToken(message), cancellationToken).ConfigureAwait(false);

            // RFC 7959 section 2.9.3: 4.13 with a Block1 option names the size the server wants.
            if (response.Code == CoapCode.RequestEntityTooLarge && block.Number == 0 && !renegotiated &&
                response.Block1 is BlockOption preferred && preferred.SizeExponent < sender.SizeExponent)
            {
                sender = new BlockSender(request.Payload, preferred.SizeExponent);
                renegotiated = true;
                continue;
            }

            if (!block.More) return response;
            if (response.Code != CoapCode.Continue || response.Block1 is not BlockOption acknowledged) return response;
            if (!sender.AdvanceAfter(acknowledged)) return response;
        }
    }

    /// <summary>Fetches the remaining blocks of a Block2 response and returns the reassembled whole (RFC 7959 section 2.4).</summary>
    private async Task<CoapMessage> CollectBlock2Async(ICoapPeer peer, CoapMessage template, CoapMessage first, CancellationToken cancellationToken)
    {
        var receiver = new BlockReceiver(_options.MaxBodySize);
        var block = first.Block2!.Value;
        if (block.Number != 0) throw new CoapBlockwiseException($"Block-wise response started at block {block.Number}, not 0.");
        var status = receiver.Add(block, first.Payload.Span);
        CheckBlockStatus(status);
        byte[]? etag = first.ETag;

        while (status != BlockReceiveStatus.Complete)
        {
            var next = template.Clone();
            next.RemoveOptions(CoapOptionNumber.Observe);
            next.Block1 = null;
            int szx = receiver.SizeExponent!.Value;
            next.Block2 = new BlockOption(receiver.Length / BlockOption.SizeOf(szx), false, szx);
            var response = await ExchangeAsync(peer, WithFreshToken(next), cancellationToken).ConfigureAwait(false);
            if (!response.Code.IsSuccess) return response;
            if (response.Block2 is not BlockOption received)
                throw new CoapBlockwiseException("A block-wise continuation response carried no Block2 option.");
            var responseTag = response.ETag;
            if (etag is not null && (responseTag is null || !etag.AsSpan().SequenceEqual(responseTag)))
                throw new CoapBlockwiseException("The representation changed during the block-wise transfer (ETag differs).");
            status = receiver.Add(received, response.Payload.Span);
            CheckBlockStatus(status);
        }

        var assembled = first.Clone();
        assembled.Payload = receiver.Body.ToArray();
        assembled.Block2 = null;
        assembled.RemoveOptions(CoapOptionNumber.Size2);
        return assembled;
    }

    private static void CheckBlockStatus(BlockReceiveStatus status)
    {
        switch (status)
        {
            case BlockReceiveStatus.OutOfOrder:
                throw new CoapBlockwiseException("A block arrived out of order.");
            case BlockReceiveStatus.WrongSize:
                throw new CoapBlockwiseException("A block did not match its size exponent.");
            case BlockReceiveStatus.TooLarge:
                throw new CoapBlockwiseException("The block-wise body exceeds the configured maximum.");
        }
    }

    private CoapMessage WithFreshToken(CoapMessage message)
    {
        message.Token = TokenGenerator.Create(_options.TokenLength);
        return message;
    }

    /// <summary>Sends one request message and waits for its response, without block-wise handling.</summary>
    private Task<CoapMessage> ExchangeAsync(ICoapPeer peer, CoapMessage message, CancellationToken cancellationToken)
    {
        OutboundExchange exchange;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_awaitingResponse.ContainsKey((peer, TokenKey.From(message.Token))))
                throw new CoapException("A request with this token is already outstanding.");
            exchange = StartTrackedLocked(OutboundKind.Request, peer, message, cancellationToken);
        }
        return exchange.Completion!.Task;
    }

    private OutboundExchange StartTrackedLocked(OutboundKind kind, ICoapPeer peer, CoapMessage message, CancellationToken cancellationToken)
    {
        // The completion must exist before the send, which can fail synchronously.
        var completion = new TaskCompletionSource<CoapMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var exchange = StartOutboundLocked(kind, peer, message, completion: completion);
        if (!exchange.Done && cancellationToken.CanBeCanceled)
        {
            exchange.Cancellation = cancellationToken.UnsafeRegister(static state =>
            {
                var (endpoint, ex, token) = ((CoapEndpoint, OutboundExchange, CancellationToken))state!;
                lock (endpoint._gate)
                {
                    endpoint.FinishLocked(ex);
                    ex.Completion?.TrySetCanceled(token);
                }
            }, (this, exchange, cancellationToken));
        }
        return exchange;
    }

    // ---- NSTART (RFC 7252 section 4.7) ----

    private Task AcquireSlotAsync(ICoapPeer peer, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var state = PeerLocked(peer);
            if (state.ActiveInteractions < _options.Transmission.NStart)
            {
                state.ActiveInteractions++;
                return Task.CompletedTask;
            }
            if (state.Waiters.Count >= _options.MaxQueuedRequestsPerPeer)
                throw new CoapException($"Too many requests are queued for {peer}.");

            var waiter = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var node = state.Waiters.AddLast(waiter);
            if (cancellationToken.CanBeCanceled)
            {
                var registration = cancellationToken.UnsafeRegister(static s =>
                {
                    var (endpoint, st, n, token) = ((CoapEndpoint, PeerState, LinkedListNode<TaskCompletionSource>, CancellationToken))s!;
                    lock (endpoint._gate)
                    {
                        if (n.List is not null) st.Waiters.Remove(n);
                    }
                    n.Value.TrySetCanceled(token);
                }, (this, state, node, cancellationToken));
                _ = waiter.Task.ContinueWith(_ => registration.Unregister(), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            }
            return waiter.Task;
        }
    }

    private void ReleaseSlot(ICoapPeer peer)
    {
        lock (_gate)
        {
            if (!_peers.TryGetValue(peer, out var state)) return;
            while (state.Waiters.First is { } next)
            {
                state.Waiters.RemoveFirst();
                // The slot passes straight to the next waiter, so the count is unchanged.
                if (next.Value.TrySetResult()) return;
            }
            state.ActiveInteractions = Math.Max(0, state.ActiveInteractions - 1);
        }
    }

    // ---- Inbound responses ----

    private void OnResponse(ICoapPeer peer, CoapMessage response)
    {
        CoapObservation? observation = null;
        lock (_gate)
        {
            if (response.Type == CoapMessageType.Acknowledgement)
            {
                // Piggybacked response (RFC 7252 section 5.2.1).
                if (!_awaitingAck.TryGetValue((peer, response.MessageId), out var acked)) return;
                if (acked.Kind == OutboundKind.Request && response.Token.AsSpan().SequenceEqual(acked.Message.Token))
                {
                    NoteRegistrationResponseLocked((peer, TokenKey.From(response.Token)), response);
                    CompleteLocked(acked, response);
                }
                else
                {
                    // An acknowledgement whose response does not match the token still acknowledges the message.
                    OnEmptyAckLocked(peer, response.MessageId);
                }
                return;
            }

            // Separate response or notification, confirmable or not.
            var dedupKey = (peer, response.MessageId);
            if (_dedup.Check(dedupKey, _time.GetUtcNow(), out var cached) == DeduplicationResult.Duplicate)
            {
                if (response.Type == CoapMessageType.Confirmable && cached is not null) SendLocked(peer, cached);
                return;
            }

            var tokenKey = (peer, TokenKey.From(response.Token));
            if (_awaitingResponse.TryGetValue(tokenKey, out var exchange))
            {
                AcknowledgeLocked(peer, response, dedupKey);
                NoteRegistrationResponseLocked(tokenKey, response);
                CompleteLocked(exchange, response);
                return;
            }

            if (_clientObservations.TryGetValue(tokenKey, out observation))
            {
                AcknowledgeLocked(peer, response, dedupKey);
            }
            else
            {
                // No interest in this token: reject it, which also ends a stale observation (RFC 7641 section 3.6).
                var reset = new CoapMessage { Type = CoapMessageType.Reset, MessageId = response.MessageId }.Encode();
                SendLocked(peer, reset);
                _dedup.SetReply(dedupKey, reset);
                return;
            }
        }

        OnNotification(observation, response);
    }

    private void AcknowledgeLocked(ICoapPeer peer, CoapMessage response, (ICoapPeer, ushort) dedupKey)
    {
        if (response.Type != CoapMessageType.Confirmable) return;
        var ack = SendEmptyAckLocked(peer, response.MessageId);
        _dedup.SetReply(dedupKey, ack);
    }
}

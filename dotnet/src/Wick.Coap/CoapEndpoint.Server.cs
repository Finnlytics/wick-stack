using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Logging;
using Wick.Coap.Transport;

namespace Wick.Coap;

public sealed partial class CoapEndpoint
{
    private const int Block1Kind = 1;
    private const int Block2Kind = 2;

    private void OnRequest(ICoapPeer peer, CoapMessage request)
    {
        ServerExchange exchange;
        CoapRequestContext context;
        lock (_gate)
        {
            if (_disposed) return;
            var now = _time.GetUtcNow();
            var key = (peer, request.MessageId);

            // RFC 7252 section 4.5: process a message once; answer a repeated confirmable with the same reply.
            if (_dedup.Check(key, now, out var cached) == DeduplicationResult.Duplicate)
            {
                if (request.Type == CoapMessageType.Confirmable)
                {
                    if (cached is not null) SendLocked(peer, cached);
                    else if (_inProgress.TryGetValue(key, out var running) && !running.AckSent) SendSeparateAckLocked(running);
                }
                return;
            }

            if (RejectionFor(request) is CoapCode rejection)
            {
                if (rejection == CoapCode.BadOption && request.Type == CoapMessageType.NonConfirmable)
                    SendResetLocked(peer, request.MessageId); // RFC 7252 section 5.4.1: reject the non-confirmable message
                else
                    ReplyLocked(peer, request, CoapMessage.CreateResponse(rejection));
                return;
            }

            var state = PeerLocked(peer);
            if (state.HandlersRunning >= _options.MaxConcurrentRequestsPerPeer)
            {
                var busy = CoapMessage.CreateResponse(CoapCode.ServiceUnavailable);
                busy.MaxAge = 1;
                ReplyLocked(peer, request, busy);
                return;
            }

            var dispatched = request;
            BlockOption? finalBlock1 = null;
            if (request.Block1 is BlockOption block1)
            {
                if (!TryReceiveBlock1Locked(peer, request, block1, out dispatched, out finalBlock1)) return;
            }

            if (request.Block2 is { Number: > 0 } block2 && TryServeBlock2Locked(peer, request, block2)) return;

            var observe = ObserveActionOf(request);
            if (observe == ObserveAction.Deregister)
                RemoveServerObservationLocked((peer, TokenKey.From(request.Token)));

            exchange = new ServerExchange(peer, request, dispatched, observe) { FinalBlock1 = finalBlock1 };
            state.HandlersRunning++;
            _inProgress[key] = exchange;
            if (request.Type == CoapMessageType.Confirmable)
                exchange.AckTimer = _time.CreateTimer(OnSeparateAckTimer, exchange, _options.SeparateResponseDelay, Timeout.InfiniteTimeSpan);
            context = new CoapRequestContext(this, peer, dispatched, observe, state.AbortToken(_stopping.Token));
        }

        _ = RunHandlerAsync(exchange, context);
    }

    private async Task RunHandlerAsync(ServerExchange exchange, CoapRequestContext context)
    {
        CoapMessage? response;
        try
        {
            var handler = Handler;
            response = handler is null
                ? CoapMessage.CreateResponse(CoapCode.NotFound)
                : await handler.HandleAsync(context).ConfigureAwait(false);
            if (response is not null && !response.Code.IsResponse)
            {
                _logger.LogError("Handler returned {Code}, which is not a response code, for {Path}", response.Code, context.Request.UriPathString);
                response = CoapMessage.CreateResponse(CoapCode.InternalServerError);
            }
        }
        catch (Exception e)
        {
            _logger.LogError(e, "Handler failed for {Method} {Path} from {Peer}", context.Request.Code, context.Request.UriPathString, context.Peer);
            response = CoapMessage.CreateResponse(CoapCode.InternalServerError);
        }

        lock (_gate) FinishServerExchangeLocked(exchange, response);
    }

    private void OnSeparateAckTimer(object? state)
    {
        var exchange = (ServerExchange)state!;
        lock (_gate)
        {
            if (!exchange.Done && !exchange.AckSent && !_disposed) SendSeparateAckLocked(exchange);
        }
    }

    private void SendSeparateAckLocked(ServerExchange exchange)
    {
        // RFC 7252 section 5.2.2: acknowledge now, respond later in a separate message.
        exchange.AckSent = true;
        var ack = SendEmptyAckLocked(exchange.Peer, exchange.Request.MessageId);
        _dedup.SetReply((exchange.Peer, exchange.Request.MessageId), ack);
    }

    private void FinishServerExchangeLocked(ServerExchange exchange, CoapMessage? response)
    {
        if (exchange.Done) return;
        exchange.Done = true;
        exchange.AckTimer?.Dispose();
        var peer = exchange.Peer;
        var request = exchange.Request;
        var key = (peer, request.MessageId);
        if (_inProgress.TryGetValue(key, out var current) && ReferenceEquals(current, exchange)) _inProgress.Remove(key);
        if (_peers.TryGetValue(peer, out var state)) state.HandlersRunning = Math.Max(0, state.HandlersRunning - 1);
        if (_disposed) return;

        if (response is null)
        {
            if (request.Type == CoapMessageType.Confirmable && !exchange.AckSent) SendSeparateAckLocked(exchange);
            return;
        }

        response = response.Clone();
        response.Token = request.Token;
        response.RemoveOptions(CoapOptionNumber.Observe);

        if (exchange.Observe == ObserveAction.Register)
        {
            var tokenKey = (peer, TokenKey.From(request.Token));
            if (response.Code.IsSuccess)
            {
                if (RegisterServerObservationLocked(peer, exchange.Dispatched, tokenKey) is { } relation)
                    response.Observe = relation.TakeSequence();
            }
            else
            {
                // RFC 7641 section 4.1: an error response ends any existing observation with this token.
                RemoveServerObservationLocked(tokenKey);
            }
        }

        if (exchange.FinalBlock1 is BlockOption block1) response.Block1 = block1;
        response = ApplyBlock2Locked(peer, request, response, RequestKey(request));
        SendResponseLocked(exchange, response);
    }

    private void SendResponseLocked(ServerExchange exchange, CoapMessage response)
    {
        var peer = exchange.Peer;
        var request = exchange.Request;
        try
        {
            if (request.Type == CoapMessageType.Confirmable && !exchange.AckSent)
            {
                // Piggybacked (RFC 7252 section 5.2.1).
                response.Type = CoapMessageType.Acknowledgement;
                response.MessageId = request.MessageId;
                var bytes = EncodeForPeer(response);
                SendLocked(peer, bytes);
                _dedup.SetReply((peer, request.MessageId), bytes);
            }
            else if (request.Type == CoapMessageType.Confirmable)
            {
                // Separate response, sent confirmable and retransmitted (RFC 7252 section 5.2.2).
                response.Type = CoapMessageType.Confirmable;
                StartOutboundLocked(OutboundKind.SeparateResponse, peer, response);
            }
            else
            {
                response.Type = CoapMessageType.NonConfirmable;
                response.MessageId = PeerLocked(peer).MessageIds.Next();
                SendLocked(peer, EncodeForPeer(response));
            }
        }
        catch (CoapException e)
        {
            _logger.LogError(e, "Could not send the response to {Peer}", peer);
        }
    }

    /// <summary>Sends an immediate reply that bypasses the handler: piggybacked for a confirmable request, non-confirmable otherwise.</summary>
    private void ReplyLocked(ICoapPeer peer, CoapMessage request, CoapMessage response)
    {
        response.Token = request.Token;
        if (request.Type == CoapMessageType.Confirmable)
        {
            response.Type = CoapMessageType.Acknowledgement;
            response.MessageId = request.MessageId;
            var bytes = EncodeForPeer(response);
            SendLocked(peer, bytes);
            _dedup.SetReply((peer, request.MessageId), bytes);
        }
        else
        {
            response.Type = CoapMessageType.NonConfirmable;
            response.MessageId = PeerLocked(peer).MessageIds.Next();
            SendLocked(peer, EncodeForPeer(response));
        }
    }

    private byte[] EncodeForPeer(CoapMessage response)
    {
        var bytes = response.Encode();
        if (bytes.Length <= _transport.MaxMessageSize) return bytes;
        _logger.LogError("Response of {Length} bytes exceeds the transport limit; sending 5.00 instead", bytes.Length);
        var error = new CoapMessage
        {
            Type = response.Type,
            Code = CoapCode.InternalServerError,
            MessageId = response.MessageId,
            Token = response.Token,
        };
        return error.Encode();
    }

    /// <summary>
    /// Checks the options of a request (RFC 7252 section 5.4): an unrecognised or malformed
    /// critical option, or a repeated non-repeatable critical one, is 4.02; proxy options are
    /// 5.05 since this endpoint is not a proxy.
    /// </summary>
    private CoapCode? RejectionFor(CoapMessage request)
    {
        int previous = -1;
        int repeats = 0;
        foreach (var option in request.Options.OrderBy(o => o.Number))
        {
            repeats = option.Number == previous ? repeats + 1 : 0;
            previous = option.Number;
            bool critical = CoapOptionNumber.IsCritical(option.Number);
            if (OptionDefinitions.TryGet(option.Number, out var definition))
            {
                bool badLength = option.Length < definition.MinLength || option.Length > definition.MaxLength;
                bool badRepeat = repeats > 0 && !definition.Repeatable;
                if (critical && (badLength || badRepeat)) return CoapCode.BadOption;
            }
            else if (critical && !_options.AdditionalRecognisedOptions.Contains(option.Number))
            {
                return CoapCode.BadOption;
            }
        }

        if (request.HasOption(CoapOptionNumber.ProxyUri) || request.HasOption(CoapOptionNumber.ProxyScheme))
            return CoapCode.ProxyingNotSupported;
        if (request.HasOption(CoapOptionNumber.Block1) && request.Block1 is null) return CoapCode.BadOption;
        if (request.HasOption(CoapOptionNumber.Block2) && request.Block2 is null) return CoapCode.BadOption;
        return null;
    }

    private static ObserveAction ObserveActionOf(CoapMessage request)
    {
        if (request.Code != CoapCode.Get && request.Code != CoapCode.Fetch) return ObserveAction.None;
        return request.Observe switch
        {
            ObserveSequence.Register => ObserveAction.Register,
            ObserveSequence.Deregister => ObserveAction.Deregister,
            _ => ObserveAction.None,
        };
    }

    /// <summary>
    /// The identity of a request for matching the blocks of one transfer (RFC 7959 section 2.4):
    /// method, Uri-Host, Uri-Port, Uri-Path, Uri-Query, Accept, and for FETCH the Content-Format
    /// and body. Tokens are deliberately not part of it, since each block may use a new one.
    /// </summary>
    internal static string RequestKey(CoapMessage request)
    {
        var builder = new StringBuilder();
        builder.Append(request.Code.Value);
        bool fetch = request.Code == CoapCode.Fetch;
        foreach (var option in request.Options.OrderBy(o => o.Number))
        {
            bool include = option.Number is CoapOptionNumber.UriHost or CoapOptionNumber.UriPort or CoapOptionNumber.UriPath
                or CoapOptionNumber.UriQuery or CoapOptionNumber.Accept
                || (fetch && option.Number == CoapOptionNumber.ContentFormat);
            if (!include) continue;
            builder.Append('|').Append(option.Number).Append(':').Append(Convert.ToHexString(option.Value.Span));
        }
        if (fetch && request.Block1 is null && !request.Payload.IsEmpty)
            builder.Append("|body:").Append(Convert.ToHexString(SHA256.HashData(request.Payload.Span), 0, 16));
        return builder.ToString();
    }

    // ---- Block-wise, server side ----

    private bool TryReceiveBlock1Locked(ICoapPeer peer, CoapMessage request, BlockOption block1, out CoapMessage dispatched, out BlockOption? finalBlock1)
    {
        dispatched = request;
        finalBlock1 = null;
        var now = _time.GetUtcNow();
        var requestKey = RequestKey(request);
        var key = (peer, requestKey);

        Block1Transfer? transfer;
        if (block1.Number == 0)
        {
            if (request.Size1 is uint total && total > _options.MaxBodySize)
            {
                ReplyTooLargeLocked(peer, request);
                return false;
            }
            transfer = new Block1Transfer(new BlockReceiver(_options.MaxBodySize), now + _options.Transmission.ExchangeLifetime);
            _block1In[key] = transfer;
            TrackTransferLocked(peer, Block1Kind, requestKey);
        }
        else if (!_block1In.TryGetValue(key, out transfer))
        {
            ReplyLocked(peer, request, CoapMessage.CreateResponse(CoapCode.RequestEntityIncomplete));
            return false;
        }

        var status = transfer.Receiver.Add(block1, request.Payload.Span);
        switch (status)
        {
            case BlockReceiveStatus.Continue:
            case BlockReceiveStatus.Duplicate:
            {
                transfer.ExpiresAt = now + _options.Transmission.ExchangeLifetime;
                int ours = PreferredExponent;
                // RFC 7959 section 2.5: a server may ask for smaller blocks by answering with a smaller SZX.
                var acknowledged = block1.SizeExponent <= ours
                    ? new BlockOption(block1.Number, true, block1.SizeExponent)
                    : new BlockOption((int)(block1.Offset / BlockOption.SizeOf(ours)), true, ours);
                var proceed = CoapMessage.CreateResponse(CoapCode.Continue);
                proceed.Block1 = acknowledged;
                ReplyLocked(peer, request, proceed);
                return false;
            }
            case BlockReceiveStatus.Complete:
            {
                _block1In.Remove(key);
                UntrackTransferLocked(peer, Block1Kind, requestKey);
                var assembled = request.Clone();
                assembled.Payload = transfer.Receiver.Body.ToArray();
                assembled.Block1 = null;
                assembled.RemoveOptions(CoapOptionNumber.Size1);
                dispatched = assembled;
                finalBlock1 = new BlockOption(block1.Number, false, block1.SizeExponent);
                return true;
            }
            case BlockReceiveStatus.TooLarge:
                _block1In.Remove(key);
                UntrackTransferLocked(peer, Block1Kind, requestKey);
                ReplyTooLargeLocked(peer, request);
                return false;
            default:
                // RFC 7959 section 2.9.2: blocks missing or out of order.
                _block1In.Remove(key);
                UntrackTransferLocked(peer, Block1Kind, requestKey);
                ReplyLocked(peer, request, CoapMessage.CreateResponse(CoapCode.RequestEntityIncomplete));
                return false;
        }
    }

    private void ReplyTooLargeLocked(ICoapPeer peer, CoapMessage request)
    {
        var tooLarge = CoapMessage.CreateResponse(CoapCode.RequestEntityTooLarge);
        tooLarge.Size1 = (uint)_options.MaxBodySize;
        ReplyLocked(peer, request, tooLarge);
    }

    /// <summary>Serves a later block of a response held from an earlier request (RFC 7959 section 2.4).</summary>
    private bool TryServeBlock2Locked(ICoapPeer peer, CoapMessage request, BlockOption requested)
    {
        var requestKey = RequestKey(request);
        if (!_block2Out.TryGetValue((peer, requestKey), out var transfer)) return false;

        int szx = Math.Min(requested.SizeExponent, PreferredExponent);
        int number = (int)(requested.Offset / BlockOption.SizeOf(szx));
        var full = transfer.Response;
        if ((long)number * BlockOption.SizeOf(szx) >= full.Payload.Length)
        {
            ReplyLocked(peer, request, CoapMessage.CreateResponse(CoapCode.BadOption));
            return true;
        }

        var (chunk, block) = BlockSender.Slice(full.Payload, number, szx);
        var part = full.Clone();
        part.RemoveOptions(CoapOptionNumber.Observe);
        part.RemoveOptions(CoapOptionNumber.Block1);
        part.RemoveOptions(CoapOptionNumber.Size2);
        part.Payload = chunk;
        part.Block2 = block;
        if (block.More)
        {
            transfer.ExpiresAt = _time.GetUtcNow() + _options.Transmission.ExchangeLifetime;
        }
        else
        {
            _block2Out.Remove((peer, requestKey));
            UntrackTransferLocked(peer, Block2Kind, requestKey);
        }
        ReplyLocked(peer, request, part);
        return true;
    }

    /// <summary>Cuts a large response down to the requested block and keeps the whole for later blocks.</summary>
    private CoapMessage ApplyBlock2Locked(ICoapPeer peer, CoapMessage request, CoapMessage response, string requestKey)
    {
        int szx = Math.Min(FitSizeExponent(response, PreferredExponent), request.Block2?.SizeExponent ?? 6);
        int size = BlockOption.SizeOf(szx);
        int number = request.Block2 is BlockOption asked ? (int)(asked.Offset / size) : 0;
        if (response.Payload.Length <= size && number == 0) return response;
        if (number > 0 && (long)number * size >= response.Payload.Length)
        {
            var bad = CoapMessage.CreateResponse(CoapCode.BadOption);
            bad.Token = response.Token;
            return bad;
        }

        var (chunk, block) = BlockSender.Slice(response.Payload, number, szx);
        if (block.More) StoreBlock2Locked(peer, requestKey, response);
        var part = response.Clone();
        part.Payload = chunk;
        part.Block2 = block;
        if (number == 0) part.Size2 = (uint)response.Payload.Length;
        return part;
    }

    private void StoreBlock2Locked(ICoapPeer peer, string requestKey, CoapMessage fullResponse)
    {
        _block2Out[(peer, requestKey)] = new Block2Transfer(fullResponse.Clone(), _time.GetUtcNow() + _options.Transmission.ExchangeLifetime);
        TrackTransferLocked(peer, Block2Kind, requestKey);
    }

    private void TrackTransferLocked(ICoapPeer peer, int kind, string requestKey)
    {
        var transfers = PeerLocked(peer).BlockTransfers;
        transfers.Remove((kind, requestKey));
        transfers.AddLast((kind, requestKey));
        while (transfers.Count > _options.MaxBlockTransfersPerPeer)
        {
            var (oldestKind, oldestKey) = transfers.First!.Value;
            transfers.RemoveFirst();
            if (oldestKind == Block1Kind) _block1In.Remove((peer, oldestKey));
            else _block2Out.Remove((peer, oldestKey));
        }
    }

    private void UntrackTransferLocked(ICoapPeer peer, int kind, string requestKey)
    {
        if (_peers.TryGetValue(peer, out var state)) state.BlockTransfers.Remove((kind, requestKey));
    }
}

using Microsoft.Extensions.Logging;
using Wick.Coap.Transport;

namespace Wick.Coap;

public sealed partial class CoapEndpoint
{
    // ---- Client side (RFC 7641 section 3) ----

    /// <summary>
    /// Registers an observation of a remote resource (RFC 7641 section 3.1): sends the request
    /// with Observe: 0 and a fresh token, and returns once the first response has arrived.
    /// Later notifications appear on <see cref="CoapObservation.Notifications"/>; confirmable
    /// ones are acknowledged, stale ones dropped by the section 3.4 ordering rule, and a
    /// notification carrying the first block of a larger body is completed with Block2
    /// requests before it is delivered.
    /// </summary>
    /// <param name="peer">The peer.</param>
    /// <param name="request">A GET or FETCH request. It is copied, not modified.</param>
    /// <param name="cancellationToken">Abandons the registration while it is in progress.</param>
    /// <returns>The observation; check <see cref="CoapObservation.IsRegistered"/>.</returns>
    public async Task<CoapObservation> ObserveAsync(ICoapPeer peer, CoapMessage request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(peer);
        ArgumentNullException.ThrowIfNull(request);
        if (request.Code != CoapCode.Get && request.Code != CoapCode.Fetch)
            throw new ArgumentException("Only GET and FETCH can register an observation.", nameof(request));

        var registration = request.Clone();
        registration.Observe = ObserveSequence.Register;
        registration.Block2 = null;
        WithFreshToken(registration);
        var observation = new CoapObservation(this, peer, registration, _options.NotificationBufferSize);
        var key = (peer, TokenKey.From(registration.Token));

        await AcquireSlotAsync(peer, cancellationToken).ConfigureAwait(false);
        try
        {
            lock (_gate)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                _clientObservations[key] = observation;
                observation.Active = true;
            }

            CoapMessage response;
            try
            {
                response = await ExchangeAsync(peer, registration.Clone(), cancellationToken).ConfigureAwait(false);
                if (response.Code.IsSuccess && response.Block2 is { More: true })
                {
                    var template = registration.Clone();
                    template.RemoveOptions(CoapOptionNumber.Observe);
                    response = await CollectBlock2Async(peer, template, response, cancellationToken).ConfigureAwait(false);
                }
            }
            catch
            {
                ForgetObservation(observation);
                throw;
            }

            observation.InitialResponse = response;
            if (response.Code.IsSuccess && response.Observe is not null)
            {
                observation.IsRegistered = true;
            }
            else
            {
                // The server declined: it answered without Observe, or with an error (RFC 7641 section 3.1).
                ForgetObservation(observation);
            }
            return observation;
        }
        finally
        {
            ReleaseSlot(peer);
        }
    }

    internal async Task<CoapMessage?> CancelObservationAsync(CoapObservation observation, CancellationToken cancellationToken)
    {
        var key = (observation.Peer, TokenKey.From(observation.Token));
        lock (_gate)
        {
            if (!_clientObservations.TryGetValue(key, out var current) || !ReferenceEquals(current, observation)) return null;
            _clientObservations.Remove(key);
            observation.Active = false;
        }
        observation.End();

        // RFC 7641 section 3.6: repeat the registration with Observe: 1 and the same token.
        var cancel = observation.Request.Clone();
        cancel.Observe = ObserveSequence.Deregister;
        await AcquireSlotAsync(observation.Peer, cancellationToken).ConfigureAwait(false);
        try
        {
            var response = await ExchangeAsync(observation.Peer, cancel, cancellationToken).ConfigureAwait(false);
            if (response.Code.IsSuccess && response.Block2 is { More: true })
            {
                var template = cancel.Clone();
                template.RemoveOptions(CoapOptionNumber.Observe);
                response = await CollectBlock2Async(observation.Peer, template, response, cancellationToken).ConfigureAwait(false);
            }
            return response;
        }
        finally
        {
            ReleaseSlot(observation.Peer);
        }
    }

    internal void ForgetObservation(CoapObservation observation)
    {
        var key = (observation.Peer, TokenKey.From(observation.Token));
        lock (_gate)
        {
            if (_clientObservations.TryGetValue(key, out var current) && ReferenceEquals(current, observation))
                _clientObservations.Remove(key);
            observation.Active = false;
        }
        observation.End();
    }

    /// <summary>Records the sequence number of a response to a registration, under the lock, so a notification that overtakes it is ordered correctly.</summary>
    private void NoteRegistrationResponseLocked((ICoapPeer, TokenKey) key, CoapMessage response)
    {
        if (!_clientObservations.TryGetValue(key, out var observation)) return;
        if (response.Observe is not uint sequence) return;
        var now = _time.GetUtcNow();
        if (ObserveSequence.IsNewer(sequence, now, observation.LastSequence, observation.LastSequenceAt))
        {
            observation.LastSequence = sequence;
            observation.LastSequenceAt = now;
        }
    }

    private void OnNotification(CoapObservation observation, CoapMessage notification)
    {
        bool ended = false;
        bool needsBlocks = false;
        lock (_gate)
        {
            if (!observation.Active) return;
            var now = _time.GetUtcNow();
            if (!notification.Code.IsSuccess || notification.Observe is not uint sequence)
            {
                // RFC 7641 section 3.2: a notification without Observe, or an error, ends the observation.
                _clientObservations.Remove((observation.Peer, TokenKey.From(observation.Token)));
                observation.Active = false;
                ended = true;
            }
            else
            {
                if (!ObserveSequence.IsNewer(sequence, now, observation.LastSequence, observation.LastSequenceAt)) return;
                observation.LastSequence = sequence;
                observation.LastSequenceAt = now;
                needsBlocks = notification.Block2 is { More: true };
            }
        }

        if (ended) observation.End(notification);
        else if (needsBlocks) _ = CompleteNotificationAsync(observation, notification);
        else observation.Deliver(notification);
    }

    /// <summary>Fetches the rest of a notification that carried only its first block (RFC 7959 section 3.4).</summary>
    private async Task CompleteNotificationAsync(CoapObservation observation, CoapMessage first)
    {
        try
        {
            var token = _stopping.Token;
            await AcquireSlotAsync(observation.Peer, token).ConfigureAwait(false);
            try
            {
                var template = observation.Request.Clone();
                template.RemoveOptions(CoapOptionNumber.Observe);
                var whole = await CollectBlock2Async(observation.Peer, template, first, token).ConfigureAwait(false);
                if (observation.Active) observation.Deliver(whole);
            }
            finally
            {
                ReleaseSlot(observation.Peer);
            }
        }
        catch (Exception e)
        {
            _logger.LogDebug(e, "Could not complete a block-wise notification from {Peer}", observation.Peer);
        }
    }

    // ---- Server side (RFC 7641 section 4) ----

    /// <summary>Returns a snapshot of the observations peers hold on this endpoint.</summary>
    /// <returns>The observations.</returns>
    public IReadOnlyList<ServerObservation> GetServerObservations()
    {
        lock (_gate) return [.. _serverObservations.Values];
    }

    /// <summary>
    /// Sends a notification to one observer (RFC 7641 section 4.2). The endpoint sets the token,
    /// a fresh message id and the next sequence number, splits a large payload into blocks, and
    /// chooses confirmable when <paramref name="confirmable"/> is null and either a confirmable
    /// notification is already in flight, which this one replaces (section 4.5.2), or none has
    /// been sent within <see cref="CoapEndpointOptions.ConfirmableNotificationInterval"/>.
    /// A response code other than 2.xx ends the observation after it is sent.
    /// </summary>
    /// <param name="observation">The observation.</param>
    /// <param name="notification">The response to send: code, options and payload.</param>
    /// <param name="confirmable">Forces confirmable or non-confirmable, or null to let the endpoint decide.</param>
    /// <returns>False when the observation no longer exists.</returns>
    public bool Notify(ServerObservation observation, CoapMessage notification, bool? confirmable = null)
    {
        ArgumentNullException.ThrowIfNull(observation);
        ArgumentNullException.ThrowIfNull(notification);
        if (!notification.Code.IsResponse) throw new ArgumentException("A notification must carry a response code.", nameof(notification));
        lock (_gate) return NotifyLocked(observation, notification, confirmable);
    }

    /// <summary>Notifies every observer that matches a predicate.</summary>
    /// <param name="predicate">Selects the observations.</param>
    /// <param name="build">Builds the notification for one observation, or returns null to skip it.</param>
    /// <returns>The number of notifications sent.</returns>
    public int NotifyObservers(Func<ServerObservation, bool> predicate, Func<ServerObservation, CoapMessage?> build)
    {
        ArgumentNullException.ThrowIfNull(predicate);
        ArgumentNullException.ThrowIfNull(build);
        int count = 0;
        foreach (var observation in GetServerObservations().Where(predicate))
        {
            if (build(observation) is { } notification && Notify(observation, notification)) count++;
        }
        return count;
    }

    /// <summary>Notifies every observer of a path with the same notification.</summary>
    /// <param name="path">The path, for example <c>/3/0</c>.</param>
    /// <param name="notification">The notification.</param>
    /// <returns>The number of notifications sent.</returns>
    public int NotifyObservers(string path, CoapMessage notification)
    {
        var segments = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return NotifyObservers(o => o.UriPath.SequenceEqual(segments, StringComparer.Ordinal), _ => notification);
    }

    /// <summary>Removes a server-side observation without telling the peer.</summary>
    /// <param name="observation">The observation.</param>
    /// <returns>False when it had already ended.</returns>
    public bool RemoveServerObservation(ServerObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        lock (_gate)
        {
            var key = (observation.Peer, TokenKey.From(observation.Token));
            if (!_serverObservations.TryGetValue(key, out var current) || !ReferenceEquals(current, observation)) return false;
            RemoveServerObservationLocked(key);
            return true;
        }
    }

    private bool NotifyLocked(ServerObservation observation, CoapMessage notification, bool? confirmable)
    {
        var peer = observation.Peer;
        var key = (peer, TokenKey.From(observation.Token));
        if (_disposed || !_serverObservations.TryGetValue(key, out var current) || !ReferenceEquals(current, observation)) return false;

        var now = _time.GetUtcNow();
        var message = notification.Clone();
        message.Token = observation.Token;
        message.RemoveOptions(CoapOptionNumber.Observe);
        message.RemoveOptions(CoapOptionNumber.Block1);
        bool ending = !message.Code.IsSuccess;
        if (!ending) message.Observe = observation.TakeSequence();
        message = ApplyBlock2Locked(peer, observation.Request, message, observation.RequestKey);

        bool con = confirmable ?? (observation.InFlight is not null || now - observation.LastConfirmableAt >= _options.ConfirmableNotificationInterval);
        RetransmissionState? carried = null;
        if (observation.InFlight is { } previous)
        {
            // RFC 7641 section 4.5.2: the new notification replaces the one in flight and keeps its retransmission state.
            carried = con ? previous.Retransmission : null;
            FinishLocked(previous);
            observation.InFlight = null;
        }
        if (observation.LastNonMessageId is ushort oldId)
        {
            _nonNotifications.Remove((peer, oldId));
            observation.LastNonMessageId = null;
        }

        try
        {
            if (con)
            {
                message.Type = CoapMessageType.Confirmable;
                var exchange = StartOutboundLocked(OutboundKind.Notification, peer, message, continueFrom: carried, observation: observation);
                if (!exchange.Done) observation.InFlight = exchange;
                observation.LastConfirmableAt = now;
            }
            else
            {
                message.Type = CoapMessageType.NonConfirmable;
                message.MessageId = PeerLocked(peer).MessageIds.Next();
                SendLocked(peer, EncodeForPeer(message));
                observation.LastNonMessageId = message.MessageId;
                _nonNotifications[(peer, message.MessageId)] = observation;
            }
        }
        catch (CoapException e)
        {
            _logger.LogError(e, "Could not send a notification to {Peer}", peer);
            return false;
        }

        if (ending)
        {
            observation.InFlight = null; // let a final confirmable notification finish its retransmissions
            RemoveServerObservationLocked(key);
        }
        return true;
    }

    private ServerObservation? RegisterServerObservationLocked(ICoapPeer peer, CoapMessage request, (ICoapPeer, TokenKey) key)
    {
        var now = _time.GetUtcNow();
        var stored = request.Clone();
        stored.RemoveOptions(CoapOptionNumber.Observe);
        stored.RemoveOptions(CoapOptionNumber.Block1);
        stored.RemoveOptions(CoapOptionNumber.Block2);
        stored.RemoveOptions(CoapOptionNumber.Size1);
        stored.RemoveOptions(CoapOptionNumber.Size2);
        var requestKey = RequestKey(stored);

        if (_serverObservations.TryGetValue(key, out var existing))
        {
            // RFC 7641 section 4.1: a registration with the same peer and token replaces the existing entry.
            existing.Request = stored;
            existing.RequestKey = requestKey;
            existing.RegisteredAt = now;
            return existing;
        }

        var state = PeerLocked(peer);
        if (state.Observations >= _options.MaxObservationsPerPeer) return null;
        var observation = new ServerObservation(peer, stored, now, requestKey);
        _serverObservations[key] = observation;
        state.Observations++;
        return observation;
    }

    private void RemoveServerObservationLocked((ICoapPeer Peer, TokenKey Token) key)
    {
        if (!_serverObservations.Remove(key, out var observation)) return;
        if (_peers.TryGetValue(key.Peer, out var state)) state.Observations = Math.Max(0, state.Observations - 1);
        if (observation.InFlight is { } inFlight)
        {
            FinishLocked(inFlight);
            observation.InFlight = null;
        }
        if (observation.LastNonMessageId is ushort id) _nonNotifications.Remove((key.Peer, id));
        Raise(ServerObservationEnded, observation);
    }
}

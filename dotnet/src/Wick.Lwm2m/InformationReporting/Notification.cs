using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.DeviceManagement;
using Wick.Lwm2m.Model;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.InformationReporting;

/// <summary>
/// A notification decoded against the relation it belongs to (OMA LwM2M 1.2 §6.4.5, RFC 7641).
/// </summary>
/// <remarks>
/// A success notification carries a 2.05 code, the Observe option and the new value. An error
/// code (4.04 when the Resource was deleted, for example) ends the relation (RFC 7641 §3.2); the
/// server should then remove it from its store.
/// </remarks>
public sealed record Notification
{
    private Notification(Observation observation, ResponseCode code)
    {
        Observation = observation;
        Code = code;
    }

    /// <summary>The relation the notification belongs to.</summary>
    public Observation Observation { get; }

    /// <summary>The response code.</summary>
    public ResponseCode Code { get; }

    /// <summary>True for a 2.xx notification; false when the client has ended the relation with an error.</summary>
    public bool IsSuccess => Code.IsSuccess;

    /// <summary>The Observe sequence number, or <see langword="null"/> on an error notification.</summary>
    public uint? Sequence { get; private init; }

    /// <summary>The payload's Content-Format, or <see langword="null"/> on error.</summary>
    public int? ContentFormat { get; private init; }

    /// <summary>
    /// The new value at the observed path for a single-path relation, or <see langword="null"/>
    /// for a Composite relation and on error.
    /// </summary>
    public Lwm2mNode? Node { get; private init; }

    /// <summary>
    /// The new values per observed path for a Composite relation, in relation order, or empty for a
    /// single-path relation and on error. A <see langword="null"/> node means no value was reported there.
    /// </summary>
    public IReadOnlyList<KeyValuePair<Lwm2mPath, Lwm2mNode?>> Nodes { get; private init; } = [];

    /// <summary>The diagnostic text of an error notification, or <see langword="null"/>.</summary>
    public string? ErrorMessage { get; private init; }

    /// <summary>Decodes a notification for <paramref name="observation"/>.</summary>
    /// <remarks>
    /// This does not judge freshness. Run <see cref="IObservationStore.Accept"/> (or
    /// <see cref="Observation.Accept"/>) with <see cref="WireResponse.Observe"/> first and only decode
    /// fresh notifications.
    /// </remarks>
    /// <param name="response">The notification as it arrived.</param>
    /// <param name="observation">The relation, found by the notification's token.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The decoded notification.</returns>
    /// <exception cref="Lwm2mException">
    /// <see cref="Lwm2mErrorCode.InvalidResponse"/> for a success code other than 2.05 or a 2.05 without
    /// the Observe option, or a codec error when the payload does not decode.
    /// </exception>
    public static Notification Parse(WireResponse response, Observation observation, ILwm2mModel? model = null)
    {
        ArgumentNullException.ThrowIfNull(response);
        ArgumentNullException.ThrowIfNull(observation);
        if (response.Code.IsError)
        {
            return new Notification(observation, response.Code)
            {
                ErrorMessage = response.Payload.IsEmpty ? null : response.PayloadText,
            };
        }

        if (response.Code != ResponseCode.Content || response.Observe is not { } sequence)
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidResponse, $"a notification is a 2.05 carrying the Observe option, not {response}");
        }

        if (observation.IsComposite)
        {
            var contentFormat = response.ContentFormat
                ?? throw new Lwm2mException(Lwm2mErrorCode.InvalidResponse, "a Composite notification needs a Content-Format");
            return new Notification(observation, response.Code)
            {
                Sequence = sequence,
                ContentFormat = contentFormat,
                Nodes = Lwm2mNodeCodec.DecodeComposite(response.Payload.Span, contentFormat, observation.Paths, model),
            };
        }

        var path = observation.Paths[0];
        var format = Lwm2mResponse.ContentFormatOf(response, path);
        return new Notification(observation, response.Code)
        {
            Sequence = sequence,
            ContentFormat = format,
            Node = Lwm2mNodeCodec.Decode(response.Payload.Span, format, path, model),
        };
    }
}

/// <summary>
/// Send (OMA LwM2M 1.2 §6.4.6, LwM2M 1.1 and later): a client pushing values to the server
/// unprompted, as a POST to <c>/dp</c> with a SenML body.
/// </summary>
public sealed record SendRequest
{
    private SendRequest(int contentFormat, ReadOnlyMemory<byte> payload)
    {
        ContentFormat = contentFormat;
        Payload = payload.ToArray();
    }

    /// <summary>The Uri-Path a Send is posted to.</summary>
    public static IReadOnlyList<string> DataPath { get; } = ["dp"];

    /// <summary>The payload's Content-Format: SenML JSON or SenML CBOR.</summary>
    public int ContentFormat { get; }

    /// <summary>The encoded payload.</summary>
    public ReadOnlyMemory<byte> Payload { get; }

    /// <summary>True when <paramref name="request"/> is addressed to the Send endpoint, a POST to <c>/dp</c>.</summary>
    /// <param name="request">The request.</param>
    /// <returns>Whether it is a Send.</returns>
    public static bool IsSend(WireRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return request.Method == Method.Post && request.Path is ["dp"];
    }

    /// <summary>Parses a Send.</summary>
    /// <param name="request">The request.</param>
    /// <returns>The Send.</returns>
    /// <exception cref="Lwm2mException">
    /// <see cref="Lwm2mErrorCode.UnsupportedOperation"/> when the request is not a POST to <c>/dp</c>, or
    /// <see cref="Lwm2mErrorCode.UnsupportedContentFormat"/> when the body is not SenML.
    /// </exception>
    public static SendRequest Parse(WireRequest request)
    {
        if (!IsSend(request))
        {
            throw new Lwm2mException(Lwm2mErrorCode.UnsupportedOperation, $"a Send is a POST to /dp, not {request}");
        }

        return ContentFormats.IsSenml(request.ContentFormat)
            ? new SendRequest(request.ContentFormat!.Value, request.Payload)
            : throw new Lwm2mException(Lwm2mErrorCode.UnsupportedContentFormat, $"a Send carries SenML JSON (110) or SenML CBOR (112), not {request.ContentFormat?.ToString() ?? "no Content-Format"}");
    }

    /// <summary>Decodes the values sent, grouped by timestamp and Resource.</summary>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The values, one group per distinct time.</returns>
    /// <exception cref="Lwm2mException">The payload is malformed or a value does not satisfy its declared type.</exception>
    public IReadOnlyList<TimestampedNodes> DecodeNodes(ILwm2mModel? model = null) =>
        Lwm2mNodeCodec.DecodeTimestamped(Payload.Span, ContentFormat, model);

    /// <summary>The response that acknowledges a Send: 2.04 Changed.</summary>
    /// <returns>The response.</returns>
    public static WireResponse Accepted() => new(ResponseCode.Changed);

    /// <inheritdoc/>
    public bool Equals(SendRequest? other) => other is not null && ContentFormat == other.ContentFormat && Payload.Span.SequenceEqual(other.Payload.Span);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(ContentFormat, Payload.Length);
}

using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.Links;
using Wick.Lwm2m.Model;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.DeviceManagement;

/// <summary>
/// The outcome of a Device Management or Information Reporting operation, as the server sees it.
/// </summary>
/// <remarks>
/// An error response from the client (4.xx or 5.xx) is a normal outcome, not an exception: the
/// code says what happened and <see cref="ErrorMessage"/> carries any diagnostic text. A success
/// code that the operation does not define (2.01 to a Read, say) is a protocol violation, and the
/// parsers throw <see cref="Lwm2mException"/> with <see cref="Lwm2mErrorCode.InvalidResponse"/>.
/// </remarks>
public record Lwm2mResponse
{
    /// <summary>Creates a response.</summary>
    /// <param name="code">The response code.</param>
    public Lwm2mResponse(ResponseCode code)
    {
        Code = code;
    }

    /// <summary>The response code.</summary>
    public ResponseCode Code { get; }

    /// <summary>True for a 2.xx code.</summary>
    public bool IsSuccess => Code.IsSuccess;

    /// <summary>The diagnostic text of an error response, or <see langword="null"/>.</summary>
    public string? ErrorMessage { get; init; }

    internal static Lwm2mResponse Parse(WireResponse response, ResponseCode expected, string operation)
    {
        ArgumentNullException.ThrowIfNull(response);
        return Check(response, expected, operation) ?? new Lwm2mResponse(response.Code);
    }

    // Returns an error outcome for 4.xx and 5.xx, null for the expected success code, and throws for anything else.
    internal static Lwm2mResponse? Check(WireResponse response, ResponseCode expected, string operation)
    {
        if (response.Code == expected)
        {
            return null;
        }

        if (response.Code.IsError)
        {
            return new Lwm2mResponse(response.Code) { ErrorMessage = response.Payload.IsEmpty ? null : response.PayloadText };
        }

        throw new Lwm2mException(Lwm2mErrorCode.InvalidResponse, $"{operation} expects {expected} or an error, not {response.Code}");
    }

    internal static int ContentFormatOf(WireResponse response, Lwm2mPath path)
    {
        if (response.ContentFormat is { } contentFormat)
        {
            return contentFormat;
        }

        // A single value with no Content-Format is plain text; anything larger is ambiguous.
        return path.ResourceId is not null
            ? ContentFormats.PlainText
            : throw new Lwm2mException(Lwm2mErrorCode.InvalidResponse, $"the response for {path} has a payload but no Content-Format");
    }
}

/// <summary>The outcome of a Read, carrying the decoded node on success.</summary>
public sealed record ReadResponse : Lwm2mResponse
{
    /// <summary>Creates a Read response.</summary>
    /// <param name="code">The response code.</param>
    /// <param name="node">The node read, or <see langword="null"/> on error.</param>
    public ReadResponse(ResponseCode code, Lwm2mNode? node)
        : base(code)
    {
        Node = node;
    }

    /// <summary>The node read, at the level of the request path. <see langword="null"/> on error.</summary>
    public Lwm2mNode? Node { get; }

    /// <summary>The Content-Format the client answered in, or <see langword="null"/> on error.</summary>
    public int? ContentFormat { get; init; }

    internal static ReadResponse Parse(WireResponse response, Lwm2mPath path, ILwm2mModel? model, string operation)
    {
        ArgumentNullException.ThrowIfNull(response);
        if (Check(response, ResponseCode.Content, operation) is { } error)
        {
            return new ReadResponse(error.Code, null) { ErrorMessage = error.ErrorMessage };
        }

        var contentFormat = ContentFormatOf(response, path);
        return new ReadResponse(response.Code, Lwm2mNodeCodec.Decode(response.Payload.Span, contentFormat, path, model))
        {
            ContentFormat = contentFormat,
        };
    }
}

/// <summary>The outcome of a Discover, carrying the links the client reported.</summary>
public sealed record DiscoverResponse : Lwm2mResponse
{
    /// <summary>Creates a Discover response.</summary>
    /// <param name="code">The response code.</param>
    /// <param name="links">The links, empty on error.</param>
    public DiscoverResponse(ResponseCode code, IReadOnlyList<Link> links)
        : base(code)
    {
        Links = links ?? throw new ArgumentNullException(nameof(links));
    }

    /// <summary>The links, each with the attributes in force at its level. Empty on error.</summary>
    public IReadOnlyList<Link> Links { get; }

    internal static DiscoverResponse Parse(WireResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        if (Check(response, ResponseCode.Content, "Discover") is { } error)
        {
            return new DiscoverResponse(error.Code, []) { ErrorMessage = error.ErrorMessage };
        }

        if (response.ContentFormat is { } cf && cf != ContentFormats.LinkFormat)
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidResponse, $"a Discover response must be link-format (40), not {cf}");
        }

        return new DiscoverResponse(response.Code, CoreLinkFormat.Decode(response.Payload.Span));
    }
}

/// <summary>The outcome of a Create, carrying the path of the new Object Instance when the client reports it.</summary>
public sealed record CreateResponse : Lwm2mResponse
{
    /// <summary>Creates a Create response.</summary>
    /// <param name="code">The response code.</param>
    /// <param name="location">The new Instance's path, or <see langword="null"/>.</param>
    public CreateResponse(ResponseCode code, Lwm2mPath? location)
        : base(code)
    {
        Location = location;
    }

    /// <summary>
    /// The new Object Instance's path from the Location-Path option, or <see langword="null"/> on
    /// error or when the server chose the Instance ID in the request body and the client sent no location.
    /// </summary>
    public Lwm2mPath? Location { get; }

    internal static CreateResponse Parse(WireResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        if (Check(response, ResponseCode.Created, "Create") is { } error)
        {
            return new CreateResponse(error.Code, null) { ErrorMessage = error.ErrorMessage };
        }

        if (response.LocationPath.Count == 0)
        {
            return new CreateResponse(response.Code, null);
        }

        var location = Lwm2mPath.TryFromSegments(response.LocationPath, out var path) && path.IsObjectInstance
            ? path
            : throw new Lwm2mException(Lwm2mErrorCode.InvalidResponse, $"a Create response's location /{string.Join('/', response.LocationPath)} is not an Object Instance path");
        return new CreateResponse(response.Code, location);
    }
}

/// <summary>The outcome of an Observe: the current value, and the sequence number when the relation was established.</summary>
public sealed record ObserveResponse : Lwm2mResponse
{
    /// <summary>Creates an Observe response.</summary>
    /// <param name="code">The response code.</param>
    /// <param name="node">The current value, or <see langword="null"/> on error.</param>
    /// <param name="sequence">The Observe option value, or <see langword="null"/> when the client did not establish a relation.</param>
    public ObserveResponse(ResponseCode code, Lwm2mNode? node, uint? sequence)
        : base(code)
    {
        Node = node;
        Sequence = sequence;
    }

    /// <summary>The current value at the observed path. <see langword="null"/> on error.</summary>
    public Lwm2mNode? Node { get; }

    /// <summary>The Observe option value, or <see langword="null"/> when it was absent.</summary>
    public uint? Sequence { get; }

    /// <summary>The Content-Format of the value, or <see langword="null"/> on error.</summary>
    public int? ContentFormat { get; init; }

    /// <summary>
    /// True when the client established the relation: a 2.05 carrying the Observe option. A 2.05
    /// without it is a plain Read result and no notifications will follow (RFC 7641 §3.1).
    /// </summary>
    public bool IsEstablished => IsSuccess && Sequence is not null;

    internal static ObserveResponse Parse(WireResponse response, Lwm2mPath path, ILwm2mModel? model)
    {
        var read = ReadResponse.Parse(response, path, model, "Observe");
        return new ObserveResponse(read.Code, read.Node, read.IsSuccess ? response.Observe : null)
        {
            ErrorMessage = read.ErrorMessage,
            ContentFormat = read.ContentFormat,
        };
    }
}

/// <summary>The outcome of a Read-Composite or Observe-Composite: one node per requested path.</summary>
public sealed record CompositeResponse : Lwm2mResponse
{
    /// <summary>Creates a Composite response.</summary>
    /// <param name="code">The response code.</param>
    /// <param name="nodes">The nodes per requested path.</param>
    /// <param name="sequence">The Observe option value for Observe-Composite, or <see langword="null"/>.</param>
    public CompositeResponse(ResponseCode code, IReadOnlyList<KeyValuePair<Lwm2mPath, Lwm2mNode?>> nodes, uint? sequence = null)
        : base(code)
    {
        Nodes = nodes ?? throw new ArgumentNullException(nameof(nodes));
        Sequence = sequence;
    }

    /// <summary>
    /// One entry per requested path, in request order. A <see langword="null"/> node means the client
    /// had no value there, which Read-Composite allows. Empty on error.
    /// </summary>
    public IReadOnlyList<KeyValuePair<Lwm2mPath, Lwm2mNode?>> Nodes { get; }

    /// <summary>The Observe option value, set when an Observe-Composite relation was established.</summary>
    public uint? Sequence { get; }

    internal static CompositeResponse Parse(WireResponse response, IReadOnlyList<Lwm2mPath> paths, ILwm2mModel? model, string operation)
    {
        ArgumentNullException.ThrowIfNull(response);
        if (Check(response, ResponseCode.Content, operation) is { } error)
        {
            return new CompositeResponse(error.Code, []) { ErrorMessage = error.ErrorMessage };
        }

        var contentFormat = response.ContentFormat
            ?? throw new Lwm2mException(Lwm2mErrorCode.InvalidResponse, $"a {operation} response needs a Content-Format");
        return new CompositeResponse(response.Code, Lwm2mNodeCodec.DecodeComposite(response.Payload.Span, contentFormat, paths, model), response.Observe);
    }
}

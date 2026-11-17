using System.Collections.Immutable;
using System.Text;
using Wick.Lwm2m.Attributes;
using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.Model;
using Wick.Lwm2m.Senml;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.DeviceManagement;

/// <summary>Whether a Write replaces its target or merges into it (OMA LwM2M 1.2 §6.3.3).</summary>
public enum WriteMode
{
    /// <summary>Replace the target. Sent as PUT.</summary>
    Replace,

    /// <summary>Merge into the target Object Instance, leaving other Resources alone. Sent as POST.</summary>
    PartialUpdate,
}

/// <summary>
/// A request a server sends to a client: the Device Management and Information Reporting
/// operations of OMA LwM2M 1.2 §6.3 and §6.4.
/// </summary>
/// <remarks>
/// <para>
/// Each operation is its own immutable record. Constructors check that the path is one the
/// operation allows, so an invalid request cannot be built. <see cref="ToWire"/> gives the
/// transport-neutral form, and each record has a <c>ParseResponse</c> method that turns the
/// client's answer into a typed outcome, using the request's own path for context.
/// </para>
/// <para>
/// <see cref="FromWire"/> goes the other way, recovering the operation from a wire request. A
/// server does not need it to talk to clients, but it is the inverse that makes the mapping testable,
/// and it lets a gateway or client classify traffic.
/// </para>
/// </remarks>
public abstract record Lwm2mRequest
{
    private protected Lwm2mRequest()
    {
    }

    /// <summary>The transport-neutral form of the request.</summary>
    /// <returns>The wire request.</returns>
    public abstract WireRequest ToWire();

    /// <summary>
    /// Recovers the operation a wire request carries, using the method, path depth and options as
    /// OMA LwM2M 1.2 §6.3 and §6.4 lay them out.
    /// </summary>
    /// <remarks>
    /// <list type="bullet">
    /// <item><description>GET: Observe 0 is Observe, Observe 1 is Cancel Observation, Accept 40 is Discover, otherwise Read.</description></item>
    /// <item><description>PUT: a Content-Format means a body, so a replacing Write; none means Write-Attributes.</description></item>
    /// <item><description>POST: an Object path is Create, an Object Instance path is a partial Write, a Resource path is Execute.</description></item>
    /// <item><description>DELETE is Delete. FETCH is Read-Composite, or Observe-Composite with Observe 0. iPATCH is Write-Composite.</description></item>
    /// </list>
    /// </remarks>
    /// <param name="request">The wire request.</param>
    /// <returns>The operation.</returns>
    /// <exception cref="Lwm2mException">
    /// <see cref="Lwm2mErrorCode.InvalidPath"/> when the Uri-Path is not an LwM2M path (which includes
    /// <c>/rd</c> and <c>/dp</c> traffic), or <see cref="Lwm2mErrorCode.UnsupportedOperation"/> for a
    /// combination LwM2M does not define.
    /// </exception>
    public static Lwm2mRequest FromWire(WireRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        switch (request.Method)
        {
            case Method.Fetch:
            {
                var paths = DecodePaths(request);
                return request.Observe switch
                {
                    0 => new ObserveCompositeRequest(paths, request.ContentFormat!.Value, request.Accept) { Token = request.Token },
                    1 => new CancelObserveCompositeRequest(paths, request.ContentFormat!.Value) { Token = request.Token },
                    _ => new ReadCompositeRequest(paths, request.ContentFormat!.Value, request.Accept),
                };
            }

            case Method.IPatch:
                return request.Path.Count == 0 && request.ContentFormat is { } cf
                    ? new WriteCompositeRequest(cf, request.Payload)
                    : throw Unsupported("Write-Composite needs the root path and a Content-Format");
        }

        var path = Lwm2mPath.FromSegments(request.Path);
        return request.Method switch
        {
            Method.Get => request.Observe switch
            {
                0 => new ObserveRequest(path, request.Accept) { Token = request.Token },
                1 => new CancelObservationRequest(path) { Token = request.Token },
                _ when request.Accept == ContentFormats.LinkFormat => new DiscoverRequest(path),
                _ => new ReadRequest(path, request.Accept),
            },
            Method.Put => request.ContentFormat is { } format
                ? new WriteRequest(path, WriteMode.Replace, format, request.Payload)
                : new WriteAttributesRequest(path, NotificationAttributes.FromQuery(request.Query)),
            Method.Post => path.Depth switch
            {
                1 => new CreateRequest(path, request.ContentFormat ?? throw Unsupported("Create needs a Content-Format"), request.Payload),
                2 => new WriteRequest(path, WriteMode.PartialUpdate, request.ContentFormat ?? throw Unsupported("a partial Write needs a Content-Format"), request.Payload),
                3 => new ExecuteRequest(path, request.Payload.IsEmpty ? null : Encoding.UTF8.GetString(request.Payload.Span)),
                _ => throw Unsupported($"LwM2M defines no POST on a Resource Instance path ({path})"),
            },
            Method.Delete => new DeleteRequest(path),
            _ => throw Unsupported($"LwM2M defines no operation for {request.Method}"),
        };
    }

    private protected static IReadOnlyList<string> Segments(Lwm2mPath path) => path.ToSegments();

    private protected static Lwm2mException Unsupported(string message) => new(Lwm2mErrorCode.UnsupportedOperation, message);

    private protected static void RequireDepth(Lwm2mPath path, string operation, params int[] depths)
    {
        ArgumentNullException.ThrowIfNull(path);
        if (!depths.Contains(path.Depth))
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, $"{operation} is not allowed on {path}");
        }
    }

    private protected static bool SameBytes(ReadOnlyMemory<byte> left, ReadOnlyMemory<byte> right) => left.Span.SequenceEqual(right.Span);

    private protected static ImmutableArray<Lwm2mPath> CheckPaths(IEnumerable<Lwm2mPath> paths, string operation)
    {
        ArgumentNullException.ThrowIfNull(paths);
        var list = paths.ToImmutableArray();
        if (list.IsEmpty)
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, $"{operation} needs at least one path");
        }

        return list;
    }

    private protected static void RequireSenml(int contentFormat, string operation)
    {
        if (!ContentFormats.IsSenml(contentFormat))
        {
            throw new Lwm2mException(Lwm2mErrorCode.UnsupportedContentFormat, $"{operation} needs SenML JSON (110) or SenML CBOR (112), not {contentFormat}");
        }
    }

    private protected static byte[] EncodePaths(IEnumerable<Lwm2mPath> paths, int contentFormat)
    {
        var pack = SenmlPack.FromPaths(paths);
        return contentFormat == ContentFormats.SenmlJson
            ? SenmlJsonCodec.Encode(pack, allowNoValue: true)
            : SenmlCborCodec.Encode(pack, allowNoValue: true);
    }

    private static IReadOnlyList<Lwm2mPath> DecodePaths(WireRequest request)
    {
        if (request.ContentFormat is not { } cf || !ContentFormats.IsSenml(cf))
        {
            throw Unsupported("Composite operations need a SenML Content-Format (110 or 112)");
        }

        return Lwm2mNodeCodec.DecodePack(request.Payload.Span, cf).ToPaths();
    }
}

/// <summary>Read (OMA LwM2M 1.2 §6.3.1): retrieve the value at an Object, Object Instance, Resource or Resource Instance.</summary>
public sealed record ReadRequest : Lwm2mRequest
{
    /// <summary>Creates a Read.</summary>
    /// <param name="path">The target. Any depth.</param>
    /// <param name="accept">The Content-Format wanted in the response, or <see langword="null"/> to let the client choose.</param>
    public ReadRequest(Lwm2mPath path, int? accept = null)
    {
        RequireDepth(path, "Read", 1, 2, 3, 4);
        Path = path;
        Accept = accept;
    }

    /// <summary>The target path.</summary>
    public Lwm2mPath Path { get; }

    /// <summary>The Content-Format wanted in the response, or <see langword="null"/>.</summary>
    public int? Accept { get; }

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.Get) { Path = Segments(Path), Accept = Accept };

    /// <summary>Parses the client's response, decoding the value on 2.05 Content.</summary>
    /// <param name="response">The response.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The outcome.</returns>
    /// <exception cref="Lwm2mException">The response is not a valid answer to a Read, or its payload does not decode.</exception>
    public ReadResponse ParseResponse(WireResponse response, ILwm2mModel? model = null) =>
        ReadResponse.Parse(response, Path, model, "Read");
}

/// <summary>Write (OMA LwM2M 1.2 §6.3.3): replace or partially update values at the target.</summary>
public sealed record WriteRequest : Lwm2mRequest
{
    /// <summary>Creates a Write from an already encoded payload.</summary>
    /// <param name="path">
    /// The target. A replacing Write may target an Object Instance, Resource or Resource Instance;
    /// a partial update targets an Object Instance.
    /// </param>
    /// <param name="mode">Replace (PUT) or partial update (POST).</param>
    /// <param name="contentFormat">The payload's Content-Format.</param>
    /// <param name="payload">The encoded payload. Copied.</param>
    public WriteRequest(Lwm2mPath path, WriteMode mode, int contentFormat, ReadOnlyMemory<byte> payload)
    {
        if (mode == WriteMode.Replace)
        {
            RequireDepth(path, "a replacing Write", 2, 3, 4);
        }
        else
        {
            RequireDepth(path, "a partial-update Write", 2);
        }

        Path = path;
        Mode = mode;
        ContentFormat = contentFormat;
        Payload = payload.ToArray();
    }

    /// <summary>The target path.</summary>
    public Lwm2mPath Path { get; }

    /// <summary>Replace or partial update.</summary>
    public WriteMode Mode { get; }

    /// <summary>The payload's Content-Format.</summary>
    public int ContentFormat { get; }

    /// <summary>The encoded payload.</summary>
    public ReadOnlyMemory<byte> Payload { get; }

    /// <summary>Creates a Write by encoding a node.</summary>
    /// <param name="path">The target.</param>
    /// <param name="node">The node to write, at the level of <paramref name="path"/>.</param>
    /// <param name="mode">Replace or partial update.</param>
    /// <param name="contentFormat">The Content-Format to encode in.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The request.</returns>
    /// <exception cref="Lwm2mException">The node does not fit the path or cannot be encoded in the format.</exception>
    public static WriteRequest Create(Lwm2mPath path, Lwm2mNode node, WriteMode mode, int contentFormat, ILwm2mModel? model = null) =>
        new(path, mode, contentFormat, Lwm2mNodeCodec.Encode(node, path, contentFormat, model));

    /// <summary>Decodes the payload into the node being written, for a receiver.</summary>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The node.</returns>
    public Lwm2mNode DecodeNode(ILwm2mModel? model = null) => Lwm2mNodeCodec.Decode(Payload.Span, ContentFormat, Path, model);

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Mode == WriteMode.Replace ? Method.Put : Method.Post)
    {
        Path = Segments(Path),
        ContentFormat = ContentFormat,
        Payload = Payload,
    };

    /// <summary>Parses the client's response. Success is 2.04 Changed.</summary>
    /// <param name="response">The response.</param>
    /// <returns>The outcome.</returns>
    public Lwm2mResponse ParseResponse(WireResponse response) => Lwm2mResponse.Parse(response, ResponseCode.Changed, "Write");

    /// <inheritdoc/>
    public bool Equals(WriteRequest? other) =>
        other is not null && Path == other.Path && Mode == other.Mode && ContentFormat == other.ContentFormat && SameBytes(Payload, other.Payload);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Path, Mode, ContentFormat, Payload.Length);
}

/// <summary>Execute (OMA LwM2M 1.2 §6.3.5): invoke an Executable Resource, optionally with arguments.</summary>
public sealed record ExecuteRequest : Lwm2mRequest
{
    /// <summary>Creates an Execute.</summary>
    /// <param name="path">The Resource to execute.</param>
    /// <param name="arguments">The argument text, such as <c>0='abc',1</c>, or <see langword="null"/> for none. See <see cref="ExecuteArguments"/>.</param>
    public ExecuteRequest(Lwm2mPath path, string? arguments = null)
    {
        RequireDepth(path, "Execute", 3);
        Path = path;
        Arguments = string.IsNullOrEmpty(arguments) ? null : arguments;
    }

    /// <summary>The Resource path.</summary>
    public Lwm2mPath Path { get; }

    /// <summary>The argument text, or <see langword="null"/>.</summary>
    public string? Arguments { get; }

    /// <inheritdoc/>
    public override WireRequest ToWire() => Arguments is null
        ? new WireRequest(Method.Post) { Path = Segments(Path) }
        : new WireRequest(Method.Post) { Path = Segments(Path), ContentFormat = ContentFormats.PlainText, Payload = Encoding.UTF8.GetBytes(Arguments) };

    /// <summary>Parses the client's response. Success is 2.04 Changed.</summary>
    /// <param name="response">The response.</param>
    /// <returns>The outcome.</returns>
    public Lwm2mResponse ParseResponse(WireResponse response) => Lwm2mResponse.Parse(response, ResponseCode.Changed, "Execute");
}

/// <summary>Discover (OMA LwM2M 1.2 §6.3.4): list the Resources and attributes at an Object, Object Instance or Resource.</summary>
public sealed record DiscoverRequest : Lwm2mRequest
{
    /// <summary>Creates a Discover.</summary>
    /// <param name="path">The target: an Object, Object Instance or Resource.</param>
    public DiscoverRequest(Lwm2mPath path)
    {
        RequireDepth(path, "Discover", 1, 2, 3);
        Path = path;
    }

    /// <summary>The target path.</summary>
    public Lwm2mPath Path { get; }

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.Get) { Path = Segments(Path), Accept = ContentFormats.LinkFormat };

    /// <summary>Parses the client's response into links.</summary>
    /// <param name="response">The response.</param>
    /// <returns>The outcome.</returns>
    public DiscoverResponse ParseResponse(WireResponse response) => DiscoverResponse.Parse(response);
}

/// <summary>Create (OMA LwM2M 1.2 §6.3.6): create an Object Instance.</summary>
public sealed record CreateRequest : Lwm2mRequest
{
    /// <summary>Creates a Create from an already encoded payload.</summary>
    /// <param name="objectPath">The Object path.</param>
    /// <param name="contentFormat">The payload's Content-Format.</param>
    /// <param name="payload">The encoded payload. Copied.</param>
    public CreateRequest(Lwm2mPath objectPath, int contentFormat, ReadOnlyMemory<byte> payload)
    {
        RequireDepth(objectPath, "Create", 1);
        Path = objectPath;
        ContentFormat = contentFormat;
        Payload = payload.ToArray();
    }

    /// <summary>The Object path.</summary>
    public Lwm2mPath Path { get; }

    /// <summary>The payload's Content-Format.</summary>
    public int ContentFormat { get; }

    /// <summary>The encoded payload.</summary>
    public ReadOnlyMemory<byte> Payload { get; }

    /// <summary>
    /// Creates a Create by encoding Object Instances. The server chooses the Instance IDs; to let the
    /// client choose, encode the Resources without an Instance wrapper and use the constructor.
    /// </summary>
    /// <param name="objectPath">The Object path.</param>
    /// <param name="instances">The Instances to create.</param>
    /// <param name="contentFormat">TLV or a SenML format.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The request.</returns>
    /// <exception cref="Lwm2mException">The content format cannot carry Object Instances.</exception>
    public static CreateRequest Create(Lwm2mPath objectPath, IEnumerable<Lwm2mObjectInstance> instances, int contentFormat, ILwm2mModel? model = null)
    {
        ArgumentNullException.ThrowIfNull(objectPath);
        if (contentFormat is not (ContentFormats.Tlv or ContentFormats.SenmlJson or ContentFormats.SenmlCbor))
        {
            throw new Lwm2mException(Lwm2mErrorCode.UnsupportedContentFormat, $"Create needs TLV or SenML, not {contentFormat}");
        }

        var node = new Lwm2mObject(objectPath.ObjectId, instances);
        return new CreateRequest(objectPath, contentFormat, Lwm2mNodeCodec.Encode(node, objectPath, contentFormat, model));
    }

    /// <summary>Decodes the payload into the Instances being created, for a receiver.</summary>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The Object node holding them.</returns>
    public Lwm2mObject DecodeNode(ILwm2mModel? model = null) => (Lwm2mObject)Lwm2mNodeCodec.Decode(Payload.Span, ContentFormat, Path, model);

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.Post) { Path = Segments(Path), ContentFormat = ContentFormat, Payload = Payload };

    /// <summary>Parses the client's response. Success is 2.01 Created, with the new Instance's path when the client reports it.</summary>
    /// <param name="response">The response.</param>
    /// <returns>The outcome.</returns>
    public CreateResponse ParseResponse(WireResponse response) => CreateResponse.Parse(response);

    /// <inheritdoc/>
    public bool Equals(CreateRequest? other) =>
        other is not null && Path == other.Path && ContentFormat == other.ContentFormat && SameBytes(Payload, other.Payload);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Path, ContentFormat, Payload.Length);
}

/// <summary>Delete (OMA LwM2M 1.2 §6.3.7): delete an Object Instance.</summary>
public sealed record DeleteRequest : Lwm2mRequest
{
    /// <summary>Creates a Delete.</summary>
    /// <param name="path">The Object Instance path.</param>
    public DeleteRequest(Lwm2mPath path)
    {
        RequireDepth(path, "Delete", 2);
        Path = path;
    }

    /// <summary>The Object Instance path.</summary>
    public Lwm2mPath Path { get; }

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.Delete) { Path = Segments(Path) };

    /// <summary>Parses the client's response. Success is 2.02 Deleted.</summary>
    /// <param name="response">The response.</param>
    /// <returns>The outcome.</returns>
    public Lwm2mResponse ParseResponse(WireResponse response) => Lwm2mResponse.Parse(response, ResponseCode.Deleted, "Delete");
}

/// <summary>
/// Write-Attributes (OMA LwM2M 1.2 §6.3.4): set or clear the notification attributes at a path.
/// Sent as a PUT with the attributes as Uri-Query parameters and no payload.
/// </summary>
public sealed record WriteAttributesRequest : Lwm2mRequest
{
    /// <summary>Creates a Write-Attributes, validating the attributes against the path.</summary>
    /// <param name="path">The target. Any depth; <c>gt</c>, <c>lt</c> and <c>st</c> need a Resource or Resource Instance.</param>
    /// <param name="attributes">The attributes to set or clear. At least one must be present.</param>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.InvalidAttribute"/> when the set is empty or breaks a rule.</exception>
    public WriteAttributesRequest(Lwm2mPath path, NotificationAttributes attributes)
    {
        RequireDepth(path, "Write-Attributes", 1, 2, 3, 4);
        ArgumentNullException.ThrowIfNull(attributes);
        if (attributes.ToQuery().Count == 0)
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidAttribute, "Write-Attributes needs at least one notification attribute");
        }

        attributes.Validate(path);
        Path = path;
        Attributes = attributes;
    }

    /// <summary>The target path.</summary>
    public Lwm2mPath Path { get; }

    /// <summary>The attributes.</summary>
    public NotificationAttributes Attributes { get; }

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.Put) { Path = Segments(Path), Query = Attributes.ToQuery() };

    /// <summary>Parses the client's response. Success is 2.04 Changed.</summary>
    /// <param name="response">The response.</param>
    /// <returns>The outcome.</returns>
    public Lwm2mResponse ParseResponse(WireResponse response) => Lwm2mResponse.Parse(response, ResponseCode.Changed, "Write-Attributes");
}

/// <summary>
/// Observe (OMA LwM2M 1.2 §6.4.1, RFC 7641): a GET with Observe 0, asking the client to notify on change.
/// </summary>
public sealed record ObserveRequest : Lwm2mRequest
{
    private readonly ReadOnlyMemory<byte> _token = ReadOnlyMemory<byte>.Empty;

    /// <summary>Creates an Observe.</summary>
    /// <param name="path">The target. Any depth.</param>
    /// <param name="accept">The Content-Format wanted in notifications, or <see langword="null"/>.</param>
    public ObserveRequest(Lwm2mPath path, int? accept = null)
    {
        RequireDepth(path, "Observe", 1, 2, 3, 4);
        Path = path;
        Accept = accept;
    }

    /// <summary>The target path.</summary>
    public Lwm2mPath Path { get; }

    /// <summary>The Content-Format wanted in notifications, or <see langword="null"/>.</summary>
    public int? Accept { get; }

    /// <summary>
    /// The CoAP token the relation is keyed by, up to 8 bytes. Every notification carries it back.
    /// Empty lets the transport choose, in which case the caller must learn it from the transport.
    /// </summary>
    public ReadOnlyMemory<byte> Token
    {
        get => _token;
        init => _token = value.Length <= 8 ? value.ToArray() : throw new ArgumentException("a CoAP token is at most 8 bytes", nameof(value));
    }

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.Get) { Path = Segments(Path), Accept = Accept, Observe = 0, Token = Token };

    /// <summary>Parses the client's response: the current value, and whether the relation was established.</summary>
    /// <param name="response">The response.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The outcome.</returns>
    public ObserveResponse ParseResponse(WireResponse response, ILwm2mModel? model = null) => ObserveResponse.Parse(response, Path, model);

    /// <inheritdoc/>
    public bool Equals(ObserveRequest? other) =>
        other is not null && Path == other.Path && Accept == other.Accept && SameBytes(Token, other.Token);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Path, Accept, Token.Length);
}

/// <summary>
/// Cancel Observation (OMA LwM2M 1.2 §6.4.2), the active form: a GET with Observe 1 and the same
/// token as the Observe. The passive form needs no request: the server forgets the relation and
/// answers the next notification with a CoAP Reset.
/// </summary>
public sealed record CancelObservationRequest : Lwm2mRequest
{
    private readonly ReadOnlyMemory<byte> _token = ReadOnlyMemory<byte>.Empty;

    /// <summary>Creates a Cancel Observation.</summary>
    /// <param name="path">The observed path.</param>
    public CancelObservationRequest(Lwm2mPath path)
    {
        RequireDepth(path, "Cancel Observation", 1, 2, 3, 4);
        Path = path;
    }

    /// <summary>The observed path.</summary>
    public Lwm2mPath Path { get; }

    /// <summary>The token of the relation being cancelled, up to 8 bytes.</summary>
    public ReadOnlyMemory<byte> Token
    {
        get => _token;
        init => _token = value.Length <= 8 ? value.ToArray() : throw new ArgumentException("a CoAP token is at most 8 bytes", nameof(value));
    }

    /// <summary>Creates the Cancel Observation for an established relation, reusing its path and token.</summary>
    /// <param name="observation">The relation.</param>
    /// <returns>The request.</returns>
    /// <exception cref="Lwm2mException">The relation is Composite; cancel it with <see cref="CancelObserveCompositeRequest"/>.</exception>
    public static CancelObservationRequest For(InformationReporting.Observation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        return observation.IsComposite
            ? throw Unsupported("a Composite relation is cancelled with a FETCH, not a GET")
            : new CancelObservationRequest(observation.Paths[0]) { Token = observation.Token };
    }

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.Get) { Path = Segments(Path), Observe = 1, Token = Token };

    /// <summary>Parses the client's response. A 2.05 with the current value is the normal answer.</summary>
    /// <param name="response">The response.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The outcome.</returns>
    public ReadResponse ParseResponse(WireResponse response, ILwm2mModel? model = null) =>
        ReadResponse.Parse(response, Path, model, "Cancel Observation");

    /// <inheritdoc/>
    public bool Equals(CancelObservationRequest? other) => other is not null && Path == other.Path && SameBytes(Token, other.Token);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Path, Token.Length);
}

/// <summary>Read-Composite (OMA LwM2M 1.2 §6.3.8, LwM2M 1.1 and later): read several paths in one FETCH.</summary>
public sealed record ReadCompositeRequest : Lwm2mRequest
{
    private readonly ImmutableArray<Lwm2mPath> _paths;

    /// <summary>Creates a Read-Composite.</summary>
    /// <param name="paths">The paths to read. At least one.</param>
    /// <param name="contentFormat">The request body's format: SenML JSON or SenML CBOR.</param>
    /// <param name="accept">The Content-Format wanted in the response, or <see langword="null"/>.</param>
    public ReadCompositeRequest(IEnumerable<Lwm2mPath> paths, int contentFormat = ContentFormats.SenmlCbor, int? accept = null)
    {
        _paths = CheckPaths(paths, "Read-Composite");
        RequireSenml(contentFormat, "Read-Composite");
        ContentFormat = contentFormat;
        Accept = accept;
    }

    /// <summary>The paths to read.</summary>
    public IReadOnlyList<Lwm2mPath> Paths => _paths;

    /// <summary>The request body's Content-Format.</summary>
    public int ContentFormat { get; }

    /// <summary>The Content-Format wanted in the response, or <see langword="null"/>.</summary>
    public int? Accept { get; }

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.Fetch)
    {
        ContentFormat = ContentFormat,
        Accept = Accept,
        Payload = EncodePaths(_paths, ContentFormat),
    };

    /// <summary>Parses the client's response into one node per requested path.</summary>
    /// <param name="response">The response.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The outcome.</returns>
    public CompositeResponse ParseResponse(WireResponse response, ILwm2mModel? model = null) =>
        CompositeResponse.Parse(response, _paths, model, "Read-Composite");

    /// <inheritdoc/>
    public bool Equals(ReadCompositeRequest? other) =>
        other is not null && _paths.SequenceEqual(other._paths) && ContentFormat == other.ContentFormat && Accept == other.Accept;

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(_paths.Length, ContentFormat, Accept);
}

/// <summary>Write-Composite (OMA LwM2M 1.2 §6.3.9, LwM2M 1.1 and later): write several Resources in one iPATCH.</summary>
public sealed record WriteCompositeRequest : Lwm2mRequest
{
    /// <summary>Creates a Write-Composite from an already encoded SenML payload.</summary>
    /// <param name="contentFormat">SenML JSON or SenML CBOR.</param>
    /// <param name="payload">The encoded payload. Copied.</param>
    public WriteCompositeRequest(int contentFormat, ReadOnlyMemory<byte> payload)
    {
        RequireSenml(contentFormat, "Write-Composite");
        ContentFormat = contentFormat;
        Payload = payload.ToArray();
    }

    /// <summary>The payload's Content-Format.</summary>
    public int ContentFormat { get; }

    /// <summary>The encoded payload.</summary>
    public ReadOnlyMemory<byte> Payload { get; }

    /// <summary>Creates a Write-Composite by encoding nodes, each relative to its own path.</summary>
    /// <param name="nodes">The nodes to write, keyed by path. Resources and Resource Instances only.</param>
    /// <param name="contentFormat">SenML JSON or SenML CBOR.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The request.</returns>
    /// <exception cref="Lwm2mException">A path is above Resource level, or a node does not fit its path.</exception>
    public static WriteCompositeRequest Create(IEnumerable<KeyValuePair<Lwm2mPath, Lwm2mNode>> nodes, int contentFormat = ContentFormats.SenmlCbor, ILwm2mModel? model = null)
    {
        ArgumentNullException.ThrowIfNull(nodes);
        var list = nodes.ToList();
        if (list.Count == 0 || list.Any(n => n.Key.ResourceId is null))
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, "Write-Composite needs at least one node, and only Resources and Resource Instances can be written");
        }

        return new WriteCompositeRequest(contentFormat, Lwm2mNodeCodec.EncodeComposite(list.Select(n => KeyValuePair.Create<Lwm2mPath, Lwm2mNode?>(n.Key, n.Value)), contentFormat, model));
    }

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.IPatch) { ContentFormat = ContentFormat, Payload = Payload };

    /// <summary>Parses the client's response. Success is 2.04 Changed.</summary>
    /// <param name="response">The response.</param>
    /// <returns>The outcome.</returns>
    public Lwm2mResponse ParseResponse(WireResponse response) => Lwm2mResponse.Parse(response, ResponseCode.Changed, "Write-Composite");

    /// <inheritdoc/>
    public bool Equals(WriteCompositeRequest? other) => other is not null && ContentFormat == other.ContentFormat && SameBytes(Payload, other.Payload);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(ContentFormat, Payload.Length);
}

/// <summary>Observe-Composite (OMA LwM2M 1.2 §6.4.3, LwM2M 1.1 and later): one relation over several paths, sent as FETCH with Observe 0.</summary>
public sealed record ObserveCompositeRequest : Lwm2mRequest
{
    private readonly ImmutableArray<Lwm2mPath> _paths;
    private readonly ReadOnlyMemory<byte> _token = ReadOnlyMemory<byte>.Empty;

    /// <summary>Creates an Observe-Composite.</summary>
    /// <param name="paths">The paths to observe. At least one.</param>
    /// <param name="contentFormat">The request body's format: SenML JSON or SenML CBOR.</param>
    /// <param name="accept">The Content-Format wanted in notifications, or <see langword="null"/>.</param>
    public ObserveCompositeRequest(IEnumerable<Lwm2mPath> paths, int contentFormat = ContentFormats.SenmlCbor, int? accept = null)
    {
        _paths = CheckPaths(paths, "Observe-Composite");
        RequireSenml(contentFormat, "Observe-Composite");
        ContentFormat = contentFormat;
        Accept = accept;
    }

    /// <summary>The paths to observe.</summary>
    public IReadOnlyList<Lwm2mPath> Paths => _paths;

    /// <summary>The request body's Content-Format.</summary>
    public int ContentFormat { get; }

    /// <summary>The Content-Format wanted in notifications, or <see langword="null"/>.</summary>
    public int? Accept { get; }

    /// <summary>The CoAP token the relation is keyed by, up to 8 bytes.</summary>
    public ReadOnlyMemory<byte> Token
    {
        get => _token;
        init => _token = value.Length <= 8 ? value.ToArray() : throw new ArgumentException("a CoAP token is at most 8 bytes", nameof(value));
    }

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.Fetch)
    {
        ContentFormat = ContentFormat,
        Accept = Accept,
        Observe = 0,
        Token = Token,
        Payload = EncodePaths(_paths, ContentFormat),
    };

    /// <summary>Parses the client's response into one node per path, with the sequence number when the relation was established.</summary>
    /// <param name="response">The response.</param>
    /// <param name="model">The model used to type values, or <see langword="null"/>.</param>
    /// <returns>The outcome.</returns>
    public CompositeResponse ParseResponse(WireResponse response, ILwm2mModel? model = null) =>
        CompositeResponse.Parse(response, _paths, model, "Observe-Composite");

    /// <inheritdoc/>
    public bool Equals(ObserveCompositeRequest? other) =>
        other is not null && _paths.SequenceEqual(other._paths) && ContentFormat == other.ContentFormat && Accept == other.Accept && SameBytes(Token, other.Token);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(_paths.Length, ContentFormat, Accept);
}

/// <summary>Cancel Observe-Composite (OMA LwM2M 1.2 §6.4.4), the active form: a FETCH with Observe 1, the same paths and the same token.</summary>
public sealed record CancelObserveCompositeRequest : Lwm2mRequest
{
    private readonly ImmutableArray<Lwm2mPath> _paths;
    private readonly ReadOnlyMemory<byte> _token = ReadOnlyMemory<byte>.Empty;

    /// <summary>Creates a Cancel Observe-Composite.</summary>
    /// <param name="paths">The observed paths.</param>
    /// <param name="contentFormat">The request body's format: SenML JSON or SenML CBOR.</param>
    public CancelObserveCompositeRequest(IEnumerable<Lwm2mPath> paths, int contentFormat = ContentFormats.SenmlCbor)
    {
        _paths = CheckPaths(paths, "Cancel Observe-Composite");
        RequireSenml(contentFormat, "Cancel Observe-Composite");
        ContentFormat = contentFormat;
    }

    /// <summary>The observed paths.</summary>
    public IReadOnlyList<Lwm2mPath> Paths => _paths;

    /// <summary>The request body's Content-Format.</summary>
    public int ContentFormat { get; }

    /// <summary>The token of the relation being cancelled.</summary>
    public ReadOnlyMemory<byte> Token
    {
        get => _token;
        init => _token = value.Length <= 8 ? value.ToArray() : throw new ArgumentException("a CoAP token is at most 8 bytes", nameof(value));
    }

    /// <inheritdoc/>
    public override WireRequest ToWire() => new(Method.Fetch)
    {
        ContentFormat = ContentFormat,
        Observe = 1,
        Token = Token,
        Payload = EncodePaths(_paths, ContentFormat),
    };

    /// <inheritdoc/>
    public bool Equals(CancelObserveCompositeRequest? other) =>
        other is not null && _paths.SequenceEqual(other._paths) && ContentFormat == other.ContentFormat && SameBytes(Token, other.Token);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(_paths.Length, ContentFormat);
}

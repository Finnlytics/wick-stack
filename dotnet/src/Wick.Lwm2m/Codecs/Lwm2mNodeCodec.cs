using Wick.Lwm2m.Model;
using Wick.Lwm2m.Senml;

namespace Wick.Lwm2m.Codecs;

/// <summary>
/// Encodes and decodes <see cref="Lwm2mNode"/>s in any supported content format, using the Object
/// model to type values where the format does not carry type.
/// </summary>
/// <remarks>
/// <para>
/// This is the entry point a server uses for Read and Observe responses and for Write and Create
/// bodies. Supported formats are plain text (0), opaque (42), SenML JSON (110), SenML CBOR (112) and
/// TLV (11542). Plain text and opaque carry a single Resource or Resource Instance only.
/// </para>
/// <para>
/// When encoding with a model, each value is converted to the declared type where the conversion
/// is lossless (Integer to Float, Integer to Unsigned Integer when non-negative, String to CoRE
/// Link and so on), and refused otherwise. When decoding, the declared type wins; without a model,
/// SenML values are inferred from the value field, TLV values come back as Opaque and plain text
/// comes back as String.
/// </para>
/// <para>
/// SenML output follows Eclipse Leshan's layout: the first record carries the request path as its
/// base name and every record names its position relative to that path, so a Read of <c>/3/0</c>
/// encodes as <c>[{"bn":"/3/0/","n":"0",...},{"n":"9",...}]</c>.
/// </para>
/// </remarks>
public static class Lwm2mNodeCodec
{
    /// <summary>True when <paramref name="contentFormat"/> is one Wick can encode and decode nodes in.</summary>
    /// <param name="contentFormat">The Content-Format number.</param>
    /// <returns>Whether it is supported.</returns>
    public static bool IsSupported(int contentFormat) => ContentFormats.Supported.Contains(contentFormat);

    /// <summary>Encodes a node relative to the request path.</summary>
    /// <param name="node">The node. Its level and IDs must agree with <paramref name="path"/>.</param>
    /// <param name="path">The request path.</param>
    /// <param name="contentFormat">The Content-Format to encode in.</param>
    /// <param name="model">The model, or <see langword="null"/>.</param>
    /// <returns>The payload bytes.</returns>
    /// <exception cref="Lwm2mException">
    /// The format is not supported, cannot carry this node, the node does not fit the path, or a value
    /// cannot be converted to its declared type.
    /// </exception>
    public static byte[] Encode(Lwm2mNode node, Lwm2mPath path, int contentFormat, ILwm2mModel? model = null)
    {
        ArgumentNullException.ThrowIfNull(node);
        ArgumentNullException.ThrowIfNull(path);
        var leaves = NodeLeaves.Flatten(node, path, model);
        switch (contentFormat)
        {
            case ContentFormats.SenmlJson:
                return SenmlJsonCodec.Encode(new SenmlPack(NodeLeaves.ToRecords(leaves, path)));
            case ContentFormats.SenmlCbor:
                return SenmlCborCodec.Encode(new SenmlPack(NodeLeaves.ToRecords(leaves, path)));
            case ContentFormats.Tlv:
                return Tlv.Encode(NodeTlv.ToEntries(node, path, model));
            case ContentFormats.PlainText:
                return PlainTextCodec.Encode(SingleValue(node, path, contentFormat, leaves));
            case ContentFormats.Opaque:
                return OpaqueCodec.Encode(SingleValue(node, path, contentFormat, leaves));
            default:
                throw Unsupported(contentFormat);
        }
    }

    /// <summary>Decodes a payload into the node at the request path.</summary>
    /// <param name="payload">The payload bytes.</param>
    /// <param name="contentFormat">The payload's Content-Format.</param>
    /// <param name="path">The request path the payload answers or targets.</param>
    /// <param name="model">The model, or <see langword="null"/>.</param>
    /// <returns>
    /// A node at the level of <paramref name="path"/>: an <see cref="Lwm2mObject"/>,
    /// <see cref="Lwm2mObjectInstance"/>, <see cref="Lwm2mResource"/> or <see cref="Lwm2mResourceInstance"/>.
    /// </returns>
    /// <exception cref="Lwm2mException">The payload is malformed, does not fit the path, or a value does not satisfy its declared type.</exception>
    public static Lwm2mNode Decode(ReadOnlySpan<byte> payload, int contentFormat, Lwm2mPath path, ILwm2mModel? model = null)
    {
        ArgumentNullException.ThrowIfNull(path);
        switch (contentFormat)
        {
            case ContentFormats.SenmlJson:
                return NodeLeaves.ToNode(NodeLeaves.FromPack(SenmlJsonCodec.Decode(payload), path, model), path, model);
            case ContentFormats.SenmlCbor:
                return NodeLeaves.ToNode(NodeLeaves.FromPack(SenmlCborCodec.Decode(payload), path, model), path, model);
            case ContentFormats.Tlv:
                return NodeTlv.ToNode(Tlv.Decode(payload), path, model);
            case ContentFormats.PlainText:
                return SingleNode(path, model, contentFormat, PlainTextCodec.Decode(payload, model.ResourceType(path)));
            case ContentFormats.Opaque:
                var declared = model.ResourceType(path);
                if (declared is { } t && t != Lwm2mType.Opaque)
                {
                    throw new Lwm2mException(Lwm2mErrorCode.UnsupportedContentFormat, $"{path} is declared {t}; Content-Format 42 carries Opaque values only");
                }

                return SingleNode(path, model, contentFormat, OpaqueCodec.Decode(payload));
            default:
                throw Unsupported(contentFormat);
        }
    }

    /// <summary>
    /// Encodes several nodes, each relative to its own path, into one SenML pack. This is the body of
    /// a Write-Composite request, a Read-Composite response and a Send.
    /// </summary>
    /// <param name="nodes">The nodes, keyed by path. A <see langword="null"/> node is skipped.</param>
    /// <param name="contentFormat">SenML JSON (110) or SenML CBOR (112).</param>
    /// <param name="model">The model, or <see langword="null"/>.</param>
    /// <returns>The payload bytes.</returns>
    /// <exception cref="Lwm2mException">The format is not SenML, or a node does not fit its path.</exception>
    public static byte[] EncodeComposite(IEnumerable<KeyValuePair<Lwm2mPath, Lwm2mNode?>> nodes, int contentFormat, ILwm2mModel? model = null)
    {
        ArgumentNullException.ThrowIfNull(nodes);
        RequireSenml(contentFormat);
        var records = new List<SenmlRecord>();
        foreach (var (path, node) in nodes)
        {
            if (node is not null)
            {
                records.AddRange(NodeLeaves.ToRecords(NodeLeaves.Flatten(node, path, model), path));
            }
        }

        var pack = new SenmlPack(records);
        return contentFormat == ContentFormats.SenmlJson ? SenmlJsonCodec.Encode(pack) : SenmlCborCodec.Encode(pack);
    }

    /// <summary>
    /// Decodes a SenML payload into one node per requested path, the shape of a Read-Composite or
    /// Observe-Composite response.
    /// </summary>
    /// <param name="payload">The payload bytes.</param>
    /// <param name="contentFormat">SenML JSON (110) or SenML CBOR (112).</param>
    /// <param name="paths">The requested paths.</param>
    /// <param name="model">The model, or <see langword="null"/>.</param>
    /// <returns>
    /// One entry per requested path, in request order. The node is <see langword="null"/> when the
    /// payload holds no value under that path, which LwM2M allows because Read-Composite is best effort.
    /// </returns>
    /// <exception cref="Lwm2mException">The format is not SenML, the payload is malformed, or a record falls under none of the paths.</exception>
    public static IReadOnlyList<KeyValuePair<Lwm2mPath, Lwm2mNode?>> DecodeComposite(
        ReadOnlySpan<byte> payload, int contentFormat, IReadOnlyList<Lwm2mPath> paths, ILwm2mModel? model = null)
    {
        ArgumentNullException.ThrowIfNull(paths);
        var leaves = NodeLeaves.FromPack(DecodePack(payload, contentFormat), null, model);
        var orphan = leaves.FirstOrDefault(l => !paths.Any(p => p.Contains(l.Path)));
        if (orphan is not null)
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, $"the payload holds {orphan.Path}, which is under none of the requested paths");
        }

        return paths.Select(path =>
        {
            var under = leaves.Where(l => path.Contains(l.Path)).ToList();
            Lwm2mNode? node = under.Count == 0 && !(path.IsResource && model.GetResource(path) is { Multiple: true })
                ? null
                : NodeLeaves.ToNode(under, path, model);
            return KeyValuePair.Create(path, node);
        }).ToList();
    }

    /// <summary>
    /// Decodes a SenML payload whose paths are not known in advance, the shape of a Send or a
    /// Composite Notify, grouping records into one node per Resource and per timestamp.
    /// </summary>
    /// <param name="payload">The payload bytes.</param>
    /// <param name="contentFormat">SenML JSON (110) or SenML CBOR (112).</param>
    /// <param name="model">The model, or <see langword="null"/>.</param>
    /// <returns>
    /// One group per distinct resolved time, in order of first appearance. A group's time is
    /// <see langword="null"/> when its records carry no time. Within a group, each Resource path maps
    /// to its Resource node. A multiple Resource holds only the instances the payload carried.
    /// </returns>
    /// <exception cref="Lwm2mException">The format is not SenML or the payload is malformed.</exception>
    public static IReadOnlyList<TimestampedNodes> DecodeTimestamped(ReadOnlySpan<byte> payload, int contentFormat, ILwm2mModel? model = null)
    {
        var pack = DecodePack(payload, contentFormat);
        var groups = new List<TimestampedNodes>();
        foreach (var group in pack.Resolve().GroupBy(r => r.Time))
        {
            var leaves = NodeLeaves.FromResolved(group, null, model);
            var nodes = leaves
                .GroupBy(l => new Lwm2mPath(l.Path.ObjectId, l.Path.ObjectInstanceId, l.Path.ResourceId))
                .OrderBy(g => g.Key)
                .Select(g => KeyValuePair.Create(g.Key, NodeLeaves.ToNode(g.ToList(), g.Key, model)))
                .ToList();
            groups.Add(new TimestampedNodes(group.Key, nodes));
        }

        return groups;
    }

    internal static SenmlPack DecodePack(ReadOnlySpan<byte> payload, int contentFormat)
    {
        RequireSenml(contentFormat);
        return contentFormat == ContentFormats.SenmlJson ? SenmlJsonCodec.Decode(payload) : SenmlCborCodec.Decode(payload);
    }

    private static void RequireSenml(int contentFormat)
    {
        if (!ContentFormats.IsSenml(contentFormat))
        {
            throw new Lwm2mException(Lwm2mErrorCode.UnsupportedContentFormat, $"Composite payloads need SenML JSON (110) or SenML CBOR (112), not {contentFormat}");
        }
    }

    private static Lwm2mValue SingleValue(Lwm2mNode node, Lwm2mPath path, int contentFormat, IReadOnlyList<NodeLeaf> leaves)
    {
        if (node is not (Lwm2mSingleResource or Lwm2mResourceInstance) || leaves.Count != 1)
        {
            throw new Lwm2mException(Lwm2mErrorCode.UnsupportedContentFormat, $"Content-Format {contentFormat} carries a single Resource value, not the node at {path}");
        }

        return leaves[0].Value;
    }

    private static Lwm2mNode SingleNode(Lwm2mPath path, ILwm2mModel? model, int contentFormat, Lwm2mValue value)
    {
        if (path.IsResourceInstance)
        {
            return new Lwm2mResourceInstance(path.ResourceInstanceId!.Value, value);
        }

        if (path.IsResource && model.GetResource(path) is not { Multiple: true })
        {
            return new Lwm2mSingleResource(path.ResourceId!.Value, value);
        }

        throw new Lwm2mException(Lwm2mErrorCode.UnsupportedContentFormat, $"Content-Format {contentFormat} carries a single Resource value, but {path} is not a single Resource");
    }

    private static Lwm2mException Unsupported(int contentFormat) =>
        new(Lwm2mErrorCode.UnsupportedContentFormat, $"Content-Format {contentFormat} is not supported for LwM2M nodes");
}

/// <summary>The nodes a SenML payload reported at one point in time.</summary>
/// <param name="Time">The resolved SenML time, usually seconds since the Unix epoch, or <see langword="null"/> when the records carry none.</param>
/// <param name="Nodes">The nodes, keyed by path, in ascending path order.</param>
public sealed record TimestampedNodes(SenmlNumber? Time, IReadOnlyList<KeyValuePair<Lwm2mPath, Lwm2mNode>> Nodes);

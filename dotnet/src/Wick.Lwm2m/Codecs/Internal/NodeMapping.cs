using Wick.Lwm2m.Model;
using Wick.Lwm2m.Senml;

namespace Wick.Lwm2m.Codecs;

/// <summary>One Resource or Resource Instance value with its absolute path.</summary>
internal sealed record NodeLeaf(Lwm2mPath Path, Lwm2mValue Value);

/// <summary>Conversions between nodes, flat lists of leaf values and SenML records.</summary>
internal static class NodeLeaves
{
    public static void Validate(Lwm2mNode node, Lwm2mPath path)
    {
        bool fits = node switch
        {
            Lwm2mObject o => path.IsObject && o.Id == path.ObjectId,
            Lwm2mObjectInstance i => path.IsObject || (path.IsObjectInstance && i.Id == path.ObjectInstanceId),
            Lwm2mResource r => path.IsResource && r.Id == path.ResourceId,
            Lwm2mResourceInstance ri => path.IsResourceInstance && ri.Id == path.ResourceInstanceId,
            _ => false,
        };

        if (!fits)
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidNode, $"{Describe(node)} does not fit the path {path}");
        }
    }

    public static IReadOnlyList<NodeLeaf> Flatten(Lwm2mNode node, Lwm2mPath path, ILwm2mModel? model)
    {
        Validate(node, path);
        var leaves = new List<NodeLeaf>();
        switch (node)
        {
            case Lwm2mObject o:
                foreach (var instance in o.Instances.Values)
                {
                    AddInstance(leaves, path.Append(instance.Id), instance, model);
                }

                break;
            case Lwm2mObjectInstance i:
                AddInstance(leaves, path.IsObject ? path.Append(i.Id) : path, i, model);
                break;
            case Lwm2mResource r:
                AddResource(leaves, path, r, model);
                break;
            case Lwm2mResourceInstance ri:
                leaves.Add(Leaf(path, ri.Value, model));
                break;
        }

        return leaves;
    }

    // Leshan's layout: the first record carries the request path as base name, and each record
    // names its position relative to that path.
    public static IEnumerable<SenmlRecord> ToRecords(IReadOnlyList<NodeLeaf> leaves, Lwm2mPath path)
    {
        var basePath = path.ToString();
        var depth = path.Depth;
        for (int i = 0; i < leaves.Count; i++)
        {
            var leaf = leaves[i];
            if (leaf.Value.Type == Lwm2mType.None)
            {
                throw new Lwm2mException(Lwm2mErrorCode.UnencodableValue, $"{leaf.Path} has no value to encode");
            }

            var name = string.Join('/', leaf.Path.ToSegments().Skip(depth));
            var record = SenmlValues.ToRecord(leaf.Value) with { Name = name.Length == 0 ? null : name };
            yield return i == 0 ? record with { BaseName = name.Length == 0 ? basePath : basePath + "/" } : record;
        }
    }

    public static IReadOnlyList<NodeLeaf> FromPack(SenmlPack pack, Lwm2mPath? requestPath, ILwm2mModel? model) =>
        FromResolved(pack.Resolve(), requestPath, model);

    public static IReadOnlyList<NodeLeaf> FromResolved(IEnumerable<ResolvedSenmlRecord> records, Lwm2mPath? requestPath, ILwm2mModel? model)
    {
        var leaves = new List<NodeLeaf>();
        var seen = new HashSet<Lwm2mPath>();
        foreach (var resolved in records)
        {
            var path = ResolveName(resolved.Name, requestPath);
            if (requestPath is not null && !requestPath.Contains(path))
            {
                throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, $"record {path} is not under the request path {requestPath}");
            }

            if (path.ResourceId is null)
            {
                throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, $"record {path} does not name a Resource");
            }

            if (!seen.Add(path))
            {
                throw new Lwm2mException(Lwm2mErrorCode.MalformedSenml, $"record {path} appears more than once");
            }

            leaves.Add(new NodeLeaf(path, SenmlValues.ToValue(resolved.Record, model.ResourceType(path), path)));
        }

        return leaves;
    }

    public static Lwm2mNode ToNode(IReadOnlyList<NodeLeaf> leaves, Lwm2mPath path, ILwm2mModel? model)
    {
        switch (path.Depth)
        {
            case 4:
                if (leaves is [{ } only] && only.Path == path)
                {
                    return new Lwm2mResourceInstance(path.ResourceInstanceId!.Value, only.Value);
                }

                throw new Lwm2mException(Lwm2mErrorCode.InvalidNode, $"expected exactly one value for {path}, found {leaves.Count}");
            case 3:
                return BuildResource(path, leaves, model);
            case 2:
                return BuildInstance(path, leaves, model);
            default:
                return new Lwm2mObject(path.ObjectId, leaves
                    .GroupBy(l => l.Path.ObjectInstanceId!.Value)
                    .Select(g => BuildInstance(path.Append(g.Key), g.ToList(), model)));
        }
    }

    public static Lwm2mValue Convert(Lwm2mValue value, Lwm2mType target, Lwm2mPath path)
    {
        if (value.Type == target || target == Lwm2mType.None)
        {
            return value;
        }

        Lwm2mValue? converted = (value.Type, target) switch
        {
            (Lwm2mType.Integer, Lwm2mType.Float) => Lwm2mValue.FromFloat(value.AsInteger()),
            (Lwm2mType.UnsignedInteger, Lwm2mType.Float) => Lwm2mValue.FromFloat(value.AsUnsignedInteger()),
            (Lwm2mType.Integer, Lwm2mType.UnsignedInteger) when value.AsInteger() >= 0 => Lwm2mValue.FromUnsignedInteger((ulong)value.AsInteger()),
            (Lwm2mType.UnsignedInteger, Lwm2mType.Integer) when value.AsUnsignedInteger() <= long.MaxValue => Lwm2mValue.FromInteger((long)value.AsUnsignedInteger()),
            (Lwm2mType.Integer, Lwm2mType.Time) => Lwm2mValue.FromTime(value.AsInteger()),
            (Lwm2mType.Time, Lwm2mType.Integer) => Lwm2mValue.FromInteger(value.AsTime()),
            (Lwm2mType.UnsignedInteger, Lwm2mType.Time) when value.AsUnsignedInteger() <= long.MaxValue => Lwm2mValue.FromTime((long)value.AsUnsignedInteger()),
            (Lwm2mType.Float, Lwm2mType.Integer) when IsWhole(value.AsFloat()) && value.AsFloat() is >= long.MinValue and < long.MaxValue => Lwm2mValue.FromInteger((long)value.AsFloat()),
            (Lwm2mType.String, Lwm2mType.CoreLink) => Lwm2mValue.FromCoreLink(value.AsString()),
            (Lwm2mType.CoreLink, Lwm2mType.String) => Lwm2mValue.FromString(value.AsCoreLink()),
            _ => null,
        };

        return converted ?? throw new Lwm2mException(Lwm2mErrorCode.TypeMismatch, $"{path} is declared {target}, which {value} cannot be converted to");
    }

    private static bool IsWhole(double value) => double.IsFinite(value) && Math.Floor(value) == value;

    private static Lwm2mPath ResolveName(string name, Lwm2mPath? requestPath)
    {
        if (name.Length == 0)
        {
            return requestPath ?? throw new Lwm2mException(Lwm2mErrorCode.MissingName, "a record has no name and there is no request path to stand in for it");
        }

        if (name[0] == '/' || requestPath is null)
        {
            return Lwm2mPath.Parse(name);
        }

        return Lwm2mPath.Parse(requestPath + "/" + name);
    }

    private static void AddInstance(List<NodeLeaf> leaves, Lwm2mPath instancePath, Lwm2mObjectInstance instance, ILwm2mModel? model)
    {
        foreach (var resource in instance.Resources.Values)
        {
            AddResource(leaves, instancePath.Append(resource.Id), resource, model);
        }
    }

    private static void AddResource(List<NodeLeaf> leaves, Lwm2mPath resourcePath, Lwm2mResource resource, ILwm2mModel? model)
    {
        switch (resource)
        {
            case Lwm2mSingleResource single:
                leaves.Add(Leaf(resourcePath, single.Value, model));
                break;
            case Lwm2mMultipleResource multiple:
                foreach (var instance in multiple.Instances.Values)
                {
                    leaves.Add(Leaf(resourcePath.Append(instance.Id), instance.Value, model));
                }

                break;
        }
    }

    private static NodeLeaf Leaf(Lwm2mPath path, Lwm2mValue value, ILwm2mModel? model) =>
        new(path, model.ResourceType(path) is { } declared ? Convert(value, declared, path) : value);

    private static Lwm2mObjectInstance BuildInstance(Lwm2mPath instancePath, IReadOnlyList<NodeLeaf> leaves, ILwm2mModel? model) =>
        new(instancePath.ObjectInstanceId!.Value, leaves
            .GroupBy(l => l.Path.ResourceId!.Value)
            .Select(g => BuildResource(instancePath.Append(g.Key), g.ToList(), model)));

    private static Lwm2mResource BuildResource(Lwm2mPath resourcePath, IReadOnlyList<NodeLeaf> leaves, ILwm2mModel? model)
    {
        var resourceModel = model.GetResource(resourcePath);
        bool multiple = resourceModel?.Multiple ?? leaves.Any(l => l.Path.IsResourceInstance);
        if (!multiple)
        {
            if (leaves is [{ Path.IsResource: true } only])
            {
                return new Lwm2mSingleResource(resourcePath.ResourceId!.Value, only.Value);
            }

            throw new Lwm2mException(Lwm2mErrorCode.InvalidNode, $"{resourcePath} is a single Resource but the payload holds {leaves.Count} values for it, or values for its instances");
        }

        if (leaves.FirstOrDefault(l => !l.Path.IsResourceInstance) is { } stray)
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidNode, $"{resourcePath} is a multiple Resource but the payload holds a value for {stray.Path} itself");
        }

        var type = resourceModel?.Type ?? CommonType(leaves, resourcePath);
        return new Lwm2mMultipleResource(
            resourcePath.ResourceId!.Value,
            type,
            leaves.Select(l => new Lwm2mResourceInstance(l.Path.ResourceInstanceId!.Value, Convert(l.Value, type, l.Path))));
    }

    // Without a model, a multiple Resource's type comes from its values. Integers mixed with
    // floats widen to Float, since SenML writes a whole Float as an integer.
    private static Lwm2mType CommonType(IReadOnlyList<NodeLeaf> leaves, Lwm2mPath resourcePath)
    {
        var types = leaves.Select(l => l.Value.Type).Distinct().ToList();
        return types switch
        {
            [] => Lwm2mType.String,
            [var single] => single,
            _ when types.All(t => t is Lwm2mType.Integer or Lwm2mType.UnsignedInteger or Lwm2mType.Float) => Lwm2mType.Float,
            _ => throw new Lwm2mException(Lwm2mErrorCode.TypeMismatch, $"the instances of {resourcePath} hold different types: {string.Join(", ", types)}"),
        };
    }

    private static string Describe(Lwm2mNode node) => node switch
    {
        Lwm2mObject => $"Object {node.Id}",
        Lwm2mObjectInstance => $"Object Instance {node.Id}",
        Lwm2mResource => $"Resource {node.Id}",
        _ => $"Resource Instance {node.Id}",
    };
}

/// <summary>Direct conversion between nodes and TLV entries, keeping value types and empty multiple Resources intact.</summary>
internal static class NodeTlv
{
    public static IReadOnlyList<TlvEntry> ToEntries(Lwm2mNode node, Lwm2mPath path, ILwm2mModel? model)
    {
        NodeLeaves.Validate(node, path);
        return node switch
        {
            Lwm2mObject o => o.Instances.Values.Select(i => InstanceEntry(path.Append(i.Id), i, model)).ToList(),
            Lwm2mObjectInstance i when path.IsObject => [InstanceEntry(path.Append(i.Id), i, model)],
            Lwm2mObjectInstance i => ResourceEntries(path, i, model),
            Lwm2mResource r => [ResourceEntry(path, r, model)],
            Lwm2mResourceInstance ri => [TlvEntry.WithValue(TlvEntryType.ResourceInstance, ri.Id, Value(path, ri.Value, model))],
            _ => throw new Lwm2mException(Lwm2mErrorCode.InvalidNode, "unknown node type"),
        };
    }

    public static Lwm2mNode ToNode(IReadOnlyList<TlvEntry> entries, Lwm2mPath path, ILwm2mModel? model)
    {
        switch (path.Depth)
        {
            case 1:
                if (entries.All(e => e.Type == TlvEntryType.ObjectInstance))
                {
                    return new Lwm2mObject(path.ObjectId, entries.Select(e => Instance(path.Append(e.Id), e.Children, model)));
                }

                // A single-instance Object may be sent as its Resources alone, with no Instance entry.
                if (entries.All(e => e.Type is TlvEntryType.Resource or TlvEntryType.MultipleResource))
                {
                    return new Lwm2mObject(path.ObjectId, Instance(path.Append(0), entries, model));
                }

                throw Tlv.Malformed($"a TLV payload for {path} mixes Object Instance and Resource entries");

            case 2:
                if (entries is [{ Type: TlvEntryType.ObjectInstance } wrapper])
                {
                    if (wrapper.Id != path.ObjectInstanceId)
                    {
                        throw Tlv.Malformed($"the payload holds Object Instance {wrapper.Id}, not {path}");
                    }

                    return Instance(path, wrapper.Children, model);
                }

                return Instance(path, entries, model);

            case 3:
                if (entries is [{ Type: TlvEntryType.Resource or TlvEntryType.MultipleResource } entry])
                {
                    if (entry.Id != path.ResourceId)
                    {
                        throw Tlv.Malformed($"the payload holds Resource {entry.Id}, not {path}");
                    }

                    return Resource(path, entry, model);
                }

                if (entries.All(e => e.Type == TlvEntryType.ResourceInstance))
                {
                    return Multiple(path, entries, model);
                }

                throw Tlv.Malformed($"expected one Resource entry for {path}");

            default:
                if (entries is [{ Type: TlvEntryType.ResourceInstance or TlvEntryType.Resource } item] && item.Id == path.ResourceInstanceId)
                {
                    return new Lwm2mResourceInstance(item.Id, Decode(path, item, model));
                }

                throw Tlv.Malformed($"expected one Resource Instance entry for {path}");
        }
    }

    private static Lwm2mObjectInstance Instance(Lwm2mPath instancePath, IReadOnlyList<TlvEntry> entries, ILwm2mModel? model)
    {
        var resources = entries.Select(e => e.Type is TlvEntryType.Resource or TlvEntryType.MultipleResource
            ? Resource(instancePath.Append(e.Id), e, model)
            : throw Tlv.Malformed($"an Object Instance may only contain Resource entries, found {e.Type} {e.Id}"));
        try
        {
            return new Lwm2mObjectInstance(instancePath.ObjectInstanceId!.Value, resources);
        }
        catch (ArgumentException e) when (e is not ArgumentNullException)
        {
            throw new Lwm2mException(Lwm2mErrorCode.MalformedTlv, $"{instancePath}: {e.Message}", e);
        }
    }

    private static Lwm2mResource Resource(Lwm2mPath resourcePath, TlvEntry entry, ILwm2mModel? model) =>
        entry.Type == TlvEntryType.Resource
            ? new Lwm2mSingleResource(entry.Id, Decode(resourcePath, entry, model))
            : Multiple(resourcePath, entry.Children, model);

    private static Lwm2mMultipleResource Multiple(Lwm2mPath resourcePath, IReadOnlyList<TlvEntry> entries, ILwm2mModel? model)
    {
        var type = model.ResourceType(resourcePath) ?? Lwm2mType.Opaque;
        var instances = entries.Select(e => e.Type == TlvEntryType.ResourceInstance
            ? new Lwm2mResourceInstance(e.Id, Decode(resourcePath.Append(e.Id), e, model))
            : throw Tlv.Malformed($"a multiple Resource may only contain Resource Instance entries, found {e.Type}"));
        try
        {
            return new Lwm2mMultipleResource(resourcePath.ResourceId!.Value, type, instances);
        }
        catch (ArgumentException e) when (e is not ArgumentNullException)
        {
            throw new Lwm2mException(Lwm2mErrorCode.MalformedTlv, $"{resourcePath}: {e.Message}", e);
        }
    }

    private static Lwm2mValue Decode(Lwm2mPath path, TlvEntry entry, ILwm2mModel? model) =>
        TlvValues.Decode(entry.Value.Span, model.ResourceType(path) ?? Lwm2mType.Opaque, path);

    private static TlvEntry InstanceEntry(Lwm2mPath instancePath, Lwm2mObjectInstance instance, ILwm2mModel? model) =>
        TlvEntry.WithChildren(TlvEntryType.ObjectInstance, instance.Id, ResourceEntries(instancePath, instance, model));

    private static List<TlvEntry> ResourceEntries(Lwm2mPath instancePath, Lwm2mObjectInstance instance, ILwm2mModel? model) =>
        instance.Resources.Values.Select(r => ResourceEntry(instancePath.Append(r.Id), r, model)).ToList();

    private static TlvEntry ResourceEntry(Lwm2mPath resourcePath, Lwm2mResource resource, ILwm2mModel? model) => resource switch
    {
        Lwm2mSingleResource single => TlvEntry.WithValue(TlvEntryType.Resource, single.Id, Value(resourcePath, single.Value, model)),
        Lwm2mMultipleResource multiple => TlvEntry.WithChildren(
            TlvEntryType.MultipleResource,
            multiple.Id,
            multiple.Instances.Values.Select(i => TlvEntry.WithValue(TlvEntryType.ResourceInstance, i.Id, Value(resourcePath.Append(i.Id), i.Value, model)))),
        _ => throw new Lwm2mException(Lwm2mErrorCode.InvalidNode, "unknown Resource type"),
    };

    private static byte[] Value(Lwm2mPath path, Lwm2mValue value, ILwm2mModel? model)
    {
        var converted = model.ResourceType(path) is { } declared ? NodeLeaves.Convert(value, declared, path) : value;
        return TlvValues.Encode(converted, path);
    }
}

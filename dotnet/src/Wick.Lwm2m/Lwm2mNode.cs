using System.Collections.Immutable;
using System.Text;

namespace Wick.Lwm2m;

/// <summary>
/// A node in the LwM2M Object tree: an Object, an Object Instance, a Resource or a Resource Instance.
/// </summary>
/// <remarks>
/// <para>
/// This is what a Read returns and what a Write carries, independent of content format. A node
/// does not know its own path; the request path supplies the context, as it does on the wire.
/// </para>
/// <para>Nodes are immutable and compare by content. Children are kept in ascending ID order.</para>
/// </remarks>
public abstract class Lwm2mNode : IEquatable<Lwm2mNode>
{
    private protected Lwm2mNode(int id)
    {
        if (id is < 0 or > Lwm2mPath.MaxId)
        {
            throw new ArgumentOutOfRangeException(nameof(id), id, $"a node ID must be in 0 to {Lwm2mPath.MaxId}");
        }

        Id = id;
    }

    /// <summary>The node's ID at its own level: an Object ID, Instance ID, Resource ID or Resource Instance ID.</summary>
    public int Id { get; }

    /// <inheritdoc/>
    public abstract bool Equals(Lwm2mNode? other);

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is Lwm2mNode node && Equals(node);

    /// <inheritdoc/>
    public abstract override int GetHashCode();

    private protected static ImmutableSortedDictionary<int, T> Index<T>(IEnumerable<T> children, string what)
        where T : Lwm2mNode
    {
        ArgumentNullException.ThrowIfNull(children);
        var builder = ImmutableSortedDictionary.CreateBuilder<int, T>();
        foreach (var child in children)
        {
            ArgumentNullException.ThrowIfNull(child);
            if (!builder.TryAdd(child.Id, child))
            {
                throw new ArgumentException($"duplicate {what} ID {child.Id}", nameof(children));
            }
        }

        return builder.ToImmutable();
    }

    private protected static bool SameChildren<T>(IReadOnlyDictionary<int, T> left, IReadOnlyDictionary<int, T> right)
        where T : Lwm2mNode
    {
        if (left.Count != right.Count)
        {
            return false;
        }

        foreach (var (id, node) in left)
        {
            if (!right.TryGetValue(id, out var other) || !node.Equals(other))
            {
                return false;
            }
        }

        return true;
    }

    private protected static int HashChildren<T>(int seed, IReadOnlyDictionary<int, T> children)
        where T : Lwm2mNode
    {
        var hash = new HashCode();
        hash.Add(seed);
        foreach (var child in children.Values)
        {
            hash.Add(child.GetHashCode());
        }

        return hash.ToHashCode();
    }

    private protected static string Render<T>(string label, int id, IReadOnlyDictionary<int, T> children)
        where T : Lwm2mNode
    {
        var builder = new StringBuilder().Append(label).Append('(').Append(id).Append(") {");
        builder.AppendJoin(", ", children.Values);
        return builder.Append('}').ToString();
    }
}

/// <summary>An Object node: the Object Instances under one Object ID.</summary>
public sealed class Lwm2mObject : Lwm2mNode
{
    /// <summary>Creates an Object node.</summary>
    /// <param name="id">The Object ID.</param>
    /// <param name="instances">The Object Instances. IDs must be unique.</param>
    public Lwm2mObject(int id, IEnumerable<Lwm2mObjectInstance> instances)
        : base(id)
    {
        Instances = Index(instances, "Object Instance");
    }

    /// <summary>Creates an Object node.</summary>
    /// <param name="id">The Object ID.</param>
    /// <param name="instances">The Object Instances. IDs must be unique.</param>
    public Lwm2mObject(int id, params Lwm2mObjectInstance[] instances)
        : this(id, (IEnumerable<Lwm2mObjectInstance>)instances)
    {
    }

    /// <summary>The Object Instances, keyed and ordered by Instance ID.</summary>
    public IReadOnlyDictionary<int, Lwm2mObjectInstance> Instances { get; }

    /// <inheritdoc/>
    public override bool Equals(Lwm2mNode? other) =>
        other is Lwm2mObject o && o.Id == Id && SameChildren(Instances, o.Instances);

    /// <inheritdoc/>
    public override int GetHashCode() => HashChildren(Id, Instances);

    /// <inheritdoc/>
    public override string ToString() => Render("Object", Id, Instances);
}

/// <summary>An Object Instance node: the Resources of one Instance.</summary>
public sealed class Lwm2mObjectInstance : Lwm2mNode
{
    /// <summary>Creates an Object Instance node.</summary>
    /// <param name="id">The Object Instance ID.</param>
    /// <param name="resources">The Resources. IDs must be unique.</param>
    public Lwm2mObjectInstance(int id, IEnumerable<Lwm2mResource> resources)
        : base(id)
    {
        Resources = Index(resources, "Resource");
    }

    /// <summary>Creates an Object Instance node.</summary>
    /// <param name="id">The Object Instance ID.</param>
    /// <param name="resources">The Resources. IDs must be unique.</param>
    public Lwm2mObjectInstance(int id, params Lwm2mResource[] resources)
        : this(id, (IEnumerable<Lwm2mResource>)resources)
    {
    }

    /// <summary>The Resources, keyed and ordered by Resource ID.</summary>
    public IReadOnlyDictionary<int, Lwm2mResource> Resources { get; }

    /// <inheritdoc/>
    public override bool Equals(Lwm2mNode? other) =>
        other is Lwm2mObjectInstance o && o.Id == Id && SameChildren(Resources, o.Resources);

    /// <inheritdoc/>
    public override int GetHashCode() => HashChildren(Id, Resources);

    /// <inheritdoc/>
    public override string ToString() => Render("Instance", Id, Resources);
}

/// <summary>A Resource node, either single-instance (<see cref="Lwm2mSingleResource"/>) or multiple-instance (<see cref="Lwm2mMultipleResource"/>).</summary>
public abstract class Lwm2mResource : Lwm2mNode
{
    private protected Lwm2mResource(int id, Lwm2mType type)
        : base(id)
    {
        Type = type;
    }

    /// <summary>The LwM2M type of the Resource's value or values.</summary>
    public Lwm2mType Type { get; }

    /// <summary>True for a multiple-instance Resource.</summary>
    public abstract bool IsMultiple { get; }
}

/// <summary>A single-instance Resource holding one value.</summary>
public sealed class Lwm2mSingleResource : Lwm2mResource
{
    /// <summary>Creates a single-instance Resource.</summary>
    /// <param name="id">The Resource ID.</param>
    /// <param name="value">The value.</param>
    public Lwm2mSingleResource(int id, Lwm2mValue value)
        : base(id, (value ?? throw new ArgumentNullException(nameof(value))).Type)
    {
        Value = value;
    }

    /// <summary>The Resource's value.</summary>
    public Lwm2mValue Value { get; }

    /// <inheritdoc/>
    public override bool IsMultiple => false;

    /// <inheritdoc/>
    public override bool Equals(Lwm2mNode? other) =>
        other is Lwm2mSingleResource r && r.Id == Id && r.Value.Equals(Value);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Id, Value);

    /// <inheritdoc/>
    public override string ToString() => $"Resource({Id})={Value}";
}

/// <summary>A multiple-instance Resource: Resource Instances that all share one type.</summary>
public sealed class Lwm2mMultipleResource : Lwm2mResource
{
    /// <summary>Creates a multiple-instance Resource.</summary>
    /// <param name="id">The Resource ID.</param>
    /// <param name="type">The type every instance holds.</param>
    /// <param name="instances">The Resource Instances. IDs must be unique and every value must have <paramref name="type"/>.</param>
    public Lwm2mMultipleResource(int id, Lwm2mType type, IEnumerable<Lwm2mResourceInstance> instances)
        : base(id, type)
    {
        Instances = Index(instances, "Resource Instance");
        foreach (var instance in Instances.Values)
        {
            if (instance.Value.Type != type)
            {
                throw new ArgumentException(
                    $"Resource Instance {instance.Id} holds {instance.Value.Type} but Resource {id} is {type}", nameof(instances));
            }
        }
    }

    /// <summary>Creates a multiple-instance Resource.</summary>
    /// <param name="id">The Resource ID.</param>
    /// <param name="type">The type every instance holds.</param>
    /// <param name="instances">The Resource Instances.</param>
    public Lwm2mMultipleResource(int id, Lwm2mType type, params Lwm2mResourceInstance[] instances)
        : this(id, type, (IEnumerable<Lwm2mResourceInstance>)instances)
    {
    }

    /// <summary>The Resource Instances, keyed and ordered by Resource Instance ID.</summary>
    public IReadOnlyDictionary<int, Lwm2mResourceInstance> Instances { get; }

    /// <inheritdoc/>
    public override bool IsMultiple => true;

    /// <inheritdoc/>
    public override bool Equals(Lwm2mNode? other) =>
        other is Lwm2mMultipleResource r && r.Id == Id && r.Type == Type && SameChildren(Instances, r.Instances);

    /// <inheritdoc/>
    public override int GetHashCode() => HashChildren(HashCode.Combine(Id, Type), Instances);

    /// <inheritdoc/>
    public override string ToString() => Render("MultipleResource", Id, Instances);
}

/// <summary>One instance of a multiple-instance Resource.</summary>
public sealed class Lwm2mResourceInstance : Lwm2mNode
{
    /// <summary>Creates a Resource Instance.</summary>
    /// <param name="id">The Resource Instance ID.</param>
    /// <param name="value">The value.</param>
    public Lwm2mResourceInstance(int id, Lwm2mValue value)
        : base(id)
    {
        Value = value ?? throw new ArgumentNullException(nameof(value));
    }

    /// <summary>The instance's value.</summary>
    public Lwm2mValue Value { get; }

    /// <inheritdoc/>
    public override bool Equals(Lwm2mNode? other) =>
        other is Lwm2mResourceInstance r && r.Id == Id && r.Value.Equals(Value);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Id, Value);

    /// <inheritdoc/>
    public override string ToString() => $"ResourceInstance({Id})={Value}";
}

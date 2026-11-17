using System.Collections.Immutable;

namespace Wick.Lwm2m.Model;

/// <summary>The operations a server may perform on a Resource, from the DDF <c>Operations</c> element.</summary>
[Flags]
public enum ResourceOperations
{
    /// <summary>No operations.</summary>
    None = 0,

    /// <summary>Read (R).</summary>
    Read = 1,

    /// <summary>Write (W).</summary>
    Write = 2,

    /// <summary>Execute (E).</summary>
    Execute = 4,

    /// <summary>Read and Write (RW).</summary>
    ReadWrite = Read | Write,
}

/// <summary>
/// The definition of one Resource within an Object, as declared by its DDF <c>Item</c>.
/// </summary>
/// <param name="Id">The Resource ID.</param>
/// <param name="Name">The Resource name.</param>
/// <param name="Operations">The operations the Resource allows.</param>
/// <param name="Multiple">True when the Resource holds multiple instances.</param>
/// <param name="Mandatory">True when the Resource is mandatory in its Object.</param>
/// <param name="Type">The declared value type. <see cref="Lwm2mType.None"/> for Executable Resources.</param>
public sealed record ResourceModel(
    int Id,
    string Name,
    ResourceOperations Operations,
    bool Multiple,
    bool Mandatory,
    Lwm2mType Type)
{
    /// <summary>The free-text range or enumeration, or <see langword="null"/>.</summary>
    public string? RangeEnumeration { get; init; }

    /// <summary>The units, or <see langword="null"/>.</summary>
    public string? Units { get; init; }

    /// <summary>The description, or <see langword="null"/>.</summary>
    public string? Description { get; init; }

    /// <summary>True when the Resource allows Read.</summary>
    public bool IsReadable => Operations.HasFlag(ResourceOperations.Read);

    /// <summary>True when the Resource allows Write.</summary>
    public bool IsWritable => Operations.HasFlag(ResourceOperations.Write);

    /// <summary>True when the Resource allows Execute.</summary>
    public bool IsExecutable => Operations.HasFlag(ResourceOperations.Execute);
}

/// <summary>
/// The definition of an LwM2M Object, as declared by its DDF file.
/// </summary>
public sealed record ObjectModel
{
    private readonly ImmutableSortedDictionary<int, ResourceModel> _resources;

    /// <summary>Creates an Object definition.</summary>
    /// <param name="id">The Object ID.</param>
    /// <param name="name">The Object name.</param>
    /// <param name="multiple">True when the Object may have more than one Instance.</param>
    /// <param name="mandatory">True when the Object is mandatory.</param>
    /// <param name="resources">The Resource definitions. IDs must be unique.</param>
    public ObjectModel(int id, string name, bool multiple, bool mandatory, IEnumerable<ResourceModel> resources)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(resources);
        var builder = ImmutableSortedDictionary.CreateBuilder<int, ResourceModel>();
        foreach (var resource in resources)
        {
            if (!builder.TryAdd(resource.Id, resource))
            {
                throw new ArgumentException($"duplicate Resource ID {resource.Id} in Object {id}", nameof(resources));
            }
        }

        Id = id;
        Name = name;
        Multiple = multiple;
        Mandatory = mandatory;
        _resources = builder.ToImmutable();
    }

    /// <summary>The Object ID.</summary>
    public int Id { get; }

    /// <summary>The Object name.</summary>
    public string Name { get; }

    /// <summary>True when the Object may have more than one Instance.</summary>
    public bool Multiple { get; }

    /// <summary>True when the Object is mandatory.</summary>
    public bool Mandatory { get; }

    /// <summary>The description, or <see langword="null"/>.</summary>
    public string? Description { get; init; }

    /// <summary>The Object URN, such as <c>urn:oma:lwm2m:oma:3</c>, or <see langword="null"/>.</summary>
    public string? Urn { get; init; }

    /// <summary>The LwM2M version the definition targets, such as <c>1.1</c>, or <see langword="null"/>.</summary>
    public string? Lwm2mVersion { get; init; }

    /// <summary>The Object's own version, such as <c>1.2</c>, or <see langword="null"/>.</summary>
    public string? ObjectVersion { get; init; }

    /// <summary>The Resource definitions, in ascending ID order.</summary>
    public IReadOnlyCollection<ResourceModel> Resources => _resources.Values.ToArray();

    /// <summary>Looks up a Resource definition by ID.</summary>
    /// <param name="resourceId">The Resource ID.</param>
    /// <returns>The definition, or <see langword="null"/> when the Object declares no such Resource.</returns>
    public ResourceModel? GetResource(int resourceId) => _resources.GetValueOrDefault(resourceId);

    /// <inheritdoc/>
    public bool Equals(ObjectModel? other) =>
        other is not null && other.Id == Id && other.Name == Name && other.Multiple == Multiple &&
        other.Mandatory == Mandatory && other.Description == Description && other.Urn == Urn &&
        other.Lwm2mVersion == Lwm2mVersion && other.ObjectVersion == ObjectVersion &&
        other._resources.Values.SequenceEqual(_resources.Values);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(Id, Name, ObjectVersion, _resources.Count);
}

/// <summary>
/// A source of Object and Resource definitions, used to type values on formats that do not carry type.
/// </summary>
/// <remarks>
/// TLV and plain text are not self-describing: four bytes of TLV could be an Integer, a Float or a
/// Time. SenML is partly self-describing but cannot tell an Integer from an Unsigned Integer or a
/// Time. Wick asks the model wherever the wire falls short. Every codec also accepts no model at
/// all and falls back to the best inference the format allows, so a vendor Object with no DDF
/// degrades rather than failing.
/// </remarks>
public interface ILwm2mModel
{
    /// <summary>Looks up an Object definition.</summary>
    /// <param name="objectId">The Object ID.</param>
    /// <returns>The definition, or <see langword="null"/> when the model has none.</returns>
    ObjectModel? GetObject(int objectId);
}

/// <summary>Helpers for querying an optional <see cref="ILwm2mModel"/>.</summary>
public static class Lwm2mModelExtensions
{
    /// <summary>
    /// The Resource definition the path resolves to, or <see langword="null"/> when there is no model,
    /// no such Object or Resource, or the path is above Resource level.
    /// </summary>
    /// <param name="model">The model, or <see langword="null"/>.</param>
    /// <param name="path">A Resource or Resource Instance path.</param>
    /// <returns>The Resource definition, or <see langword="null"/>.</returns>
    public static ResourceModel? GetResource(this ILwm2mModel? model, Lwm2mPath path)
    {
        ArgumentNullException.ThrowIfNull(path);
        return path.ResourceId is { } resourceId ? model?.GetObject(path.ObjectId)?.GetResource(resourceId) : null;
    }

    /// <summary>
    /// The type declared for the Resource at the path, or <see langword="null"/> when unknown. A Resource
    /// Instance path answers with its Resource's type.
    /// </summary>
    /// <param name="model">The model, or <see langword="null"/>.</param>
    /// <param name="path">The path.</param>
    /// <returns>The declared type, or <see langword="null"/>.</returns>
    public static Lwm2mType? ResourceType(this ILwm2mModel? model, Lwm2mPath path) => model.GetResource(path)?.Type;
}

using System.Collections.Immutable;

namespace Wick.Lwm2m.Model;

/// <summary>
/// An immutable collection of Object definitions, keyed by Object ID.
/// </summary>
/// <remarks>
/// <see cref="Standard"/> holds the bundled catalogue: Security (0), Server (1), Access Control (2),
/// Device (3), Connectivity Monitoring (4), Firmware Update (5), Location (6), Connectivity
/// Statistics (7), OSCORE (21) and Temperature (3303). The DDF files are embedded in the assembly,
/// so loading it needs no file access. Custom Objects are added with <see cref="With(ObjectModel)"/>,
/// typically from <see cref="DdfParser.Parse(string)"/> at run time, which returns a new registry
/// and leaves the original unchanged.
/// </remarks>
public sealed class ObjectRegistry : ILwm2mModel
{
    private static readonly Lazy<ObjectRegistry> StandardRegistry = new(LoadStandard, LazyThreadSafetyMode.ExecutionAndPublication);

    private readonly ImmutableSortedDictionary<int, ObjectModel> _objects;

    private ObjectRegistry(ImmutableSortedDictionary<int, ObjectModel> objects)
    {
        _objects = objects;
    }

    /// <summary>An empty registry.</summary>
    public static ObjectRegistry Empty { get; } = new(ImmutableSortedDictionary<int, ObjectModel>.Empty);

    /// <summary>The registry preloaded with the bundled Object catalogue.</summary>
    public static ObjectRegistry Standard => StandardRegistry.Value;

    /// <summary>The Object IDs held, ascending.</summary>
    public IReadOnlyList<int> ObjectIds => _objects.Keys.ToArray();

    /// <summary>The number of Objects held.</summary>
    public int Count => _objects.Count;

    /// <summary>Builds a registry from definitions. A later definition replaces an earlier one with the same ID.</summary>
    /// <param name="objects">The definitions.</param>
    /// <returns>The registry.</returns>
    public static ObjectRegistry From(IEnumerable<ObjectModel> objects)
    {
        ArgumentNullException.ThrowIfNull(objects);
        var builder = ImmutableSortedDictionary.CreateBuilder<int, ObjectModel>();
        foreach (var model in objects)
        {
            builder[model.Id] = model;
        }

        return new ObjectRegistry(builder.ToImmutable());
    }

    /// <inheritdoc/>
    public ObjectModel? GetObject(int objectId) => _objects.GetValueOrDefault(objectId);

    /// <summary>Returns a registry that also holds <paramref name="model"/>, replacing any definition with the same ID.</summary>
    /// <param name="model">The definition to add.</param>
    /// <returns>A new registry.</returns>
    public ObjectRegistry With(ObjectModel model)
    {
        ArgumentNullException.ThrowIfNull(model);
        return new ObjectRegistry(_objects.SetItem(model.Id, model));
    }

    /// <summary>Returns a registry that also holds every definition in <paramref name="models"/>.</summary>
    /// <param name="models">The definitions to add.</param>
    /// <returns>A new registry.</returns>
    public ObjectRegistry With(IEnumerable<ObjectModel> models)
    {
        ArgumentNullException.ThrowIfNull(models);
        return new ObjectRegistry(_objects.SetItems(models.Select(m => KeyValuePair.Create(m.Id, m))));
    }

    /// <summary>Returns a registry without the Object <paramref name="objectId"/>.</summary>
    /// <param name="objectId">The Object ID to remove.</param>
    /// <returns>A new registry.</returns>
    public ObjectRegistry Without(int objectId) => new(_objects.Remove(objectId));

    private static ObjectRegistry LoadStandard()
    {
        const string prefix = "Wick.Lwm2m.Ddf.";
        var assembly = typeof(ObjectRegistry).Assembly;
        var models = new List<ObjectModel>();
        foreach (var name in assembly.GetManifestResourceNames().Where(n => n.StartsWith(prefix, StringComparison.Ordinal)))
        {
            using var stream = assembly.GetManifestResourceStream(name)
                ?? throw new InvalidOperationException($"embedded DDF {name} is missing");
            models.Add(DdfParser.Parse(stream));
        }

        return From(models);
    }
}

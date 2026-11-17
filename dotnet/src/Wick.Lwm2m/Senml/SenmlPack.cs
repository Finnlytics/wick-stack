using System.Collections.Immutable;

namespace Wick.Lwm2m.Senml;

/// <summary>
/// An ordered list of SenML records: the unit every SenML codec encodes and decodes.
/// </summary>
public sealed class SenmlPack : IEquatable<SenmlPack>
{
    /// <summary>Creates a pack.</summary>
    /// <param name="records">The records, in order.</param>
    public SenmlPack(IEnumerable<SenmlRecord> records)
    {
        ArgumentNullException.ThrowIfNull(records);
        Records = records.ToImmutableArray();
    }

    /// <summary>Creates a pack.</summary>
    /// <param name="records">The records, in order.</param>
    public SenmlPack(params SenmlRecord[] records)
        : this((IEnumerable<SenmlRecord>)records)
    {
    }

    /// <summary>The records, in order.</summary>
    public IReadOnlyList<SenmlRecord> Records { get; }

    /// <summary>
    /// Builds a pack with one value-less record per path, the body of a Read-Composite or
    /// Observe-Composite request. Encode it with no-value records allowed.
    /// </summary>
    /// <param name="paths">The paths.</param>
    /// <returns>The pack.</returns>
    public static SenmlPack FromPaths(IEnumerable<Lwm2mPath> paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        return new SenmlPack(paths.Select(p => new SenmlRecord { Name = p.ToString() }));
    }

    /// <summary>
    /// Applies the base fields (RFC 8428 §4.5) to give every record its effective name and time.
    /// </summary>
    /// <remarks>
    /// A base name or base time applies to its own record and every later record until replaced.
    /// A record with no time and no base time in scope resolves to a <see langword="null"/> time,
    /// so "no timestamp" stays distinct from "at the base time".
    /// </remarks>
    /// <returns>One resolved entry per record, in pack order.</returns>
    public IReadOnlyList<ResolvedSenmlRecord> Resolve()
    {
        var resolved = new List<ResolvedSenmlRecord>(Records.Count);
        string baseName = string.Empty;
        SenmlNumber? baseTime = null;
        foreach (var record in Records)
        {
            baseName = record.BaseName ?? baseName;
            baseTime = record.BaseTime ?? baseTime;
            SenmlNumber? time = (baseTime, record.Time) switch
            {
                (null, null) => null,
                ({ } b, null) => b,
                (null, { } t) => t,
                ({ } b, { } t) => b + t,
            };
            resolved.Add(new ResolvedSenmlRecord(baseName + (record.Name ?? string.Empty), time, record));
        }

        return resolved;
    }

    /// <summary>Reads the pack as a list of paths, the inverse of <see cref="FromPaths"/>. Values are ignored.</summary>
    /// <returns>The paths, in pack order.</returns>
    /// <exception cref="Lwm2mException">
    /// <see cref="Lwm2mErrorCode.MissingName"/> for a record with no name, or
    /// <see cref="Lwm2mErrorCode.InvalidPath"/> when a name is not an LwM2M path.
    /// </exception>
    public IReadOnlyList<Lwm2mPath> ToPaths() => Resolve()
        .Select(r => r.Name.Length == 0
            ? throw new Lwm2mException(Lwm2mErrorCode.MissingName, "a record has no name")
            : Lwm2mPath.Parse(r.Name))
        .ToList();

    /// <inheritdoc/>
    public bool Equals(SenmlPack? other) => other is not null && Records.SequenceEqual(other.Records);

    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is SenmlPack other && Equals(other);

    /// <inheritdoc/>
    public override int GetHashCode() => Records.Count == 0 ? 0 : HashCode.Combine(Records.Count, Records[0]);
}

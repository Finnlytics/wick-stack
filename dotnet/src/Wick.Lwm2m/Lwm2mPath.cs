using System.Globalization;
using System.Text;

namespace Wick.Lwm2m;

/// <summary>
/// An LwM2M path: an Object, an Object Instance, a Resource or a Resource Instance.
/// </summary>
/// <remarks>
/// <para>
/// The shape is <c>/{object}[/{instance}[/{resource}[/{resource-instance}]]]</c> (OMA LwM2M 1.2
/// §7.1). Every component is an integer in the range 0 to 65535. Absent trailing components are
/// <see langword="null"/>, and a component can only be present when every component before it is.
/// </para>
/// <para>Paths are immutable values and compare by their components.</para>
/// </remarks>
public sealed record Lwm2mPath : IComparable<Lwm2mPath>
{
    /// <summary>The largest value any path component may take.</summary>
    public const int MaxId = 65535;

    /// <summary>Creates a path, validating that each component is in range and that no level is skipped.</summary>
    /// <param name="objectId">The Object ID.</param>
    /// <param name="objectInstanceId">The Object Instance ID, or <see langword="null"/>.</param>
    /// <param name="resourceId">The Resource ID, or <see langword="null"/>.</param>
    /// <param name="resourceInstanceId">The Resource Instance ID, or <see langword="null"/>.</param>
    /// <exception cref="Lwm2mException">A component is out of range, or a level is skipped.</exception>
    public Lwm2mPath(int objectId, int? objectInstanceId = null, int? resourceId = null, int? resourceInstanceId = null)
    {
        Check(objectId);
        if (objectInstanceId is { } i)
        {
            Check(i);
        }

        if (resourceId is { } r)
        {
            Check(r);
        }

        if (resourceInstanceId is { } ri)
        {
            Check(ri);
        }

        if ((resourceId is not null && objectInstanceId is null) ||
            (resourceInstanceId is not null && resourceId is null))
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, "a path component cannot be present when the one before it is absent");
        }

        ObjectId = objectId;
        ObjectInstanceId = objectInstanceId;
        ResourceId = resourceId;
        ResourceInstanceId = resourceInstanceId;
    }

    /// <summary>The Object ID.</summary>
    public int ObjectId { get; }

    /// <summary>The Object Instance ID, or <see langword="null"/> for an Object path.</summary>
    public int? ObjectInstanceId { get; }

    /// <summary>The Resource ID, or <see langword="null"/> for an Object or Object Instance path.</summary>
    public int? ResourceId { get; }

    /// <summary>The Resource Instance ID, or <see langword="null"/> unless this is a Resource Instance path.</summary>
    public int? ResourceInstanceId { get; }

    /// <summary>The number of components: 1 for an Object path up to 4 for a Resource Instance path.</summary>
    public int Depth => ResourceInstanceId is not null ? 4 : ResourceId is not null ? 3 : ObjectInstanceId is not null ? 2 : 1;

    /// <summary>True for an Object path such as <c>/3</c>.</summary>
    public bool IsObject => Depth == 1;

    /// <summary>True for an Object Instance path such as <c>/3/0</c>.</summary>
    public bool IsObjectInstance => Depth == 2;

    /// <summary>True for a Resource path such as <c>/3/0/9</c>.</summary>
    public bool IsResource => Depth == 3;

    /// <summary>True for a Resource Instance path such as <c>/3/0/6/1</c>.</summary>
    public bool IsResourceInstance => Depth == 4;

    /// <summary>Parses a path such as <c>/3/0/9</c>. The leading slash is optional.</summary>
    /// <param name="text">The path text.</param>
    /// <returns>The parsed path.</returns>
    /// <exception cref="Lwm2mException">The text is not a valid LwM2M path.</exception>
    public static Lwm2mPath Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return TryParse(text, out var path, out var reason)
            ? path
            : throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, reason);
    }

    /// <summary>Parses a path, returning <see langword="false"/> rather than throwing when it is invalid.</summary>
    /// <param name="text">The path text.</param>
    /// <param name="path">The parsed path when the method returns <see langword="true"/>.</param>
    /// <returns>Whether the text was a valid path.</returns>
    public static bool TryParse(string? text, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out Lwm2mPath? path)
    {
        if (text is null)
        {
            path = null;
            return false;
        }

        return TryParse(text, out path, out _);
    }

    /// <summary>Builds a path from its component strings, the form a CoAP Uri-Path option list arrives in.</summary>
    /// <param name="segments">The path segments, for example <c>["3", "0", "9"]</c>.</param>
    /// <returns>The path.</returns>
    /// <exception cref="Lwm2mException">The segments do not form a valid LwM2M path.</exception>
    public static Lwm2mPath FromSegments(IReadOnlyList<string> segments)
    {
        ArgumentNullException.ThrowIfNull(segments);
        return TryFromSegments(segments, out var path, out var reason)
            ? path
            : throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, reason);
    }

    /// <summary>Builds a path from segments, returning <see langword="false"/> rather than throwing when they are invalid.</summary>
    /// <param name="segments">The path segments.</param>
    /// <param name="path">The path when the method returns <see langword="true"/>.</param>
    /// <returns>Whether the segments formed a valid path.</returns>
    public static bool TryFromSegments(IReadOnlyList<string> segments, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out Lwm2mPath? path)
        => TryFromSegments(segments, out path, out _);

    /// <summary>Returns the path's components as strings, the form a CoAP Uri-Path option list wants.</summary>
    /// <returns>One string per component.</returns>
    public IReadOnlyList<string> ToSegments()
    {
        var segments = new List<string>(4) { ObjectId.ToString(CultureInfo.InvariantCulture) };
        if (ObjectInstanceId is { } i)
        {
            segments.Add(i.ToString(CultureInfo.InvariantCulture));
        }

        if (ResourceId is { } r)
        {
            segments.Add(r.ToString(CultureInfo.InvariantCulture));
        }

        if (ResourceInstanceId is { } ri)
        {
            segments.Add(ri.ToString(CultureInfo.InvariantCulture));
        }

        return segments;
    }

    /// <summary>The path one level up, or <see langword="null"/> for an Object path.</summary>
    public Lwm2mPath? Parent => Depth switch
    {
        4 => new Lwm2mPath(ObjectId, ObjectInstanceId, ResourceId),
        3 => new Lwm2mPath(ObjectId, ObjectInstanceId),
        2 => new Lwm2mPath(ObjectId),
        _ => null,
    };

    /// <summary>Appends one component to the path.</summary>
    /// <param name="id">The next component.</param>
    /// <returns>A path one level deeper.</returns>
    /// <exception cref="Lwm2mException">The path is already a Resource Instance path, or the ID is out of range.</exception>
    public Lwm2mPath Append(int id) => Depth switch
    {
        1 => new Lwm2mPath(ObjectId, id),
        2 => new Lwm2mPath(ObjectId, ObjectInstanceId, id),
        3 => new Lwm2mPath(ObjectId, ObjectInstanceId, ResourceId, id),
        _ => throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, "a Resource Instance path has no child level"),
    };

    /// <summary>True when this path equals <paramref name="other"/> or is an ancestor of it.</summary>
    /// <param name="other">The path to test.</param>
    /// <returns>Whether <paramref name="other"/> is at or below this path.</returns>
    public bool Contains(Lwm2mPath other)
    {
        ArgumentNullException.ThrowIfNull(other);
        return other.Depth >= Depth &&
               other.ObjectId == ObjectId &&
               (ObjectInstanceId is null || other.ObjectInstanceId == ObjectInstanceId) &&
               (ResourceId is null || other.ResourceId == ResourceId) &&
               (ResourceInstanceId is null || other.ResourceInstanceId == ResourceInstanceId);
    }

    /// <summary>Orders paths component by component, with a shorter path before its descendants.</summary>
    /// <param name="other">The path to compare with.</param>
    /// <returns>A negative number, zero or a positive number.</returns>
    public int CompareTo(Lwm2mPath? other)
    {
        if (other is null)
        {
            return 1;
        }

        int c = ObjectId.CompareTo(other.ObjectId);
        if (c != 0)
        {
            return c;
        }

        c = Nullable.Compare(ObjectInstanceId, other.ObjectInstanceId);
        if (c != 0)
        {
            return c;
        }

        c = Nullable.Compare(ResourceId, other.ResourceId);
        return c != 0 ? c : Nullable.Compare(ResourceInstanceId, other.ResourceInstanceId);
    }

    /// <summary>Formats the path with a leading slash, for example <c>/3/0/9</c>.</summary>
    /// <returns>The path text.</returns>
    public override string ToString()
    {
        var builder = new StringBuilder();
        foreach (var segment in ToSegments())
        {
            builder.Append('/').Append(segment);
        }

        return builder.ToString();
    }

    private static void Check(int id)
    {
        if (id is < 0 or > MaxId)
        {
            throw new Lwm2mException(Lwm2mErrorCode.InvalidPath, $"path component {id} is outside 0 to {MaxId}");
        }
    }

    private static bool TryParse(string text, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out Lwm2mPath? path, out string reason)
    {
        var trimmed = text.StartsWith('/') ? text[1..] : text;
        if (trimmed.Length == 0)
        {
            path = null;
            reason = "a path must contain at least an Object ID";
            return false;
        }

        return TryFromSegments(trimmed.Split('/'), out path, out reason);
    }

    private static bool TryFromSegments(IReadOnlyList<string> segments, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out Lwm2mPath? path, out string reason)
    {
        path = null;
        if (segments.Count == 0)
        {
            reason = "a path must contain at least an Object ID";
            return false;
        }

        if (segments.Count > 4)
        {
            reason = "a path has at most four components";
            return false;
        }

        Span<int> ids = stackalloc int[4];
        for (int index = 0; index < segments.Count; index++)
        {
            var segment = segments[index];
            if (segment is null || segment.Length == 0 || segment.Length > 5 || !segment.All(char.IsAsciiDigit) ||
                !int.TryParse(segment, NumberStyles.None, CultureInfo.InvariantCulture, out var id) || id > MaxId)
            {
                reason = $"invalid path component: \"{segment}\"";
                return false;
            }

            ids[index] = id;
        }

        path = segments.Count switch
        {
            1 => new Lwm2mPath(ids[0]),
            2 => new Lwm2mPath(ids[0], ids[1]),
            3 => new Lwm2mPath(ids[0], ids[1], ids[2]),
            _ => new Lwm2mPath(ids[0], ids[1], ids[2], ids[3]),
        };
        reason = string.Empty;
        return true;
    }
}

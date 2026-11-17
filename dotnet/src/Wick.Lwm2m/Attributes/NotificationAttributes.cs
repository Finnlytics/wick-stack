using System.Globalization;
using Wick.Lwm2m.Links;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.Attributes;

/// <summary>Whether an attribute is absent, explicitly cleared, or set to a value.</summary>
public enum AttributeState
{
    /// <summary>Not mentioned; leaves whatever the client holds untouched.</summary>
    Absent,

    /// <summary>Removed, written as the bare name with no value (<c>?pmin</c>).</summary>
    Cleared,

    /// <summary>Set to a value.</summary>
    Set,
}

/// <summary>
/// One attribute value in Write-Attributes: absent, cleared, or set.
/// </summary>
/// <remarks>
/// Three states are needed because <c>pmin=0</c> (no minimum period), a bare <c>pmin</c> (remove the
/// attribute) and no <c>pmin</c> at all (leave it alone) all mean different things.
/// </remarks>
/// <typeparam name="T">The value type.</typeparam>
public readonly record struct AttributeValue<T>
    where T : struct
{
    private AttributeValue(AttributeState state, T value)
    {
        State = state;
        _value = value;
    }

    private readonly T _value;

    /// <summary>The state.</summary>
    public AttributeState State { get; }

    /// <summary>True when the attribute is set to a value.</summary>
    public bool IsSet => State == AttributeState.Set;

    /// <summary>The value when set, otherwise <see langword="null"/>.</summary>
    public T? Value => IsSet ? _value : null;

    /// <summary>The absent attribute.</summary>
    public static AttributeValue<T> Absent => default;

    /// <summary>The cleared attribute.</summary>
    public static AttributeValue<T> Cleared => new(AttributeState.Cleared, default);

    /// <summary>An attribute set to <paramref name="value"/>.</summary>
    /// <param name="value">The value.</param>
    /// <returns>The attribute.</returns>
    public static AttributeValue<T> Of(T value) => new(AttributeState.Set, value);

    /// <summary>Converts a value to a set attribute.</summary>
    /// <param name="value">The value.</param>
    public static implicit operator AttributeValue<T>(T value) => Of(value);

    /// <inheritdoc/>
    public override string ToString() => State switch
    {
        AttributeState.Set => Convert.ToString(_value, CultureInfo.InvariantCulture) ?? string.Empty,
        AttributeState.Cleared => "cleared",
        _ => "absent",
    };
}

/// <summary>
/// The LwM2M attributes of OMA LwM2M 1.2 §5.1: the NOTIFICATION class a server writes with
/// Write-Attributes (<c>pmin</c>, <c>pmax</c>, <c>gt</c>, <c>lt</c>, <c>st</c>, <c>epmin</c>, <c>epmax</c>)
/// and the PROPERTY class a client reports in Discover (<c>dim</c>, <c>ssid</c>, <c>uri</c>, <c>ver</c>).
/// </summary>
/// <remarks>
/// Periods are whole seconds. Thresholds and the step are decimals, so <c>gt=25.5</c> round-trips
/// exactly; they are written without exponent or trailing zeros, as Eclipse Leshan writes them.
/// </remarks>
public sealed record NotificationAttributes
{
    /// <summary>The minimum period in seconds between notifications.</summary>
    public AttributeValue<long> Pmin { get; init; }

    /// <summary>The maximum period in seconds without a notification.</summary>
    public AttributeValue<long> Pmax { get; init; }

    /// <summary>Notify when the value crosses above this threshold.</summary>
    public AttributeValue<decimal> Gt { get; init; }

    /// <summary>Notify when the value crosses below this threshold.</summary>
    public AttributeValue<decimal> Lt { get; init; }

    /// <summary>Notify when the value changes by at least this step.</summary>
    public AttributeValue<decimal> St { get; init; }

    /// <summary>The minimum evaluation period in seconds (LwM2M 1.1 and later).</summary>
    public AttributeValue<long> Epmin { get; init; }

    /// <summary>The maximum evaluation period in seconds (LwM2M 1.1 and later).</summary>
    public AttributeValue<long> Epmax { get; init; }

    /// <summary>The number of instances of a multiple Resource, reported by the client.</summary>
    public long? Dim { get; init; }

    /// <summary>The Short Server ID, reported by the client.</summary>
    public long? Ssid { get; init; }

    /// <summary>The Server URI, reported by the client.</summary>
    public string? Uri { get; init; }

    /// <summary>The Object version, reported by the client.</summary>
    public string? Ver { get; init; }

    /// <summary>True when no attribute is present in any state.</summary>
    public bool IsEmpty => this == new NotificationAttributes();

    /// <summary>
    /// The Write-Attributes Uri-Query parameters. A cleared attribute becomes a bare name; absent ones are omitted.
    /// </summary>
    /// <returns>The parameters, in the order <c>pmin</c>, <c>pmax</c>, <c>epmin</c>, <c>epmax</c>, <c>gt</c>, <c>lt</c>, <c>st</c>.</returns>
    public IReadOnlyList<QueryParameter> ToQuery()
    {
        var query = new List<QueryParameter>();
        Add(query, "pmin", Pmin);
        Add(query, "pmax", Pmax);
        Add(query, "epmin", Epmin);
        Add(query, "epmax", Epmax);
        Add(query, "gt", Gt);
        Add(query, "lt", Lt);
        Add(query, "st", St);
        return query;
    }

    /// <summary>
    /// Parses Write-Attributes Uri-Query parameters. Parameters that are not notification
    /// attributes are ignored, since a Write-Attributes URI may carry others.
    /// </summary>
    /// <param name="query">The parameters.</param>
    /// <returns>The attributes.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.InvalidAttribute"/> when a value is malformed or an attribute repeats.</exception>
    public static NotificationAttributes FromQuery(IEnumerable<QueryParameter> query)
    {
        ArgumentNullException.ThrowIfNull(query);
        var result = new NotificationAttributes();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var parameter in query)
        {
            if (!IsNotificationName(parameter.Key))
            {
                continue;
            }

            if (!seen.Add(parameter.Key))
            {
                throw Invalid($"attribute {parameter.Key} appears more than once");
            }

            result = result.WithParameter(parameter.Key, parameter.Value);
        }

        return result;
    }

    /// <summary>
    /// Parses the parameters on a Discover link: the attributes in force at that level, plus the
    /// property attributes. Parameters that are not attributes (<c>rt</c>, <c>ct</c> and so on) are ignored.
    /// </summary>
    /// <param name="parameters">The link parameters.</param>
    /// <returns>The attributes.</returns>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.InvalidAttribute"/> when a value is malformed.</exception>
    public static NotificationAttributes FromLinkParams(IEnumerable<LinkParam> parameters)
    {
        ArgumentNullException.ThrowIfNull(parameters);
        var result = new NotificationAttributes();
        foreach (var parameter in parameters)
        {
            result = parameter.Name switch
            {
                "dim" => result with { Dim = ParseLong("dim", parameter.Value) },
                "ssid" => result with { Ssid = ParseLong("ssid", parameter.Value) },
                "uri" => result with { Uri = parameter.Value },
                "ver" => result with { Ver = parameter.Value },
                var name when IsNotificationName(name) => result.WithParameter(name, parameter.Value),
                _ => result,
            };
        }

        return result;
    }

    /// <summary>The attributes as Discover link parameters. Cleared attributes have no meaning there and are omitted.</summary>
    /// <returns>The parameters, property attributes first.</returns>
    public IReadOnlyList<LinkParam> ToLinkParams()
    {
        var parameters = new List<LinkParam>();
        if (Dim is { } dim)
        {
            parameters.Add(LinkParam.Of("dim", dim.ToString(CultureInfo.InvariantCulture)));
        }

        if (Ssid is { } ssid)
        {
            parameters.Add(LinkParam.Of("ssid", ssid.ToString(CultureInfo.InvariantCulture)));
        }

        if (Uri is { } uri)
        {
            parameters.Add(LinkParam.Of("uri", uri));
        }

        if (Ver is { } ver)
        {
            parameters.Add(LinkParam.Of("ver", ver));
        }

        parameters.AddRange(ToQuery().Where(q => q.Value is not null).Select(q => LinkParam.Of(q.Key, q.Value)));
        return parameters;
    }

    /// <summary>
    /// Folds <paramref name="incoming"/> onto these attributes, as a client does on receiving
    /// Write-Attributes: absent leaves a value alone, cleared removes it, set replaces it.
    /// </summary>
    /// <param name="incoming">The attributes written.</param>
    /// <returns>The merged attributes.</returns>
    public NotificationAttributes Merge(NotificationAttributes incoming)
    {
        ArgumentNullException.ThrowIfNull(incoming);
        return this with
        {
            Pmin = Fold(Pmin, incoming.Pmin),
            Pmax = Fold(Pmax, incoming.Pmax),
            Gt = Fold(Gt, incoming.Gt),
            Lt = Fold(Lt, incoming.Lt),
            St = Fold(St, incoming.St),
            Epmin = Fold(Epmin, incoming.Epmin),
            Epmax = Fold(Epmax, incoming.Epmax),
        };
    }

    /// <summary>
    /// Checks the rules of OMA LwM2M 1.2 §5.1.2: <c>pmin</c> no greater than <c>pmax</c>, <c>epmin</c>
    /// no greater than <c>epmax</c>, <c>lt</c> below <c>gt</c>, <c>lt + 2 × st</c> below <c>gt</c>, and no
    /// negative period or step.
    /// </summary>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.InvalidAttribute"/> naming the broken rule.</exception>
    public void Validate()
    {
        foreach (var (name, value) in new[] { ("pmin", Pmin.Value), ("pmax", Pmax.Value), ("epmin", Epmin.Value), ("epmax", Epmax.Value) })
        {
            if (value < 0)
            {
                throw Invalid($"{name} cannot be negative");
            }
        }

        if (St.Value < 0)
        {
            throw Invalid("st cannot be negative");
        }

        if (Pmin.Value is { } pmin && Pmax.Value is { } pmax && pmin > pmax)
        {
            throw Invalid("pmin must not be greater than pmax");
        }

        if (Epmin.Value is { } epmin && Epmax.Value is { } epmax && epmin > epmax)
        {
            throw Invalid("epmin must not be greater than epmax");
        }

        if (Lt.Value is { } lt && Gt.Value is { } gt)
        {
            if (lt >= gt)
            {
                throw Invalid("lt must be less than gt");
            }

            if (St.Value is { } st && lt + (2 * st) >= gt)
            {
                throw Invalid("lt + 2 * st must be less than gt");
            }
        }
    }

    /// <summary>
    /// Checks <see cref="Validate()"/> and that every attribute may be attached at <paramref name="path"/>:
    /// <c>gt</c>, <c>lt</c> and <c>st</c> apply to Resources and Resource Instances only.
    /// </summary>
    /// <param name="path">The target path.</param>
    /// <exception cref="Lwm2mException"><see cref="Lwm2mErrorCode.InvalidAttribute"/> naming the broken rule.</exception>
    public void Validate(Lwm2mPath path)
    {
        ArgumentNullException.ThrowIfNull(path);
        if (path.ResourceId is null && (Gt.State != AttributeState.Absent || Lt.State != AttributeState.Absent || St.State != AttributeState.Absent))
        {
            throw Invalid($"gt, lt and st apply to Resources only, not {path}");
        }

        Validate();
    }

    private NotificationAttributes WithParameter(string name, string? raw) => name switch
    {
        "pmin" => this with { Pmin = Period(name, raw) },
        "pmax" => this with { Pmax = Period(name, raw) },
        "epmin" => this with { Epmin = Period(name, raw) },
        "epmax" => this with { Epmax = Period(name, raw) },
        "gt" => this with { Gt = Threshold(name, raw) },
        "lt" => this with { Lt = Threshold(name, raw) },
        _ => this with { St = Threshold(name, raw) },
    };

    private static bool IsNotificationName(string name) => name is "pmin" or "pmax" or "epmin" or "epmax" or "gt" or "lt" or "st";

    private static AttributeValue<long> Period(string name, string? raw) =>
        raw is null ? AttributeValue<long>.Cleared : ParseLong(name, raw);

    private static long ParseLong(string name, string? raw) =>
        raw is not null && raw.Length > 0 && raw.All(char.IsAsciiDigit) &&
        long.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var value)
            ? value
            : throw Invalid($"attribute {name} expects a non-negative integer, got \"{raw}\"");

    private static AttributeValue<decimal> Threshold(string name, string? raw)
    {
        if (raw is null)
        {
            return AttributeValue<decimal>.Cleared;
        }

        bool shaped = raw.Length > 0 && raw.TrimStart('-').Length > 0 && raw.Count(c => c == '-') <= 1 &&
                      raw.IndexOf('-') <= 0 && raw.All(c => char.IsAsciiDigit(c) || c is '.' or '-');
        return shaped && decimal.TryParse(raw, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var value)
            ? value
            : throw Invalid($"attribute {name} expects a decimal number, got \"{raw}\"");
    }

    private static void Add(List<QueryParameter> query, string name, AttributeValue<long> value)
    {
        if (value.State != AttributeState.Absent)
        {
            query.Add(new QueryParameter(name, value.Value?.ToString(CultureInfo.InvariantCulture)));
        }
    }

    private static void Add(List<QueryParameter> query, string name, AttributeValue<decimal> value)
    {
        if (value.State != AttributeState.Absent)
        {
            query.Add(new QueryParameter(name, value.Value is { } d ? FormatDecimal(d) : null));
        }
    }

    // Plain notation with no trailing zeros, which is how Leshan writes thresholds.
    private static string FormatDecimal(decimal value) => value.ToString("0.############################", CultureInfo.InvariantCulture);

    private static AttributeValue<T> Fold<T>(AttributeValue<T> current, AttributeValue<T> incoming)
        where T : struct => incoming.State switch
        {
            AttributeState.Absent => current,
            AttributeState.Cleared => AttributeValue<T>.Absent,
            _ => incoming,
        };

    private static Lwm2mException Invalid(string message) => new(Lwm2mErrorCode.InvalidAttribute, message);
}

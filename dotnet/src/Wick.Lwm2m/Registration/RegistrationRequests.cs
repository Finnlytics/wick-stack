using System.Collections.Immutable;
using System.Globalization;
using Wick.Lwm2m.Codecs;
using Wick.Lwm2m.Links;
using Wick.Lwm2m.Wire;

namespace Wick.Lwm2m.Registration;

/// <summary>The LwM2M Enabler versions a client can declare with the <c>lwm2m</c> parameter.</summary>
public static class Lwm2mVersions
{
    /// <summary>LwM2M 1.0. A Register with no <c>lwm2m</c> parameter is taken to be 1.0, as Eclipse Leshan does.</summary>
    public const string V1_0 = "1.0";

    /// <summary>LwM2M 1.1.</summary>
    public const string V1_1 = "1.1";

    /// <summary>LwM2M 1.2.</summary>
    public const string V1_2 = "1.2";

    /// <summary>The versions Wick accepts, oldest first.</summary>
    public static IReadOnlyList<string> Supported { get; } = [V1_0, V1_1, V1_2];

    /// <summary>True when <paramref name="version"/> is 1.0.</summary>
    /// <param name="version">The version.</param>
    /// <returns>Whether it is 1.0.</returns>
    public static bool IsV1_0(string version) => version == V1_0;
}

/// <summary>
/// A failure to parse or accept a registration request, carrying the response code the server should answer with.
/// </summary>
public sealed class RegistrationRequestException : Exception
{
    /// <summary>Creates the exception.</summary>
    /// <param name="code">The response code to answer with.</param>
    /// <param name="message">The diagnostic.</param>
    public RegistrationRequestException(ResponseCode code, string message)
        : base(message)
    {
        Code = code;
    }

    /// <summary>Creates the exception with a cause.</summary>
    /// <param name="code">The response code to answer with.</param>
    /// <param name="message">The diagnostic.</param>
    /// <param name="innerException">The cause.</param>
    public RegistrationRequestException(ResponseCode code, string message, Exception innerException)
        : base(message, innerException)
    {
        Code = code;
    }

    /// <summary>The response code to answer with: 4.00 Bad Request or 4.12 Precondition Failed.</summary>
    public ResponseCode Code { get; }
}

/// <summary>
/// Register (OMA LwM2M 1.2 §6.2.1): <c>POST /rd?ep=...&amp;lt=...&amp;lwm2m=...&amp;b=...</c> with the
/// client's Objects as a link-format payload.
/// </summary>
public sealed record RegisterRequest
{
    private readonly ImmutableArray<Link> _objects;
    private readonly ImmutableArray<QueryParameter> _additional;

    /// <summary>Creates a Register.</summary>
    /// <param name="endpointName">The endpoint client name (<c>ep</c>).</param>
    /// <param name="objects">The Objects and Object Instances the client supports, as links. At least one.</param>
    public RegisterRequest(string endpointName, IEnumerable<Link> objects)
    {
        ArgumentException.ThrowIfNullOrEmpty(endpointName);
        ArgumentNullException.ThrowIfNull(objects);
        EndpointName = endpointName;
        _objects = objects.ToImmutableArray();
        _additional = [];
    }

    /// <summary>The endpoint client name (<c>ep</c>).</summary>
    public string EndpointName { get; }

    /// <summary>The requested lifetime in seconds (<c>lt</c>), or <see langword="null"/> for the server default.</summary>
    public long? Lifetime { get; init; }

    /// <summary>The declared LwM2M version (<c>lwm2m</c>), or <see langword="null"/>, which means 1.0.</summary>
    public string? Lwm2mVersion { get; init; }

    /// <summary>The binding mode (<c>b</c>), such as <c>U</c>, or <see langword="null"/>.</summary>
    public string? Binding { get; init; }

    /// <summary>Whether the client is in queue mode (the <c>Q</c> flag, LwM2M 1.1 and later).</summary>
    public bool QueueMode { get; init; }

    /// <summary>The MSISDN (<c>sms</c>), or <see langword="null"/>.</summary>
    public string? SmsNumber { get; init; }

    /// <summary>The Objects and Object Instances, as links.</summary>
    public IReadOnlyList<Link> Objects => _objects;

    /// <summary>Query parameters other than the ones above, in order.</summary>
    public IReadOnlyList<QueryParameter> AdditionalParameters
    {
        get => _additional;
        init => _additional = value?.ToImmutableArray() ?? throw new ArgumentNullException(nameof(value));
    }

    /// <summary>The version in force: the declared one, or 1.0 when none was declared.</summary>
    public string EffectiveVersion => Lwm2mVersion ?? Lwm2mVersions.V1_0;

    /// <summary>The transport-neutral form, as a client would send it.</summary>
    /// <returns>The wire request.</returns>
    public WireRequest ToWire()
    {
        var query = new List<QueryParameter> { new("ep", EndpointName) };
        if (Lifetime is { } lt)
        {
            query.Add(new QueryParameter("lt", lt.ToString(CultureInfo.InvariantCulture)));
        }

        if (Lwm2mVersion is { } version)
        {
            query.Add(new QueryParameter("lwm2m", version));
        }

        if (Binding is { } binding)
        {
            query.Add(new QueryParameter("b", binding));
        }

        if (QueueMode)
        {
            query.Add(new QueryParameter("Q", null));
        }

        if (SmsNumber is { } sms)
        {
            query.Add(new QueryParameter("sms", sms));
        }

        query.AddRange(_additional);
        return new WireRequest(Method.Post)
        {
            Path = ["rd"],
            Query = query,
            ContentFormat = ContentFormats.LinkFormat,
            Payload = CoreLinkFormat.Encode(_objects),
        };
    }

    /// <summary>
    /// Parses and validates a Register, following OMA LwM2M 1.2 §6.2.1 and the checks Eclipse Leshan applies.
    /// </summary>
    /// <param name="request">The wire request, a POST to <c>/rd</c>.</param>
    /// <returns>The Register.</returns>
    /// <exception cref="RegistrationRequestException">
    /// 4.00 for a missing or empty <c>ep</c>, a malformed <c>lt</c>, a <c>Q</c> with a value, queue mode
    /// declared by a 1.0 client, an invalid binding, or a missing or malformed link-format payload;
    /// 4.12 for an LwM2M version Wick does not support.
    /// </exception>
    public static RegisterRequest Parse(WireRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.Method != Method.Post || request.Path is not ["rd"])
        {
            throw BadRequest($"a Register is a POST to /rd, not {request.Method} /{string.Join('/', request.Path)}");
        }

        string? endpoint = null;
        long? lifetime = null;
        string? version = null;
        string? binding = null;
        string? sms = null;
        bool queue = false;
        var additional = new List<QueryParameter>();
        foreach (var parameter in request.Query)
        {
            switch (parameter.Key)
            {
                case "ep":
                    endpoint = parameter.Value;
                    break;
                case "lt":
                    lifetime = RegistrationParsing.Lifetime(parameter.Value);
                    break;
                case "lwm2m":
                    version = parameter.Value ?? throw BadRequest("lwm2m needs a value");
                    break;
                case "b":
                    binding = parameter.Value ?? string.Empty;
                    break;
                case "sms":
                    sms = parameter.Value ?? string.Empty;
                    break;
                case "Q":
                    queue = parameter.Value is null ? true : throw BadRequest("the queue mode flag Q takes no value");
                    break;
                default:
                    additional.Add(parameter);
                    break;
            }
        }

        if (string.IsNullOrEmpty(endpoint))
        {
            throw BadRequest("the endpoint client name (ep) is missing");
        }

        var effective = version ?? Lwm2mVersions.V1_0;
        RegistrationParsing.CheckVersion(effective);
        if (queue && Lwm2mVersions.IsV1_0(effective))
        {
            throw BadRequest("queue mode (Q) is not defined in LwM2M 1.0");
        }

        if (binding is not null)
        {
            RegistrationParsing.CheckBinding(binding, effective);
        }

        var objects = RegistrationParsing.Objects(request, required: true)!;
        return new RegisterRequest(endpoint, objects)
        {
            Lifetime = lifetime,
            Lwm2mVersion = version,
            Binding = binding,
            QueueMode = queue,
            SmsNumber = sms,
            AdditionalParameters = additional,
        };
    }

    /// <inheritdoc/>
    public bool Equals(RegisterRequest? other) =>
        other is not null && EndpointName == other.EndpointName && Lifetime == other.Lifetime && Lwm2mVersion == other.Lwm2mVersion &&
        Binding == other.Binding && QueueMode == other.QueueMode && SmsNumber == other.SmsNumber &&
        _objects.SequenceEqual(other._objects) && _additional.SequenceEqual(other._additional);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(EndpointName, Lifetime, Lwm2mVersion, Binding, QueueMode, _objects.Length);

    private static RegistrationRequestException BadRequest(string message) => new(ResponseCode.BadRequest, message);
}

/// <summary>
/// Update (OMA LwM2M 1.2 §6.2.2): <c>POST /rd/{id}</c>, optionally changing the lifetime, binding,
/// SMS number or Object list. With no parameters it simply refreshes the registration.
/// </summary>
public sealed record UpdateRequest
{
    private readonly ImmutableArray<Link>? _objects;
    private readonly ImmutableArray<QueryParameter> _additional = [];

    /// <summary>Creates an Update.</summary>
    /// <param name="registrationId">The registration ID from the Register response's Location-Path.</param>
    public UpdateRequest(string registrationId)
    {
        ArgumentException.ThrowIfNullOrEmpty(registrationId);
        RegistrationId = registrationId;
    }

    /// <summary>The registration ID.</summary>
    public string RegistrationId { get; }

    /// <summary>The new lifetime in seconds, or <see langword="null"/> to keep the current one.</summary>
    public long? Lifetime { get; init; }

    /// <summary>The new binding mode, or <see langword="null"/> to keep the current one.</summary>
    public string? Binding { get; init; }

    /// <summary>The new MSISDN, or <see langword="null"/> to keep the current one.</summary>
    public string? SmsNumber { get; init; }

    /// <summary>The new Object list, or <see langword="null"/> when the Update carried no payload.</summary>
    public IReadOnlyList<Link>? Objects
    {
        get => _objects;
        init => _objects = value?.ToImmutableArray();
    }

    /// <summary>Query parameters other than the ones above, in order.</summary>
    public IReadOnlyList<QueryParameter> AdditionalParameters
    {
        get => _additional;
        init => _additional = value?.ToImmutableArray() ?? throw new ArgumentNullException(nameof(value));
    }

    /// <summary>The transport-neutral form, as a client would send it.</summary>
    /// <returns>The wire request.</returns>
    public WireRequest ToWire()
    {
        var query = new List<QueryParameter>();
        if (Lifetime is { } lt)
        {
            query.Add(new QueryParameter("lt", lt.ToString(CultureInfo.InvariantCulture)));
        }

        if (Binding is { } binding)
        {
            query.Add(new QueryParameter("b", binding));
        }

        if (SmsNumber is { } sms)
        {
            query.Add(new QueryParameter("sms", sms));
        }

        query.AddRange(_additional);
        return _objects is { } objects
            ? new WireRequest(Method.Post) { Path = ["rd", RegistrationId], Query = query, ContentFormat = ContentFormats.LinkFormat, Payload = CoreLinkFormat.Encode(objects) }
            : new WireRequest(Method.Post) { Path = ["rd", RegistrationId], Query = query };
    }

    /// <summary>Parses an Update. Binding validity against the client's version is checked when the update is applied.</summary>
    /// <param name="request">The wire request, a POST to <c>/rd/{id}</c>.</param>
    /// <returns>The Update.</returns>
    /// <exception cref="RegistrationRequestException">4.00 for a malformed <c>lt</c> or a malformed link-format payload.</exception>
    public static UpdateRequest Parse(WireRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.Method != Method.Post || request.Path is not ["rd", { Length: > 0 } id])
        {
            throw new RegistrationRequestException(ResponseCode.BadRequest, $"an Update is a POST to /rd/{{id}}, not {request.Method} /{string.Join('/', request.Path)}");
        }

        long? lifetime = null;
        string? binding = null;
        string? sms = null;
        var additional = new List<QueryParameter>();
        foreach (var parameter in request.Query)
        {
            switch (parameter.Key)
            {
                case "lt":
                    lifetime = RegistrationParsing.Lifetime(parameter.Value);
                    break;
                case "b":
                    binding = parameter.Value ?? string.Empty;
                    break;
                case "sms":
                    sms = parameter.Value ?? string.Empty;
                    break;
                default:
                    additional.Add(parameter);
                    break;
            }
        }

        return new UpdateRequest(id)
        {
            Lifetime = lifetime,
            Binding = binding,
            SmsNumber = sms,
            Objects = RegistrationParsing.Objects(request, required: false),
            AdditionalParameters = additional,
        };
    }

    /// <inheritdoc/>
    public bool Equals(UpdateRequest? other) =>
        other is not null && RegistrationId == other.RegistrationId && Lifetime == other.Lifetime && Binding == other.Binding &&
        SmsNumber == other.SmsNumber && _additional.SequenceEqual(other._additional) &&
        (_objects is null ? other._objects is null : other._objects is not null && _objects.Value.SequenceEqual(other._objects.Value));

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(RegistrationId, Lifetime, Binding, SmsNumber);
}

/// <summary>Deregister (OMA LwM2M 1.2 §6.2.3): <c>DELETE /rd/{id}</c>.</summary>
/// <param name="RegistrationId">The registration ID.</param>
public sealed record DeregisterRequest(string RegistrationId)
{
    /// <summary>The transport-neutral form, as a client would send it.</summary>
    /// <returns>The wire request.</returns>
    public WireRequest ToWire() => new(Method.Delete) { Path = ["rd", RegistrationId] };

    /// <summary>Parses a Deregister.</summary>
    /// <param name="request">The wire request, a DELETE to <c>/rd/{id}</c>.</param>
    /// <returns>The Deregister.</returns>
    /// <exception cref="RegistrationRequestException">4.00 when the request is not a DELETE to <c>/rd/{id}</c>.</exception>
    public static DeregisterRequest Parse(WireRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return request.Method == Method.Delete && request.Path is ["rd", { Length: > 0 } id]
            ? new DeregisterRequest(id)
            : throw new RegistrationRequestException(ResponseCode.BadRequest, $"a Deregister is a DELETE to /rd/{{id}}, not {request.Method} /{string.Join('/', request.Path)}");
    }
}

internal static class RegistrationParsing
{
    public static long Lifetime(string? raw) =>
        raw is not null && raw.Length is > 0 and <= 18 && raw.All(char.IsAsciiDigit) &&
        long.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value > 0
            ? value
            : throw new RegistrationRequestException(ResponseCode.BadRequest, $"invalid lifetime (lt): \"{raw}\"");

    public static void CheckVersion(string version)
    {
        if (Lwm2mVersions.Supported.Contains(version))
        {
            return;
        }

        var parts = version.Split('.');
        bool wellFormed = parts.Length == 2 && parts.All(p => p.Length > 0 && p.All(char.IsAsciiDigit));
        throw wellFormed
            ? new RegistrationRequestException(ResponseCode.PreconditionFailed, $"LwM2M version {version} is not supported")
            : new RegistrationRequestException(ResponseCode.BadRequest, $"invalid LwM2M version \"{version}\"");
    }

    // U, S and (1.0 only) Q; T and N from 1.1 (OMA LwM2M 1.2 §6.2.1.1).
    public static void CheckBinding(string binding, string version)
    {
        if (binding.Length == 0)
        {
            throw new RegistrationRequestException(ResponseCode.BadRequest, "the binding (b) is empty");
        }

        bool v10 = Lwm2mVersions.IsV1_0(version);
        foreach (var mode in binding)
        {
            string? error = mode switch
            {
                'U' or 'S' => null,
                'T' or 'N' when v10 => $"binding {mode} is supported from LwM2M 1.1",
                'T' or 'N' => null,
                'Q' when !v10 => "binding Q is not supported from LwM2M 1.1; use the Q parameter",
                'Q' => null,
                _ => $"unknown binding mode '{mode}'",
            };

            if (error is not null)
            {
                throw new RegistrationRequestException(ResponseCode.BadRequest, error);
            }
        }

        if (binding.Distinct().Count() != binding.Length)
        {
            throw new RegistrationRequestException(ResponseCode.BadRequest, $"binding \"{binding}\" repeats a mode");
        }
    }

    public static IReadOnlyList<Link>? Objects(WireRequest request, bool required)
    {
        if (request.Payload.IsEmpty)
        {
            return required
                ? throw new RegistrationRequestException(ResponseCode.BadRequest, "the Object list (link-format payload) is missing")
                : null;
        }

        if (request.ContentFormat is { } cf && cf != ContentFormats.LinkFormat)
        {
            throw new RegistrationRequestException(ResponseCode.BadRequest, $"the Object list must be link-format (40), not {cf}");
        }

        try
        {
            var links = CoreLinkFormat.Decode(request.Payload.Span);
            return links.Count == 0 && required
                ? throw new RegistrationRequestException(ResponseCode.BadRequest, "the Object list is empty")
                : links;
        }
        catch (Lwm2mException e)
        {
            throw new RegistrationRequestException(ResponseCode.BadRequest, $"malformed Object list: {e.Message}", e);
        }
    }
}

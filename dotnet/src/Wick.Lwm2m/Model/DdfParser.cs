using System.Globalization;
using System.Xml;
using System.Xml.Linq;

namespace Wick.Lwm2m.Model;

/// <summary>
/// Parses OMA LwM2M DDF (Object definition) XML into an <see cref="ObjectModel"/>.
/// </summary>
/// <remarks>
/// <para>
/// The format is defined by the OMA <c>LWM2M.xsd</c> schema and published in the OMNA LwM2M
/// Registry. The parser reads the first <c>Object</c> element under the <c>LWM2M</c> root and
/// ignores elements it does not use. Element names are matched without regard to XML namespace.
/// </para>
/// <para>DTD processing is disabled and no external entities are resolved, so an untrusted file cannot reach the network or file system.</para>
/// </remarks>
public static class DdfParser
{
    /// <summary>Parses DDF XML text.</summary>
    /// <param name="xml">The XML document.</param>
    /// <returns>The Object definition.</returns>
    /// <exception cref="Lwm2mException">
    /// <see cref="Lwm2mErrorCode.MalformedXml"/> when the text is not XML, or
    /// <see cref="Lwm2mErrorCode.InvalidDdf"/> when it is XML but not a valid DDF document.
    /// </exception>
    public static ObjectModel Parse(string xml)
    {
        ArgumentNullException.ThrowIfNull(xml);
        using var reader = new StringReader(xml);
        return Parse(XmlReader.Create(reader, Settings()));
    }

    /// <summary>Parses DDF XML from a stream, honouring the document's declared encoding.</summary>
    /// <param name="xml">The stream.</param>
    /// <returns>The Object definition.</returns>
    /// <exception cref="Lwm2mException">The stream does not hold a valid DDF document.</exception>
    public static ObjectModel Parse(Stream xml)
    {
        ArgumentNullException.ThrowIfNull(xml);
        return Parse(XmlReader.Create(xml, Settings()));
    }

    private static XmlReaderSettings Settings() => new()
    {
        DtdProcessing = DtdProcessing.Ignore,
        XmlResolver = null,
        IgnoreComments = true,
        CloseInput = false,
    };

    private static ObjectModel Parse(XmlReader reader)
    {
        XDocument document;
        try
        {
            using (reader)
            {
                document = XDocument.Load(reader);
            }
        }
        catch (XmlException e)
        {
            throw new Lwm2mException(Lwm2mErrorCode.MalformedXml, $"could not parse DDF XML: {e.Message}", e);
        }

        var root = document.Root ?? throw Invalid("the document has no root element");
        var obj = Child(root, "Object") ?? throw Invalid("missing <Object> element");
        var resourcesElement = Child(obj, "Resources") ?? throw Invalid("missing <Resources> element");

        var resources = Children(resourcesElement, "Item").Select(ParseResource).OrderBy(r => r.Id).ToList();
        var duplicate = resources.GroupBy(r => r.Id).FirstOrDefault(g => g.Count() > 1);
        if (duplicate is not null)
        {
            throw Invalid($"duplicate Resource ID {duplicate.Key}");
        }

        return new ObjectModel(
            RequiredInt(obj, "ObjectID"),
            RequiredText(obj, "Name"),
            Multiplicity(obj),
            Requirement(obj),
            resources)
        {
            Description = OptionalText(obj, "Description1"),
            Urn = OptionalText(obj, "ObjectURN"),
            Lwm2mVersion = OptionalText(obj, "LWM2MVersion"),
            ObjectVersion = OptionalText(obj, "ObjectVersion"),
        };
    }

    private static ResourceModel ParseResource(XElement item)
    {
        var idText = item.Attribute("ID")?.Value.Trim() ?? throw Invalid("an <Item> is missing its ID attribute");
        if (!int.TryParse(idText, NumberStyles.None, CultureInfo.InvariantCulture, out var id) || id > Lwm2mPath.MaxId)
        {
            throw Invalid($"invalid Resource ID \"{idText}\"");
        }

        return new ResourceModel(
            id,
            RequiredText(item, "Name"),
            ParseOperations(OptionalText(item, "Operations")),
            Multiplicity(item),
            Requirement(item),
            ParseType(OptionalText(item, "Type")))
        {
            RangeEnumeration = BlankToNull(OptionalText(item, "RangeEnumeration")),
            Units = BlankToNull(OptionalText(item, "Units")),
            Description = BlankToNull(OptionalText(item, "Description")),
        };
    }

    /// <summary>Maps a DDF <c>Type</c> element value to a <see cref="Lwm2mType"/>.</summary>
    /// <param name="text">The element text, such as <c>Unsigned Integer</c>. Empty or absent means <see cref="Lwm2mType.None"/>.</param>
    /// <returns>The type.</returns>
    /// <exception cref="Lwm2mException">The text is not a DDF type name.</exception>
    public static Lwm2mType ParseType(string? text) => text switch
    {
        null or "" => Lwm2mType.None,
        "String" => Lwm2mType.String,
        "Integer" => Lwm2mType.Integer,
        "Unsigned Integer" => Lwm2mType.UnsignedInteger,
        "Float" => Lwm2mType.Float,
        "Boolean" => Lwm2mType.Boolean,
        "Opaque" => Lwm2mType.Opaque,
        "Time" => Lwm2mType.Time,
        "Objlnk" => Lwm2mType.ObjectLink,
        "Corelnk" => Lwm2mType.CoreLink,
        _ => throw Invalid($"unknown DDF Type \"{text}\""),
    };

    private static ResourceOperations ParseOperations(string? text)
    {
        var operations = ResourceOperations.None;
        foreach (var letter in (text ?? string.Empty).ToUpperInvariant())
        {
            operations |= letter switch
            {
                'R' => ResourceOperations.Read,
                'W' => ResourceOperations.Write,
                'E' => ResourceOperations.Execute,
                _ => throw Invalid($"unknown Operations letter '{letter}'"),
            };
        }

        return operations;
    }

    private static bool Multiplicity(XElement element) => RequiredText(element, "MultipleInstances") switch
    {
        "Single" => false,
        "Multiple" => true,
        var other => throw Invalid($"unknown MultipleInstances \"{other}\""),
    };

    private static bool Requirement(XElement element) => RequiredText(element, "Mandatory") switch
    {
        "Mandatory" => true,
        "Optional" => false,
        var other => throw Invalid($"unknown Mandatory \"{other}\""),
    };

    private static int RequiredInt(XElement element, string name)
    {
        var text = RequiredText(element, name);
        return int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value <= Lwm2mPath.MaxId
            ? value
            : throw Invalid($"invalid integer in <{name}>: \"{text}\"");
    }

    private static string RequiredText(XElement element, string name) =>
        OptionalText(element, name) ?? throw Invalid($"missing required <{name}> element");

    private static string? OptionalText(XElement element, string name) => Child(element, name)?.Value.Trim();

    private static XElement? Child(XElement element, string name) => Children(element, name).FirstOrDefault();

    private static IEnumerable<XElement> Children(XElement element, string name) =>
        element.Elements().Where(e => e.Name.LocalName == name);

    private static string? BlankToNull(string? text) => string.IsNullOrEmpty(text) ? null : text;

    private static Lwm2mException Invalid(string message) => new(Lwm2mErrorCode.InvalidDdf, message);
}

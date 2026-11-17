using Wick.Lwm2m.Model;

namespace Wick.Lwm2m.Tests.Model;

public sealed class DdfParserTests
{
    private static string Ddf(string name)
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "wick", "priv", "ddf")))
        {
            directory = directory.Parent;
        }

        return File.ReadAllText(Path.Combine(directory!.FullName, "wick", "priv", "ddf", name));
    }

    [Fact]
    public void Parses_location_metadata_and_resources()
    {
        var location = DdfParser.Parse(Ddf("6.xml"));

        Assert.Equal(6, location.Id);
        Assert.Equal("Location", location.Name);
        Assert.Equal("urn:oma:lwm2m:oma:6", location.Urn);
        Assert.Equal("1.0", location.Lwm2mVersion);
        Assert.Equal("1.0", location.ObjectVersion);
        Assert.False(location.Multiple);
        Assert.False(location.Mandatory);
        Assert.Contains("location telemetry", location.Description, StringComparison.Ordinal);
        Assert.Equal([0, 1, 2, 3, 4, 5, 6], location.Resources.Select(r => r.Id));
        Assert.Equal(
            [Lwm2mType.Float, Lwm2mType.Float, Lwm2mType.Float, Lwm2mType.Float, Lwm2mType.Opaque, Lwm2mType.Time, Lwm2mType.Float],
            location.Resources.Select(r => r.Type));

        var latitude = location.GetResource(0)!;
        Assert.Equal("Latitude", latitude.Name);
        Assert.Equal(ResourceOperations.Read, latitude.Operations);
        Assert.True(latitude.Mandatory);
        Assert.False(latitude.Multiple);
        Assert.Equal("lat", latitude.Units);
        Assert.Null(latitude.RangeEnumeration);
    }

    [Fact]
    public void Parses_device_operations_and_executables()
    {
        var device = DdfParser.Parse(Ddf("3.xml"));

        Assert.True(device.Mandatory);
        var reboot = device.GetResource(4)!;
        Assert.Equal("Reboot", reboot.Name);
        Assert.Equal(ResourceOperations.Execute, reboot.Operations);
        Assert.Equal(Lwm2mType.None, reboot.Type);
        Assert.True(reboot.IsExecutable);
        Assert.True(device.GetResource(6)!.Multiple);
        Assert.Equal(Lwm2mType.Time, device.GetResource(13)!.Type);
        Assert.Null(device.GetResource(999));
    }

    [Fact]
    public void Rejects_text_that_is_not_xml()
    {
        Assert.Equal(Lwm2mErrorCode.MalformedXml, Assert.Throws<Lwm2mException>(() => DdfParser.Parse("<LWM2M><Object>")).Code);
    }

    [Theory]
    [InlineData("<LWM2M/>", "missing <Object>")]
    [InlineData("<LWM2M><Object><Name>X</Name></Object></LWM2M>", "missing <Resources>")]
    [InlineData("<LWM2M><Object><Name>X</Name><ObjectID>9</ObjectID><MultipleInstances>Sometimes</MultipleInstances><Mandatory>Optional</Mandatory><Resources/></Object></LWM2M>", "MultipleInstances")]
    [InlineData("<LWM2M><Object><Name>X</Name><ObjectID>x</ObjectID><MultipleInstances>Single</MultipleInstances><Mandatory>Optional</Mandatory><Resources/></Object></LWM2M>", "ObjectID")]
    public void Rejects_xml_that_is_not_a_ddf(string xml, string mention)
    {
        var e = Assert.Throws<Lwm2mException>(() => DdfParser.Parse(xml));

        Assert.Equal(Lwm2mErrorCode.InvalidDdf, e.Code);
        Assert.Contains(mention, e.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Parses_a_custom_object_at_run_time()
    {
        const string xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <LWM2M xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
              <Object ObjectType="MODefinition">
                <Name>Widget</Name>
                <ObjectID>33000</ObjectID>
                <ObjectVersion>1.1</ObjectVersion>
                <MultipleInstances>Multiple</MultipleInstances>
                <Mandatory>Optional</Mandatory>
                <Resources>
                  <Item ID="1"><Name>Count</Name><Operations>RW</Operations><MultipleInstances>Single</MultipleInstances><Mandatory>Mandatory</Mandatory><Type>Unsigned Integer</Type></Item>
                  <Item ID="0"><Name>Links</Name><Operations>R</Operations><MultipleInstances>Multiple</MultipleInstances><Mandatory>Optional</Mandatory><Type>Corelnk</Type></Item>
                </Resources>
              </Object>
            </LWM2M>
            """;

        var widget = DdfParser.Parse(xml);
        var registry = ObjectRegistry.Standard.With(widget);

        Assert.Equal([0, 1], widget.Resources.Select(r => r.Id));
        Assert.Equal(Lwm2mType.UnsignedInteger, registry.ResourceType(Lwm2mPath.Parse("/33000/0/1")));
        Assert.Equal(Lwm2mType.CoreLink, registry.ResourceType(Lwm2mPath.Parse("/33000/0/0/4")));
        Assert.Null(ObjectRegistry.Standard.GetObject(33000));
    }

    [Fact]
    public void Does_not_resolve_external_entities()
    {
        const string xml = """
            <?xml version="1.0"?>
            <!DOCTYPE LWM2M [<!ENTITY x SYSTEM "file:///etc/passwd">]>
            <LWM2M><Object><Name>&x;</Name><ObjectID>9</ObjectID><MultipleInstances>Single</MultipleInstances><Mandatory>Optional</Mandatory><Resources/></Object></LWM2M>
            """;

        var e = Record.Exception(() => DdfParser.Parse(xml));

        Assert.True(e is Lwm2mException, $"expected a Wick error, got {e}");
    }
}

public sealed class ObjectRegistryTests
{
    [Fact]
    public void Standard_holds_the_bundled_catalogue()
    {
        Assert.Equal([0, 1, 2, 3, 4, 5, 6, 7, 21, 3303], ObjectRegistry.Standard.ObjectIds);
        Assert.Equal("Device", ObjectRegistry.Standard.GetObject(3)!.Name);
        Assert.Equal("Temperature", ObjectRegistry.Standard.GetObject(3303)!.Name);
    }

    [Fact]
    public void Resolves_resource_types_by_path()
    {
        var registry = ObjectRegistry.Standard;

        Assert.Equal(Lwm2mType.Time, registry.ResourceType(Lwm2mPath.Parse("/3/0/13")));
        Assert.Equal(Lwm2mType.Integer, registry.ResourceType(Lwm2mPath.Parse("/3/0/6/1")));
        Assert.Equal(Lwm2mType.Float, registry.ResourceType(Lwm2mPath.Parse("/3303/0/5700")));
        Assert.Null(registry.ResourceType(Lwm2mPath.Parse("/3/0")));
        Assert.Null(registry.ResourceType(Lwm2mPath.Parse("/3/0/999")));
        Assert.Null(registry.ResourceType(Lwm2mPath.Parse("/9999/0/1")));
        Assert.Null(((ILwm2mModel?)null).ResourceType(Lwm2mPath.Parse("/3/0/13")));
    }

    [Fact]
    public void Is_immutable()
    {
        var model = new ObjectModel(9, "Nine", false, false, []);
        var empty = ObjectRegistry.Empty;
        var withNine = empty.With(model);

        Assert.Equal(0, empty.Count);
        Assert.Equal(1, withNine.Count);
        Assert.Equal(0, withNine.Without(9).Count);
        Assert.Same(model, withNine.GetObject(9));
    }

    [Fact]
    public void A_later_definition_replaces_an_earlier_one()
    {
        var first = new ObjectModel(9, "First", false, false, []);
        var second = new ObjectModel(9, "Second", false, false, []);

        Assert.Equal("Second", ObjectRegistry.From([first, second]).GetObject(9)!.Name);
    }
}

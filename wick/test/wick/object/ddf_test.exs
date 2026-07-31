defmodule Wick.Object.DdfTest do
  use ExUnit.Case, async: true

  alias Wick.Error
  alias Wick.Object.Ddf
  alias Wick.Object.Definition
  alias Wick.Object.Resource

  doctest Ddf

  @ddf_dir Path.expand("../../../priv/ddf", __DIR__)

  defp read_ddf(name), do: File.read!(Path.join(@ddf_dir, name))

  describe "parse/1 — Object 6 (Location)" do
    setup do
      {:ok, definition} = Ddf.parse(read_ddf("6.xml"))
      %{definition: definition}
    end

    test "parses Object metadata", %{definition: d} do
      assert d.object_id == 6
      assert d.name == "Location"
      assert d.urn == "urn:oma:lwm2m:oma:6"
      assert d.lwm2m_version == "1.0"
      assert d.object_version == "1.0"
      assert d.multiple_instances == :single
      assert d.mandatory == :optional
    end

    test "captures the description", %{definition: d} do
      assert d.description =~ "location telemetry"
    end

    test "parses all 7 Resources, ordered by ID", %{definition: d} do
      ids = Enum.map(d.resources, & &1.resource_id)
      assert ids == [0, 1, 2, 3, 4, 5, 6]

      names = Enum.map(d.resources, & &1.name)

      assert names == [
               "Latitude",
               "Longitude",
               "Altitude",
               "Radius",
               "Velocity",
               "Timestamp",
               "Speed"
             ]
    end

    test "parses Resource types correctly", %{definition: d} do
      types = Enum.map(d.resources, & &1.type)
      assert types == [:float, :float, :float, :float, :opaque, :time, :float]
    end

    test "parses Latitude (Resource 0) end-to-end", %{definition: d} do
      assert %Resource{
               resource_id: 0,
               name: "Latitude",
               type: :float,
               operations: [:read],
               multiple_instances: :single,
               mandatory: :mandatory,
               units: "lat",
               range_enumeration: nil
             } = Definition.find_resource(d, 0)
    end
  end

  describe "parse/1 — Object 3 (Device) — covers diverse types and operations" do
    setup do
      {:ok, definition} = Ddf.parse(read_ddf("3.xml"))
      %{definition: definition}
    end

    test "Object metadata", %{definition: d} do
      assert d.object_id == 3
      assert d.name == "Device"
      assert d.mandatory == :mandatory
    end

    test "the Resource set covers a variety of types", %{definition: d} do
      types = d.resources |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()
      # Device exposes string, integer, time, opaque, and execute (no type) resources
      assert :string in types
      assert :integer in types
      assert :time in types
      assert :none in types
    end

    test "the Resource set covers all operation kinds", %{definition: d} do
      ops = d.resources |> Enum.flat_map(& &1.operations) |> Enum.uniq() |> Enum.sort()
      assert ops == [:execute, :read, :write]
    end

    test "Reboot (Resource 4) is execute-only with no value type", %{definition: d} do
      reboot = Definition.find_resource(d, 4)
      assert reboot.name == "Reboot"
      assert reboot.operations == [:execute]
      assert reboot.type == :none
    end

    test "Available Power Sources (Resource 6) is multi-instance", %{definition: d} do
      r = Definition.find_resource(d, 6)
      assert r.multiple_instances == :multiple
    end
  end

  describe "parse/1 — Object 3303 (IPSO Temperature)" do
    setup do
      {:ok, definition} = Ddf.parse(read_ddf("3303.xml"))
      %{definition: definition}
    end

    test "Object metadata", %{definition: d} do
      assert d.object_id == 3303
      assert d.name == "Temperature"
    end

    test "Sensor Value (Resource 5700) is read-only float with units", %{definition: d} do
      sensor = Definition.find_resource(d, 5700)
      assert sensor.type == :float
      assert sensor.operations == [:read]
      assert sensor.mandatory == :mandatory
    end
  end

  describe "parse/1 — error handling" do
    test "returns :malformed_xml for non-XML input" do
      assert {:error, %Error{code: :malformed_xml}} = Ddf.parse("this is not XML")
    end

    test "returns :malformed_xml for unclosed tags" do
      assert {:error, %Error{code: :malformed_xml}} =
               Ddf.parse("<LWM2M><Object>oops</LWM2M>")
    end

    test "returns :invalid_ddf for XML missing the <Object> element" do
      assert {:error, %Error{code: :invalid_ddf}} = Ddf.parse("<root/>")
    end

    test "returns :invalid_ddf for unknown type" do
      assert {:error, %Error{code: :invalid_ddf, message: "unknown DDF Type: " <> _}} =
               Ddf.parse(synthetic_ddf(type: "Quantum"))
    end

    test "returns :invalid_ddf for unknown operation letter" do
      assert {:error, %Error{code: :invalid_ddf}} =
               Ddf.parse(synthetic_ddf(operations: "Z"))
    end

    test "returns :invalid_ddf for unknown MultipleInstances value" do
      assert {:error, %Error{code: :invalid_ddf}} =
               Ddf.parse(synthetic_ddf(multiple_instances: "Sometimes"))
    end

    test "returns :invalid_ddf for unknown Mandatory value" do
      assert {:error, %Error{code: :invalid_ddf}} =
               Ddf.parse(synthetic_ddf(mandatory: "Maybe"))
    end

    test "returns :invalid_ddf when ObjectID is not an integer" do
      xml =
        ~s|<?xml version="1.0"?><LWM2M><Object ObjectType="MODefinition"><Name>X</Name>| <>
          ~s|<ObjectID>foo</ObjectID><MultipleInstances>Single</MultipleInstances>| <>
          ~s|<Mandatory>Optional</Mandatory><Resources/></Object></LWM2M>|

      assert {:error, %Error{code: :invalid_ddf}} = Ddf.parse(xml)
    end

    test "returns :invalid_ddf when Item ID attribute is not an integer" do
      xml = """
      <?xml version="1.0"?>
      <LWM2M>
        <Object ObjectType="MODefinition">
          <Name>X</Name><ObjectID>1</ObjectID>
          <MultipleInstances>Single</MultipleInstances><Mandatory>Optional</Mandatory>
          <Resources>
            <Item ID="abc">
              <Name>Bad</Name><Operations>R</Operations>
              <MultipleInstances>Single</MultipleInstances><Mandatory>Optional</Mandatory>
              <Type>Integer</Type>
            </Item>
          </Resources>
        </Object>
      </LWM2M>
      """

      assert {:error, %Error{code: :invalid_ddf, message: "invalid integer in" <> _}} =
               Ddf.parse(xml)
    end

    test "returns :invalid_ddf when a required <Name> element is missing" do
      xml = """
      <?xml version="1.0"?>
      <LWM2M>
        <Object ObjectType="MODefinition">
          <ObjectID>1</ObjectID>
          <MultipleInstances>Single</MultipleInstances><Mandatory>Optional</Mandatory>
          <Resources/>
        </Object>
      </LWM2M>
      """

      assert {:error, %Error{code: :invalid_ddf, message: "missing required <Name>" <> _}} =
               Ddf.parse(xml)
    end

    test "returns :invalid_ddf when an <Item> is missing its ID attribute" do
      xml = """
      <?xml version="1.0"?>
      <LWM2M>
        <Object ObjectType="MODefinition">
          <Name>X</Name><ObjectID>1</ObjectID>
          <MultipleInstances>Single</MultipleInstances><Mandatory>Optional</Mandatory>
          <Resources>
            <Item>
              <Name>NoID</Name><Operations>R</Operations>
              <MultipleInstances>Single</MultipleInstances><Mandatory>Optional</Mandatory>
              <Type>Integer</Type>
            </Item>
          </Resources>
        </Object>
      </LWM2M>
      """

      assert {:error, %Error{code: :invalid_ddf, message: "missing required ID attribute"}} =
               Ddf.parse(xml)
    end
  end

  describe "parse/1 — type variants not present in shipped DDFs" do
    test "Boolean, Unsigned Integer, and Corelnk types parse correctly" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <LWM2M>
        <Object ObjectType="MODefinition">
          <Name>Synthetic</Name>
          <ObjectID>33000</ObjectID>
          <MultipleInstances>Single</MultipleInstances>
          <Mandatory>Optional</Mandatory>
          <Resources>
            <Item ID="0">
              <Name>BoolFlag</Name>
              <Operations>RW</Operations>
              <MultipleInstances>Single</MultipleInstances>
              <Mandatory>Optional</Mandatory>
              <Type>Boolean</Type>
              <RangeEnumeration></RangeEnumeration>
              <Units></Units>
              <Description></Description>
            </Item>
            <Item ID="1">
              <Name>Counter</Name>
              <Operations>R</Operations>
              <MultipleInstances>Single</MultipleInstances>
              <Mandatory>Optional</Mandatory>
              <Type>Unsigned Integer</Type>
              <RangeEnumeration></RangeEnumeration>
              <Units></Units>
              <Description></Description>
            </Item>
            <Item ID="2">
              <Name>Link</Name>
              <Operations>R</Operations>
              <MultipleInstances>Multiple</MultipleInstances>
              <Mandatory>Optional</Mandatory>
              <Type>Corelnk</Type>
              <RangeEnumeration></RangeEnumeration>
              <Units></Units>
              <Description></Description>
            </Item>
          </Resources>
        </Object>
      </LWM2M>
      """

      assert {:ok, definition} = Ddf.parse(xml)

      assert [
               %Resource{type: :boolean, operations: [:read, :write]},
               %Resource{type: :unsigned_integer, operations: [:read]},
               %Resource{type: :core_link, multiple_instances: :multiple}
             ] = definition.resources
    end

    test "empty Operations element parses as []" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <LWM2M>
        <Object ObjectType="MODefinition">
          <Name>Synthetic</Name>
          <ObjectID>33002</ObjectID>
          <MultipleInstances>Single</MultipleInstances>
          <Mandatory>Optional</Mandatory>
          <Resources>
            <Item ID="0">
              <Name>X</Name>
              <Operations></Operations>
              <MultipleInstances>Single</MultipleInstances>
              <Mandatory>Optional</Mandatory>
              <Type>Integer</Type>
            </Item>
          </Resources>
        </Object>
      </LWM2M>
      """

      assert {:ok, %{resources: [resource]}} = Ddf.parse(xml)
      assert resource.operations == []
    end

    test "missing Type element parses as :none, missing Operations parses as []" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <LWM2M>
        <Object ObjectType="MODefinition">
          <Name>Synthetic</Name>
          <ObjectID>33001</ObjectID>
          <MultipleInstances>Single</MultipleInstances>
          <Mandatory>Optional</Mandatory>
          <Resources>
            <Item ID="0">
              <Name>NoTypeNoOps</Name>
              <MultipleInstances>Single</MultipleInstances>
              <Mandatory>Optional</Mandatory>
            </Item>
          </Resources>
        </Object>
      </LWM2M>
      """

      assert {:ok, %{resources: [resource]}} = Ddf.parse(xml)
      assert resource.type == :none
      assert resource.operations == []
    end
  end

  # Builds a minimal valid DDF, with a single keyword-overridable field.
  # Used to exercise individual error branches in the parser.
  defp synthetic_ddf(overrides) do
    o = fn key, default -> Keyword.get(overrides, key, default) end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <LWM2M>
      <Object ObjectType="MODefinition">
        <Name>Synthetic</Name>
        <ObjectID>33000</ObjectID>
        <MultipleInstances>Single</MultipleInstances>
        <Mandatory>Optional</Mandatory>
        <Resources>
          <Item ID="0">
            <Name>X</Name>
            <Operations>#{o.(:operations, "R")}</Operations>
            <MultipleInstances>#{o.(:multiple_instances, "Single")}</MultipleInstances>
            <Mandatory>#{o.(:mandatory, "Optional")}</Mandatory>
            <Type>#{o.(:type, "Integer")}</Type>
          </Item>
        </Resources>
      </Object>
    </LWM2M>
    """
  end
end

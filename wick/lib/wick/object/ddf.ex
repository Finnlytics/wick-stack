defmodule Wick.Object.Ddf do
  @moduledoc """
  Parser for OMA LwM2M DDF (Data Definition Format) XML files.

  Converts a DDF XML document into a `Wick.Object.Definition` struct. Uses the `:xmerl`
  library from OTP stdlib — no runtime dependencies (see ADR 0001).

  ## DDF format

  Authoritative source: the [OMA OMNA LwM2M Registry](https://github.com/OpenMobileAlliance/lwm2m-registry).
  Each registered Object has a versioned XML file (e.g. `3.xml` for the Device object,
  `6.xml` for Location, `3303.xml` for IPSO Temperature). The schema is documented in
  [LWM2M.xsd](http://www.openmobilealliance.org/tech/profiles/LWM2M.xsd).

  Outline (whitespace not significant):

      <LWM2M>
        <Object ObjectType="MODefinition">
          <Name>…</Name>
          <Description1><![CDATA[…]]></Description1>
          <ObjectID>…</ObjectID>
          <ObjectURN>…</ObjectURN>
          <LWM2MVersion>…</LWM2MVersion>
          <ObjectVersion>…</ObjectVersion>
          <MultipleInstances>Single|Multiple</MultipleInstances>
          <Mandatory>Mandatory|Optional</Mandatory>
          <Resources>
            <Item ID="0">
              <Name>…</Name>
              <Operations>R|W|RW|E|</Operations>
              <MultipleInstances>Single|Multiple</MultipleInstances>
              <Mandatory>Mandatory|Optional</Mandatory>
              <Type>String|Integer|Unsigned Integer|Float|Boolean|Opaque|Time|Objlnk|Corelnk|</Type>
              <RangeEnumeration>…</RangeEnumeration>
              <Units>…</Units>
              <Description><![CDATA[…]]></Description>
            </Item>
            …
          </Resources>
        </Object>
      </LWM2M>

  ## Examples

      iex> xml = File.read!(Application.app_dir(:wick, "priv/ddf/6.xml"))
      iex> {:ok, obj} = Wick.Object.Ddf.parse(xml)
      iex> obj.object_id
      6
      iex> obj.name
      "Location"
      iex> length(obj.resources)
      7

  ## Errors

  | Code              | When |
  |-------------------|------|
  | `:malformed_xml`  | Input is not parseable XML |
  | `:invalid_ddf`    | XML parses but is not a valid DDF document |
  """

  alias Wick.Error
  alias Wick.Object.Definition
  alias Wick.Object.Resource

  # xmerl record imports — these are records defined in xmerl.hrl. We extract them lazily
  # via Record so we don't need to track them as a separate dep.
  require Record

  @xmerl_hrl Path.join(:code.lib_dir(:xmerl), "include/xmerl.hrl")

  Record.defrecordp(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from: @xmerl_hrl)
  )

  Record.defrecordp(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from: @xmerl_hrl)
  )

  Record.defrecordp(
    :xml_attribute,
    :xmlAttribute,
    Record.extract(:xmlAttribute, from: @xmerl_hrl)
  )

  @typedoc "Raw DDF XML bytes."
  @type xml :: binary()

  @doc """
  Parse DDF XML bytes into a `Wick.Object.Definition`.
  """
  @spec parse(xml()) :: {:ok, Definition.t()} | {:error, Error.t()}
  def parse(xml) when is_binary(xml) do
    # Pass raw bytes (not codepoints) so xmerl can apply the document's declared encoding
    # itself. `String.to_charlist/1` would surface codepoints > 255 that xmerl rejects.
    {root, _rest} = :xmerl_scan.string(:erlang.binary_to_list(xml), quiet: true)
    {:ok, build_definition(root)}
  rescue
    e in [MatchError, FunctionClauseError, ArgumentError] ->
      {:error, Error.new(:malformed_xml, "could not parse DDF XML: #{Exception.message(e)}")}

    e in RuntimeError ->
      {:error, Error.new(:invalid_ddf, Exception.message(e))}
  catch
    :exit, reason ->
      {:error, Error.new(:malformed_xml, "xmerl exited: #{inspect(reason)}")}
  end

  # ── Definition ──────────────────────────────────────────────────────────────

  defp build_definition(root) do
    object = find_child(root, :Object) || raise "missing <Object> element"
    resources_element = find_child(object, :Resources) || raise "missing <Resources> element"

    %Definition{
      object_id: required_int(object, :ObjectID),
      name: required_text(object, :Name),
      description: optional_text(object, :Description1),
      urn: optional_text(object, :ObjectURN),
      lwm2m_version: optional_text(object, :LWM2MVersion),
      object_version: optional_text(object, :ObjectVersion),
      multiple_instances: required_multiplicity(object),
      mandatory: required_requirement(object),
      resources: build_resources(resources_element)
    }
  end

  defp build_resources(resources_element) do
    resources_element
    |> all_children(:Item)
    |> Enum.map(&build_resource/1)
    |> Enum.sort_by(& &1.resource_id)
  end

  defp build_resource(item) do
    %Resource{
      resource_id: required_attr_int(item, :ID),
      name: required_text(item, :Name),
      description: optional_text(item, :Description),
      type: parse_type(optional_text(item, :Type)),
      operations: parse_operations(optional_text(item, :Operations)),
      multiple_instances: required_multiplicity(item),
      mandatory: required_requirement(item),
      range_enumeration: blank_to_nil(optional_text(item, :RangeEnumeration)),
      units: blank_to_nil(optional_text(item, :Units))
    }
  end

  # ── Field parsers ───────────────────────────────────────────────────────────

  defp parse_type(nil), do: :none
  defp parse_type(""), do: :none
  defp parse_type("String"), do: :string
  defp parse_type("Integer"), do: :integer
  defp parse_type("Unsigned Integer"), do: :unsigned_integer
  defp parse_type("Float"), do: :float
  defp parse_type("Boolean"), do: :boolean
  defp parse_type("Opaque"), do: :opaque
  defp parse_type("Time"), do: :time
  defp parse_type("Objlnk"), do: :objlnk
  defp parse_type("Corelnk"), do: :core_link
  defp parse_type(other), do: raise("unknown DDF Type: #{inspect(other)}")

  defp parse_operations(nil), do: []
  defp parse_operations(""), do: []

  defp parse_operations(string) do
    string
    |> String.upcase()
    |> String.graphemes()
    |> Enum.map(&parse_operation_letter/1)
  end

  defp parse_operation_letter("R"), do: :read
  defp parse_operation_letter("W"), do: :write
  defp parse_operation_letter("E"), do: :execute
  defp parse_operation_letter(other), do: raise("unknown Operations letter: #{inspect(other)}")

  defp required_multiplicity(element) do
    case required_text(element, :MultipleInstances) do
      "Single" -> :single
      "Multiple" -> :multiple
      other -> raise "unknown MultipleInstances: #{inspect(other)}"
    end
  end

  defp required_requirement(element) do
    case required_text(element, :Mandatory) do
      "Mandatory" -> :mandatory
      "Optional" -> :optional
      other -> raise "unknown Mandatory: #{inspect(other)}"
    end
  end

  defp required_int(element, child_name) do
    text = required_text(element, child_name)

    case Integer.parse(text) do
      {n, ""} -> n
      _ -> raise "invalid integer in <#{child_name}>: #{inspect(text)}"
    end
  end

  defp required_attr_int(element, attr_name) do
    text = required_attr(element, attr_name)

    case Integer.parse(text) do
      {n, ""} -> n
      _ -> raise "invalid integer in #{attr_name} attribute: #{inspect(text)}"
    end
  end

  # ── XML helpers ─────────────────────────────────────────────────────────────

  defp required_text(element, child_name) do
    case optional_text(element, child_name) do
      nil -> raise "missing required <#{child_name}> element"
      text -> text
    end
  end

  defp optional_text(element, child_name) do
    case find_child(element, child_name) do
      nil -> nil
      child -> child |> text_content() |> String.trim()
    end
  end

  defp required_attr(element, attr_name) do
    case attr(element, attr_name) do
      nil -> raise "missing required #{attr_name} attribute"
      value -> value
    end
  end

  defp find_child(element, name) do
    element |> child_elements() |> Enum.find(&(elem_name(&1) == name))
  end

  defp all_children(element, name) do
    element |> child_elements() |> Enum.filter(&(elem_name(&1) == name))
  end

  defp child_elements(element) do
    element
    |> xml_element(:content)
    |> Enum.filter(&Record.is_record(&1, :xmlElement))
  end

  defp elem_name(element), do: xml_element(element, :name)

  defp text_content(element) do
    element
    |> xml_element(:content)
    |> Enum.reduce([], fn node, acc ->
      if Record.is_record(node, :xmlText), do: [xml_text(node, :value) | acc], else: acc
    end)
    |> Enum.reverse()
    |> :unicode.characters_to_binary()
    |> case do
      bin when is_binary(bin) -> bin
      {:error, _, _} -> raise "non-UTF-8 text content"
    end
  end

  defp attr(element, name) do
    element
    |> xml_element(:attributes)
    |> Enum.find(fn rec ->
      Record.is_record(rec, :xmlAttribute) and xml_attribute(rec, :name) == name
    end)
    |> case do
      nil -> nil
      rec -> rec |> xml_attribute(:value) |> to_string() |> String.trim()
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end

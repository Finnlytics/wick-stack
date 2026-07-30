defmodule Wick.Object.DefinitionTest do
  use ExUnit.Case, async: true

  alias Wick.Object.Definition
  alias Wick.Object.Resource

  doctest Definition

  defp obj(resources) do
    %Definition{
      object_id: 6,
      name: "Location",
      description: nil,
      urn: nil,
      lwm2m_version: nil,
      object_version: nil,
      multiple_instances: :single,
      mandatory: :optional,
      resources: resources
    }
  end

  defp resource(id, name) do
    %Resource{
      resource_id: id,
      name: name,
      type: :float,
      operations: [:read],
      multiple_instances: :single,
      mandatory: :mandatory,
      description: nil,
      range_enumeration: nil,
      units: nil
    }
  end

  describe "find_resource/2" do
    test "returns the matching resource by id" do
      definition = obj([resource(0, "Latitude"), resource(1, "Longitude")])

      assert %Resource{name: "Latitude"} = Definition.find_resource(definition, 0)
      assert %Resource{name: "Longitude"} = Definition.find_resource(definition, 1)
    end

    test "returns nil for an unknown resource id" do
      definition = obj([resource(0, "Latitude")])
      assert Definition.find_resource(definition, 999) == nil
    end

    test "returns nil for an empty definition" do
      assert Definition.find_resource(obj([]), 0) == nil
    end
  end
end

defmodule Wick.Object.RegistryTest do
  use ExUnit.Case, async: true

  alias Wick.Error
  alias Wick.Object.Definition
  alias Wick.Object.Registry
  alias Wick.Object.Resource

  doctest Registry

  defp definition(object_id, name, resources \\ []) do
    %Definition{
      object_id: object_id,
      name: name,
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
      type: :string,
      operations: [:read],
      multiple_instances: :single,
      mandatory: :optional,
      description: nil,
      range_enumeration: nil,
      units: nil
    }
  end

  describe "new/0" do
    test "creates an empty registry" do
      registry = Registry.new()
      assert Registry.size(registry) == 0
      assert Registry.object_ids(registry) == []
    end
  end

  describe "from_definitions/1" do
    test "wraps a list of definitions in a registry" do
      registry =
        Registry.from_definitions([
          definition(3, "Device"),
          definition(6, "Location")
        ])

      assert Registry.size(registry) == 2
      assert Registry.object_ids(registry) == [3, 6]
    end

    test "later definitions overwrite earlier ones with the same Object ID" do
      registry =
        Registry.from_definitions([
          definition(6, "First"),
          definition(6, "Second")
        ])

      assert Registry.size(registry) == 1
      assert Registry.lookup(registry, 6).name == "Second"
    end
  end

  describe "register/2" do
    test "adds a new Object Definition" do
      registry = Registry.new() |> Registry.register(definition(6, "Location"))
      assert Registry.lookup(registry, 6).name == "Location"
    end

    test "is immutable — original registry is unchanged" do
      r0 = Registry.new()
      _r1 = Registry.register(r0, definition(6, "Location"))
      assert Registry.size(r0) == 0
    end
  end

  describe "unregister/2" do
    test "removes an Object by ID" do
      registry =
        Registry.new()
        |> Registry.register(definition(3, "Device"))
        |> Registry.register(definition(6, "Location"))
        |> Registry.unregister(6)

      assert Registry.object_ids(registry) == [3]
    end

    test "no-op for an ID that is not registered" do
      registry =
        Registry.new()
        |> Registry.register(definition(3, "Device"))
        |> Registry.unregister(999)

      assert Registry.size(registry) == 1
    end
  end

  describe "lookup/2" do
    setup do
      registry =
        Registry.from_definitions([
          definition(6, "Location", [resource(0, "Latitude"), resource(1, "Longitude")])
        ])

      %{registry: registry}
    end

    test "returns the Definition for a registered Object", %{registry: registry} do
      assert %Definition{name: "Location"} = Registry.lookup(registry, 6)
    end

    test "returns nil for an unregistered Object", %{registry: registry} do
      assert Registry.lookup(registry, 999) == nil
    end
  end

  describe "lookup_resource/3" do
    setup do
      registry =
        Registry.from_definitions([
          definition(6, "Location", [resource(0, "Latitude"), resource(1, "Longitude")])
        ])

      %{registry: registry}
    end

    test "returns the Resource when both Object and Resource are present", %{registry: registry} do
      assert %Resource{name: "Latitude"} = Registry.lookup_resource(registry, 6, 0)
      assert %Resource{name: "Longitude"} = Registry.lookup_resource(registry, 6, 1)
    end

    test "returns nil for unknown Resource ID on a known Object", %{registry: registry} do
      assert Registry.lookup_resource(registry, 6, 999) == nil
    end

    test "returns nil for an unknown Object ID", %{registry: registry} do
      assert Registry.lookup_resource(registry, 999, 0) == nil
    end
  end

  describe "object_ids/1" do
    test "returns Object IDs in ascending numeric order" do
      registry =
        Registry.from_definitions([
          definition(6, "Location"),
          definition(3, "Device"),
          definition(3303, "Temperature")
        ])

      assert Registry.object_ids(registry) == [3, 6, 3303]
    end
  end

  describe "load_from_dir/1" do
    test "loads every *.xml in priv/ddf into a working registry" do
      ddf_dir = Application.app_dir(:wick, "priv/ddf")

      assert {:ok, registry} = Registry.load_from_dir(ddf_dir)
      assert Registry.size(registry) == 3
      assert Registry.object_ids(registry) == [3, 6, 3303]
      assert Registry.lookup(registry, 6).name == "Location"
      assert Registry.lookup_resource(registry, 3303, 5700).name == "Sensor Value"
    end

    test "returns :directory_unreadable when the path is not a directory" do
      assert {:error, %Error{code: :directory_unreadable}} =
               Registry.load_from_dir("/nonexistent-dir-#{System.unique_integer()}")
    end

    test "annotates parse errors with the offending file path" do
      tmp_dir = Path.join(System.tmp_dir!(), "wick-bad-ddf-#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)
      bad_file = Path.join(tmp_dir, "broken.xml")
      File.write!(bad_file, "<not-a-ddf/>")

      try do
        assert {:error, %Error{code: :invalid_ddf, meta: meta}} =
                 Registry.load_from_dir(tmp_dir)

        assert meta.file == bad_file
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "returns :file_unreadable for unreadable files" do
      tmp_dir = Path.join(System.tmp_dir!(), "wick-unreadable-#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)
      bad_file = Path.join(tmp_dir, "broken.xml")
      File.write!(bad_file, "<root/>")
      File.chmod!(bad_file, 0o000)

      try do
        assert {:error, %Error{code: code}} = Registry.load_from_dir(tmp_dir)
        # On macOS readable mode-0 files may still parse for the file owner; accept either.
        assert code in [:file_unreadable, :invalid_ddf]
      after
        File.chmod!(bad_file, 0o644)
        File.rm_rf!(tmp_dir)
      end
    end
  end
end

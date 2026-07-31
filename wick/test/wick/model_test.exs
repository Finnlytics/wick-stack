defmodule Wick.ModelTest do
  use ExUnit.Case, async: true

  alias Wick.Model
  alias Wick.Object.Definition
  alias Wick.Object.Registry
  alias Wick.Object.Resource

  doctest Wick.Model

  defp path!(string) do
    {:ok, path} = Wick.Path.parse(string)
    path
  end

  defp resource(id, type, opts \\ []) do
    %Resource{
      resource_id: id,
      name: "Resource #{id}",
      type: type,
      operations: [:read, :write],
      multiple_instances: Keyword.get(opts, :multiple_instances, :single),
      mandatory: :optional
    }
  end

  defp registry do
    Registry.from_definitions([
      %Definition{
        object_id: 3,
        name: "Device",
        multiple_instances: :single,
        mandatory: :mandatory,
        resources: [
          resource(0, :string),
          resource(6, :integer, multiple_instances: :multiple),
          resource(9, :integer),
          resource(13, :time)
        ]
      }
    ])
  end

  describe "resource_type/2 with a registry" do
    test "resolves a declared Resource type" do
      assert Model.resource_type(registry(), path!("/3/0/13")) == :time
      assert Model.resource_type(registry(), path!("/3/0/0")) == :string
    end

    test "resolves a Resource Instance through its parent Resource" do
      assert Model.resource_type(registry(), path!("/3/0/6/0")) == :integer
      assert Model.resource_type(registry(), path!("/3/0/6/1")) == :integer
    end

    test "returns nil for an unknown Object" do
      assert Model.resource_type(registry(), path!("/9999/0/0")) == nil
    end

    test "returns nil for an unknown Resource on a known Object" do
      assert Model.resource_type(registry(), path!("/3/0/9999")) == nil
    end

    test "returns nil for a path that is not a Resource" do
      assert Model.resource_type(registry(), path!("/3")) == nil
      assert Model.resource_type(registry(), path!("/3/0")) == nil
    end

    test "the Instance ID does not affect resolution" do
      assert Model.resource_type(registry(), path!("/3/7/13")) == :time
    end
  end

  describe "resource_type/2 with no model" do
    test "always returns nil" do
      assert Model.resource_type(nil, path!("/3/0/13")) == nil
      assert Model.resource_type(nil, path!("/3/0")) == nil
    end
  end

  describe "resource_type/2 with a function" do
    test "delegates to the function" do
      resolver = fn
        %Wick.Path{object_id: 3, resource_id: 13} -> :time
        _other -> nil
      end

      assert Model.resource_type(resolver, path!("/3/0/13")) == :time
      assert Model.resource_type(resolver, path!("/3/0/9")) == nil
    end

    test "receives the whole path, so a resolver can be Instance-aware" do
      resolver = fn path -> if path.object_instance_id == 0, do: :integer, else: :string end

      assert Model.resource_type(resolver, path!("/3/0/9")) == :integer
      assert Model.resource_type(resolver, path!("/3/1/9")) == :string
    end

    test "is never called for a non-Resource path" do
      resolver = fn _path -> flunk("resolver should not be called") end

      assert Model.resource_type(resolver, path!("/3/0")) == nil
    end
  end

  describe "model?/1" do
    test "accepts every supported shape" do
      assert Model.model?(nil)
      assert Model.model?(Registry.new())
      assert Model.model?(fn _path -> nil end)
    end

    test "rejects anything else" do
      refute Model.model?(:registry)
      refute Model.model?(%{})
      refute Model.model?(fn -> nil end)
      refute Model.model?(fn _a, _b -> nil end)
    end
  end

  describe "type vocabulary" do
    test "every DDF-declarable type is a Wick.Value type" do
      # `Wick.Object.Resource.value_type/0` is an alias for `Wick.Value.type/0`, so a
      # resolver can never return a tag the value layer does not understand. This guards the
      # drift that had the DDF parser emitting :corelnk while the tree matched on :core_link.
      {:ok, bundled} = Registry.load_from_dir(Application.app_dir(:wick, "priv/ddf"))

      declared =
        bundled
        |> Registry.object_ids()
        |> Enum.flat_map(fn id ->
          Registry.lookup(bundled, id).resources |> Enum.map(& &1.type)
        end)
        |> Enum.uniq()

      assert declared != []
      assert Enum.all?(declared, &(&1 in Wick.Value.types()))
    end
  end
end

defmodule Wick.Object.TreeTest do
  use ExUnit.Case, async: true

  doctest Wick.Object.Tree

  alias Wick.Attributes
  alias Wick.Object.Tree
  alias Wick.Path
  alias Wick.Senml.Pack
  alias Wick.Senml.Record

  defp path!(string) do
    {:ok, path} = Path.parse(string)
    path
  end

  defp device do
    Tree.from_map(%{
      1 => %{0 => %{0 => {:integer, 101}, 1 => {:integer, 86_400}}},
      3 => %{0 => %{0 => {:string, "ACME"}, 9 => {:integer, 87}}},
      3303 => %{0 => %{5700 => {:float, 22.5}}, 1 => %{5700 => {:float, 18.0}}}
    })
  end

  describe "from_map/1" do
    test "creates every Instance mentioned, including empty ones" do
      tree = Tree.from_map(%{1 => %{0 => %{}}, 3 => %{0 => %{}, 1 => %{}}})

      assert Tree.instance_ids(tree, 1) == [0]
      assert Tree.instance_ids(tree, 3) == [0, 1]
    end

    test "an empty map yields an empty tree" do
      assert Tree.from_map(%{}) == Tree.new()
    end
  end

  describe "put/3 and fetch/2" do
    test "stores and reads a tagged value" do
      path = path!("/3303/0/5700")
      tree = Tree.put(Tree.new(), path, {:float, 22.5})

      assert Tree.fetch(tree, path) == {:ok, {:float, 22.5}}
    end

    test "preserves the type tag rather than inferring it" do
      # 42 stored as a Float must not come back as an Integer.
      path = path!("/3303/0/5700")

      assert Tree.fetch(Tree.put(Tree.new(), path, {:float, 42.0}), path) == {:ok, {:float, 42.0}}
      assert Tree.fetch(Tree.put(Tree.new(), path, {:integer, 42}), path) == {:ok, {:integer, 42}}
    end

    test "creates the Object Instance implicitly" do
      tree = Tree.put(Tree.new(), path!("/3303/7/5700"), {:float, 1.0})

      assert Tree.instance?(tree, 3303, 7)
    end

    test "supports Resource Instance paths for multi-instance Resources" do
      tree =
        Tree.new()
        |> Tree.put(path!("/3/0/6/0"), {:integer, 1})
        |> Tree.put(path!("/3/0/6/1"), {:integer, 5})

      assert Tree.fetch(tree, path!("/3/0/6/0")) == {:ok, {:integer, 1}}
      assert Tree.fetch(tree, path!("/3/0/6/1")) == {:ok, {:integer, 5}}
    end

    test "an unset path is :error" do
      assert Tree.fetch(device(), path!("/3/0/17")) == :error
    end

    test "refuses to store at a path with no Resource" do
      for string <- ["/3", "/3/0"] do
        assert_raise ArgumentError, ~r/not a Resource path/, fn ->
          Tree.put(Tree.new(), path!(string), {:integer, 1})
        end
      end
    end
  end

  describe "delete/2 and delete_instance/3" do
    test "delete/2 removes one Resource and leaves its siblings" do
      tree = Tree.delete(device(), path!("/3/0/9"))

      assert Tree.fetch(tree, path!("/3/0/9")) == :error
      assert Tree.fetch(tree, path!("/3/0/0")) == {:ok, {:string, "ACME"}}
      assert Tree.instance?(tree, 3, 0), "deleting a Resource must not delete its Instance"
    end

    test "delete/2 on an unset path is a no-op" do
      tree = device()

      assert Tree.delete(tree, path!("/3/0/17")) == tree
    end

    test "delete_instance/3 removes the Instance, its Resources, and its attributes" do
      tree =
        device()
        |> Tree.put_attributes(path!("/3303/0/5700"), %Attributes{pmin: 10})
        |> Tree.delete_instance(3303, 0)

      refute Tree.instance?(tree, 3303, 0)
      assert Tree.fetch(tree, path!("/3303/0/5700")) == :error
      assert Tree.attributes(tree, path!("/3303/0/5700")) == %Attributes{}
    end

    test "delete_instance/3 leaves sibling Instances of the same Object alone" do
      tree = Tree.delete_instance(device(), 3303, 0)

      assert Tree.instance_ids(tree, 3303) == [1]
      assert Tree.fetch(tree, path!("/3303/1/5700")) == {:ok, {:float, 18.0}}
    end
  end

  describe "next_instance_id/2" do
    test "fills the lowest gap" do
      tree = Tree.from_map(%{1 => %{0 => %{}, 2 => %{}}})

      assert Tree.next_instance_id(tree, 1) == 1
    end

    test "starts at 0 for an unknown Object" do
      assert Tree.next_instance_id(device(), 5) == 0
    end

    test "appends when the Instances are contiguous" do
      assert Tree.next_instance_id(device(), 3303) == 2
    end
  end

  describe "subtree/2" do
    test "a Resource path yields at most itself" do
      assert device() |> Tree.subtree(path!("/3/0/9")) |> Enum.map(&elem(&1, 1)) ==
               [{:integer, 87}]
    end

    test "an Object Instance path yields its Resources in ascending order" do
      assert device()
             |> Tree.subtree(path!("/3/0"))
             |> Enum.map(fn {path, _value} -> Path.format(path) end) == ["/3/0/0", "/3/0/9"]
    end

    test "an Object path spans every Instance" do
      assert device()
             |> Tree.subtree(path!("/3303"))
             |> Enum.map(fn {path, _value} -> Path.format(path) end) ==
               ["/3303/0/5700", "/3303/1/5700"]
    end

    test "sorts numerically, not lexically" do
      tree =
        Tree.from_map(%{
          3 => %{0 => %{9 => {:integer, 1}, 11 => {:integer, 2}, 2 => {:integer, 3}}}
        })

      assert tree
             |> Tree.subtree(path!("/3/0"))
             |> Enum.map(fn {path, _value} -> Path.format(path) end) ==
               ["/3/0/2", "/3/0/9", "/3/0/11"]
    end

    test "an unknown path yields nothing" do
      assert Tree.subtree(device(), path!("/9999")) == []
    end
  end

  describe "exists?/2" do
    test "an Object exists when it has at least one Instance" do
      assert Tree.exists?(device(), path!("/3303"))
      refute Tree.exists?(device(), path!("/9999"))
    end

    test "an Object Instance exists once created, even with no Resources set" do
      tree = Tree.create_instance(Tree.new(), 5, 0)

      assert Tree.exists?(tree, path!("/5/0"))
      assert Tree.exists?(tree, path!("/5"))
    end

    test "a Resource exists only when its value is set" do
      assert Tree.exists?(device(), path!("/3/0/9"))
      refute Tree.exists?(device(), path!("/3/0/17"))
    end
  end

  describe "attributes" do
    test "an unset path reports an empty set rather than nil" do
      assert Tree.attributes(device(), path!("/3/0/9")) == %Attributes{}
    end

    test "put_attributes/3 folds rather than replacing" do
      path = path!("/3303/0/5700")

      tree =
        device()
        |> Tree.put_attributes(path, %Attributes{pmin: 10, pmax: 60})
        |> Tree.put_attributes(path, %Attributes{pmin: 30})

      assert Tree.attributes(tree, path) == %Attributes{pmin: 30, pmax: 60}
    end

    test "attributes are held per path, not per Object" do
      tree = Tree.put_attributes(device(), path!("/3303/0/5700"), %Attributes{pmin: 10})

      assert Tree.attributes(tree, path!("/3303/1/5700")) == %Attributes{}
    end
  end

  describe "links/1" do
    test "one link per Object Instance, ascending" do
      assert device() |> Tree.links() |> Enum.map(& &1.target) ==
               ["/1/0", "/3/0", "/3303/0", "/3303/1"]
    end

    test "an empty tree advertises nothing" do
      assert Tree.links(Tree.new()) == []
    end
  end

  describe "discover/2" do
    test "includes the target itself, then its Resources" do
      assert device() |> Tree.discover(path!("/3/0")) |> Enum.map(& &1.target) ==
               ["/3/0", "/3/0/0", "/3/0/9"]
    end

    test "carries the attributes in force at each level" do
      tree =
        device()
        |> Tree.put_attributes(path!("/3303/0"), %Attributes{pmax: 300})
        |> Tree.put_attributes(path!("/3303/0/5700"), %Attributes{pmin: 10})

      links = Tree.discover(tree, path!("/3303/0"))

      assert Enum.find(links, &(&1.target == "/3303/0")).params == %{"pmax" => "300"}
      assert Enum.find(links, &(&1.target == "/3303/0/5700")).params == %{"pmin" => "10"}
    end

    test "a Resource target yields just itself" do
      assert device() |> Tree.discover(path!("/3/0/9")) |> Enum.map(& &1.target) == ["/3/0/9"]
    end
  end

  describe "to_pack/2" do
    test "names are absolute" do
      pack = Tree.to_pack(device(), [path!("/3303/0")])

      assert Enum.map(pack.records, & &1.name) == ["/3303/0/5700"]
    end

    test "spans several roots and de-duplicates overlaps" do
      pack = Tree.to_pack(device(), [path!("/3/0"), path!("/3/0/9")])

      assert Enum.map(pack.records, & &1.name) == ["/3/0/0", "/3/0/9"]
    end

    test "maps each value tag onto the right SenML field" do
      tree =
        Tree.new()
        |> Tree.put(path!("/9/0/0"), {:string, "text"})
        |> Tree.put(path!("/9/0/1"), {:integer, 7})
        |> Tree.put(path!("/9/0/2"), {:float, 1.5})
        |> Tree.put(path!("/9/0/3"), {:boolean, true})
        |> Tree.put(path!("/9/0/4"), {:opaque, <<0xDE, 0xAD>>})
        |> Tree.put(path!("/9/0/5"), {:objlnk, {1, 0}})
        |> Tree.put(path!("/9/0/6"), {:time, 1_700_000_000})

      records = Tree.to_pack(tree, [path!("/9/0")]).records

      assert Enum.map(records, &Record.value_type(&1)) ==
               [:string, :number, :number, :boolean, :opaque, :objlnk, :number]

      assert Enum.find(records, &(&1.name == "/9/0/5")).object_link_value == "1:0"
      assert Enum.find(records, &(&1.name == "/9/0/4")).opaque_value == <<0xDE, 0xAD>>
    end

    test "an empty selection yields an empty pack" do
      assert Tree.to_pack(device(), [path!("/9999")]) == Pack.new([])
    end
  end

  describe "apply_pack/3" do
    test "absolute names need no base" do
      pack = Pack.new([%Record{name: "/3303/0/5700", number_value: 30.0}])

      assert {:ok, tree} = Tree.apply_pack(Tree.new(), pack)
      assert Tree.fetch(tree, path!("/3303/0/5700")) == {:ok, {:float, 30.0}}
    end

    test "a bare name is relative to the base, even when it parses as a path" do
      # "1" is a syntactically valid absolute path (/1), so this is the case that matters:
      # a Write on /1/0 sending record "1" means /1/0/1, not /1.
      pack = Pack.new([%Record{name: "1", number_value: 120}])

      assert {:ok, tree} = Tree.apply_pack(device(), pack, path!("/1/0"))
      assert Tree.fetch(tree, path!("/1/0/1")) == {:ok, {:integer, 120}}
    end

    test "a leading slash means absolute even when a base is given" do
      pack = Pack.new([%Record{name: "/3/0/9", number_value: 99}])

      assert {:ok, tree} = Tree.apply_pack(device(), pack, path!("/1/0"))
      assert Tree.fetch(tree, path!("/3/0/9")) == {:ok, {:integer, 99}}
      assert Tree.fetch(tree, path!("/1/0/9")) == :error
    end

    test "resolves base_name before applying" do
      pack = Pack.new([%Record{base_name: "/3303/0/", name: "5700", number_value: 31.5}])

      assert {:ok, tree} = Tree.apply_pack(Tree.new(), pack)
      assert Tree.fetch(tree, path!("/3303/0/5700")) == {:ok, {:float, 31.5}}
    end

    test "merges rather than replacing — partial-update Write semantics" do
      pack = Pack.new([%Record{name: "9", number_value: 99}])

      assert {:ok, tree} = Tree.apply_pack(device(), pack, path!("/3/0"))
      assert Tree.fetch(tree, path!("/3/0/9")) == {:ok, {:integer, 99}}
      assert Tree.fetch(tree, path!("/3/0/0")) == {:ok, {:string, "ACME"}}
    end

    test "recovers Integer vs Float from the wire shape" do
      pack =
        Pack.new([
          %Record{name: "/9/0/0", number_value: 7},
          %Record{name: "/9/0/1", number_value: 7.0}
        ])

      assert {:ok, tree} = Tree.apply_pack(Tree.new(), pack)
      assert Tree.fetch(tree, path!("/9/0/0")) == {:ok, {:integer, 7}}
      assert Tree.fetch(tree, path!("/9/0/1")) == {:ok, {:float, 7.0}}
    end

    test "round-trips through to_pack/2" do
      tree = device()
      pack = Tree.to_pack(tree, [path!("/3/0")])

      assert {:ok, rebuilt} = Tree.apply_pack(Tree.new(), pack)
      assert Tree.subtree(rebuilt, path!("/3/0")) == Tree.subtree(tree, path!("/3/0"))
    end

    test "a name that resolves above Resource level is an error, not a raise" do
      pack = Pack.new([%Record{name: "/3", number_value: 1}])

      assert {:error, err} = Tree.apply_pack(Tree.new(), pack)
      assert err.code == :not_a_resource_path
      assert err.meta == %{path: "/3"}
    end

    test "a name that is not a path at all is an error" do
      pack = Pack.new([%Record{name: "/3/0/temperature", number_value: 1}])

      assert {:error, %{code: :invalid_path}} = Tree.apply_pack(Tree.new(), pack)
    end

    test "stops at the first bad record and reports it" do
      pack =
        Pack.new([
          %Record{name: "/3/0/9", number_value: 1},
          %Record{name: "/nope", number_value: 2}
        ])

      assert {:error, %{code: :invalid_path}} = Tree.apply_pack(Tree.new(), pack)
    end

    test "an empty pack leaves the tree untouched" do
      tree = device()

      assert Tree.apply_pack(tree, Pack.new([])) == {:ok, tree}
    end
  end

  describe "apply_pack/3 with a :model" do
    test "recovers the types SenML cannot express" do
      pack =
        Pack.new([
          %Record{name: "/7/0/0", number_value: 1_700_000_000},
          %Record{name: "/7/0/1", number_value: 42},
          %Record{name: "/7/0/2", string_value: "</3/0>"}
        ])

      assert {:ok, tree} = Tree.apply_pack(Tree.new(), pack, model: model())

      assert Tree.fetch(tree, path!("/7/0/0")) == {:ok, {:time, 1_700_000_000}}
      assert Tree.fetch(tree, path!("/7/0/1")) == {:ok, {:unsigned_integer, 42}}
      assert Tree.fetch(tree, path!("/7/0/2")) == {:ok, {:core_link, "</3/0>"}}
    end

    test "without a model the same pack narrows to the wire shape" do
      pack =
        Pack.new([
          %Record{name: "/7/0/0", number_value: 1_700_000_000},
          %Record{name: "/7/0/2", string_value: "</3/0>"}
        ])

      assert {:ok, tree} = Tree.apply_pack(Tree.new(), pack)

      assert Tree.fetch(tree, path!("/7/0/0")) == {:ok, {:integer, 1_700_000_000}}
      assert Tree.fetch(tree, path!("/7/0/2")) == {:ok, {:string, "</3/0>"}}
    end

    test "a Float Resource accepts a whole number and widens it" do
      pack = Pack.new([%Record{name: "/7/0/3", number_value: 22}])

      assert {:ok, tree} = Tree.apply_pack(Tree.new(), pack, model: model())
      assert Tree.fetch(tree, path!("/7/0/3")) == {:ok, {:float, 22.0}}
    end

    test "an Integer Resource does not accept a float" do
      pack = Pack.new([%Record{name: "/7/0/4", number_value: 22.5}])

      assert {:error, err} = Tree.apply_pack(Tree.new(), pack, model: model())
      assert err.code == :type_mismatch
    end

    test "a string sent to a numeric Resource is a type mismatch, not a silent store" do
      pack = Pack.new([%Record{name: "/7/0/1", string_value: "forty-two"}])

      assert {:error, err} = Tree.apply_pack(Tree.new(), pack, model: model())
      assert err.code == :type_mismatch
      assert err.meta.path == "/7/0/1"
      assert err.meta.declared == :unsigned_integer
      assert err.meta.actual == :string
      assert err.message =~ "declared :unsigned_integer"
    end

    test "a negative value for an Unsigned Integer Resource is rejected" do
      pack = Pack.new([%Record{name: "/7/0/1", number_value: -1}])

      assert {:error, %{code: :type_mismatch}} = Tree.apply_pack(Tree.new(), pack, model: model())
    end

    test "a Resource the model does not know falls back to wire-shape inference" do
      pack = Pack.new([%Record{name: "/7/0/999", number_value: 5}])

      assert {:ok, tree} = Tree.apply_pack(Tree.new(), pack, model: model())
      assert Tree.fetch(tree, path!("/7/0/999")) == {:ok, {:integer, 5}}
    end

    test "a Resource Instance resolves through its parent Resource" do
      pack = Pack.new([%Record{name: "/7/0/5/0", number_value: 1_700_000_000}])

      assert {:ok, tree} = Tree.apply_pack(Tree.new(), pack, model: model())
      assert Tree.fetch(tree, path!("/7/0/5/0")) == {:ok, {:time, 1_700_000_000}}
    end

    test "base and model combine" do
      pack = Pack.new([%Record{name: "0", number_value: 1_700_000_000}])

      assert {:ok, tree} =
               Tree.apply_pack(Tree.new(), pack, base: path!("/7/0"), model: model())

      assert Tree.fetch(tree, path!("/7/0/0")) == {:ok, {:time, 1_700_000_000}}
    end

    test "a positional base still works" do
      pack = Pack.new([%Record{name: "9", number_value: 1}])

      assert {:ok, tree} = Tree.apply_pack(Tree.new(), pack, path!("/3/0"))
      assert Tree.fetch(tree, path!("/3/0/9")) == {:ok, {:integer, 1}}
    end
  end

  describe "to_pack/2 with a Time Resource" do
    test "an epoch integer encodes as a number" do
      tree = Tree.from_map(%{7 => %{0 => %{0 => {:time, 1_700_000_000}}}})

      assert [%Record{name: "/7/0/0", number_value: 1_700_000_000}] =
               Tree.to_pack(tree, [path!("/7/0")]).records
    end

    test "a DateTime names the mistake instead of failing inside the codec" do
      tree = Tree.from_map(%{7 => %{0 => %{0 => {:time, ~U[2026-07-31 12:00:00Z]}}}})

      assert_raise ArgumentError, ~r/Time is an integer count of seconds/, fn ->
        Tree.to_pack(tree, [path!("/7/0")])
      end
    end

    test "a Time Resource survives a full round-trip with a model" do
      tree = Tree.from_map(%{7 => %{0 => %{0 => {:time, 1_700_000_000}}}})
      pack = Tree.to_pack(tree, [path!("/7/0")])

      assert {:ok, rebuilt} = Tree.apply_pack(Tree.new(), pack, model: model())
      assert Tree.subtree(rebuilt, path!("/7/0")) == Tree.subtree(tree, path!("/7/0"))
    end
  end

  # A synthetic Object exercising every type SenML cannot express on its own.
  defp model do
    resource = fn id, type, multiplicity ->
      %Wick.Object.Resource{
        resource_id: id,
        name: "Resource #{id}",
        type: type,
        operations: [:read, :write],
        multiple_instances: multiplicity,
        mandatory: :optional
      }
    end

    Wick.Object.Registry.from_definitions([
      %Wick.Object.Definition{
        object_id: 7,
        name: "Test",
        multiple_instances: :single,
        mandatory: :optional,
        resources: [
          resource.(0, :time, :single),
          resource.(1, :unsigned_integer, :single),
          resource.(2, :core_link, :single),
          resource.(3, :float, :single),
          resource.(4, :integer, :single),
          resource.(5, :time, :multiple)
        ]
      }
    ])
  end
end

defmodule Wick.Codec.TlvTest do
  use ExUnit.Case, async: true

  doctest Wick.Codec.Tlv

  alias Wick.Codec.Tlv, as: Codec
  alias Wick.Object.Definition
  alias Wick.Object.Registry
  alias Wick.Object.Resource
  alias Wick.Object.Tree
  alias Wick.Senml.Pack
  alias Wick.Senml.Record

  defp path!(string) do
    {:ok, path} = Wick.Path.parse(string)
    path
  end

  defp hex(pack, opts),
    do:
      pack
      |> Codec.encode(opts)
      |> then(fn {:ok, io} -> io end)
      |> IO.iodata_to_binary()
      |> Base.encode16()

  defp resource(id, type, multiplicity \\ :single) do
    %Resource{
      resource_id: id,
      name: "Resource #{id}",
      type: type,
      operations: [:read, :write],
      multiple_instances: multiplicity,
      mandatory: :optional
    }
  end

  # Object 3 as far as the spec's §4.3.1 example exercises it.
  defp device_model do
    Registry.from_definitions([
      %Definition{
        object_id: 3,
        name: "Device",
        multiple_instances: :single,
        mandatory: :mandatory,
        resources: [
          resource(0, :string),
          resource(1, :string),
          resource(2, :string),
          resource(3, :string),
          resource(6, :integer, :multiple),
          resource(7, :integer, :multiple),
          resource(8, :integer, :multiple),
          resource(9, :integer),
          resource(10, :integer),
          resource(11, :integer, :multiple),
          resource(13, :time),
          resource(14, :string),
          resource(15, :string),
          resource(16, :string),
          resource(17, :string)
        ]
      }
    ])
  end

  describe "content_format/0" do
    test "is 11542" do
      assert Codec.content_format() == 11_542
      assert Wick.Codec.for_content_format(11_542) == Codec
    end
  end

  describe ":path is required" do
    test "encode refuses without one" do
      assert {:error, error} = Codec.encode(Pack.new([]), [])
      assert error.code == :missing_path
      assert error.message =~ "carries no names"
    end

    test "decode refuses without one" do
      assert {:error, %{code: :missing_path}} = Codec.decode(<<>>, [])
    end

    test "rejects something that is not a path" do
      assert {:error, %{code: :missing_path}} = Codec.decode(<<>>, path: "/3/0")
    end
  end

  describe "encode/2 — structure follows the request path" do
    test "an Object Instance path emits bare Resources" do
      pack = Pack.new([%Record{name: "/3/0/9", number_value: 87}])

      assert hex(pack, path: path!("/3/0"), model: device_model()) == "C10957"
    end

    test "an Object path wraps each Instance" do
      pack =
        Pack.new([
          %Record{name: "/3/0/9", number_value: 87},
          %Record{name: "/3/1/9", number_value: 88}
        ])

      assert hex(pack, path: path!("/3"), model: device_model()) == "0300C109570301C10958"
    end

    test "a Resource path emits one Resource entry" do
      pack = Pack.new([%Record{name: "/3/0/9", number_value: 87}])

      assert hex(pack, path: path!("/3/0/9"), model: device_model()) == "C10957"
    end

    test "a Resource with Instances becomes a multiple Resource" do
      pack =
        Pack.new([
          %Record{name: "/3/0/6/0", number_value: 1},
          %Record{name: "/3/0/6/1", number_value: 5}
        ])

      assert hex(pack, path: path!("/3/0"), model: device_model()) == "8606410001410105"
    end

    test "a Resource Instance path emits one Resource Instance entry" do
      pack = Pack.new([%Record{name: "/3/0/6/0", number_value: 1}])

      assert hex(pack, path: path!("/3/0/6/0"), model: device_model()) == "410001"
    end

    test "entries are ordered by ID, whatever order the pack arrived in" do
      pack =
        Pack.new([
          %Record{name: "/3/0/9", number_value: 87},
          %Record{name: "/3/0/0", string_value: "ACME"}
        ])

      assert "C40041434D45C10957" = hex(pack, path: path!("/3/0"), model: device_model())
    end
  end

  describe "encode/2 — values" do
    test "each declared type takes its TLV encoding" do
      model =
        Registry.from_definitions([
          %Definition{
            object_id: 9,
            name: "Types",
            multiple_instances: :single,
            mandatory: :optional,
            resources: [
              resource(0, :string),
              resource(1, :integer),
              resource(2, :float),
              resource(3, :boolean),
              resource(4, :opaque),
              resource(5, :time),
              resource(6, :objlnk),
              resource(7, :unsigned_integer),
              resource(8, :core_link)
            ]
          }
        ])

      pack =
        Pack.new([
          %Record{name: "/9/0/1", number_value: 87},
          %Record{name: "/9/0/2", number_value: 22.5},
          %Record{name: "/9/0/3", boolean_value: true},
          %Record{name: "/9/0/5", number_value: 1_700_000_000},
          %Record{name: "/9/0/6", object_link_value: "3:0"},
          %Record{name: "/9/0/7", number_value: 200}
        ])

      assert hex(pack, path: path!("/9/0"), model: model) ==
               "C10157" <>
                 "C802084036800000000000" <>
                 "C10301" <>
                 "C4056553F100" <>
                 "C40600030000" <>
                 "C20700C8"
    end

    test "a float Resource sent a whole number still encodes as a float" do
      model =
        Registry.from_definitions([
          %Definition{
            object_id: 9,
            name: "Types",
            multiple_instances: :single,
            mandatory: :optional,
            resources: [resource(0, :float)]
          }
        ])

      pack = Pack.new([%Record{name: "/9/0/0", number_value: 22}])

      assert hex(pack, path: path!("/9/0"), model: model) == "C80008" <> "4036000000000000"
    end

    test "an Execute-style Resource with no value encodes as zero bytes" do
      pack = Pack.new([%Record{name: "/3/0/4"}])

      assert hex(pack, path: path!("/3/0")) == "C004"
    end

    test "an unencodable value is an error, not a raise" do
      model =
        Registry.from_definitions([
          %Definition{
            object_id: 9,
            name: "Types",
            multiple_instances: :single,
            mandatory: :optional,
            resources: [resource(0, :integer)]
          }
        ])

      pack = Pack.new([%Record{name: "/9/0/0", string_value: "not a number"}])

      assert {:error, error} = Codec.encode(pack, path: path!("/9/0"), model: model)
      assert error.code == :unencodable_value
      assert error.meta.path == "/9/0/0"
      assert error.meta.type == :integer
    end

    test "a malformed objlnk string is an error" do
      model =
        Registry.from_definitions([
          %Definition{
            object_id: 9,
            name: "Types",
            multiple_instances: :single,
            mandatory: :optional,
            resources: [resource(0, :objlnk)]
          }
        ])

      pack = Pack.new([%Record{name: "/9/0/0", object_link_value: "not-an-objlnk"}])

      assert {:error, %{code: :unencodable_value}} =
               Codec.encode(pack, path: path!("/9/0"), model: model)
    end
  end

  describe "encode/2 without a model" do
    test "falls back to the record's own shape" do
      pack =
        Pack.new([
          %Record{name: "/3/0/9", number_value: 87},
          %Record{name: "/3/0/0", string_value: "ACME"}
        ])

      assert hex(pack, path: path!("/3/0")) == "C40041434D45C10957"
    end

    test "a float record still encodes as a float" do
      pack = Pack.new([%Record{name: "/3/0/9", number_value: 22.5}])

      assert hex(pack, path: path!("/3/0")) == "C809084036800000000000"
    end
  end

  describe "decode/2" do
    test "names every value with its absolute path" do
      {:ok, pack} =
        Codec.decode(Base.decode16!("C10957"), path: path!("/3/0"), model: device_model())

      assert [%Record{name: "/3/0/9", number_value: 87}] = pack.records
    end

    test "expands Object Instance entries" do
      {:ok, pack} =
        Codec.decode(Base.decode16!("0300C10957"), path: path!("/3"), model: device_model())

      assert [%Record{name: "/3/0/9", number_value: 87}] = pack.records
    end

    test "expands multiple Resources into Resource Instances" do
      {:ok, pack} =
        Codec.decode(Base.decode16!("8606410001410105"),
          path: path!("/3/0"),
          model: device_model()
        )

      assert [
               %Record{name: "/3/0/6/0", number_value: 1},
               %Record{name: "/3/0/6/1", number_value: 5}
             ] = pack.records
    end

    test "types each value from the model" do
      model =
        Registry.from_definitions([
          %Definition{
            object_id: 9,
            name: "Types",
            multiple_instances: :single,
            mandatory: :optional,
            resources: [
              resource(0, :string),
              resource(1, :boolean),
              resource(2, :objlnk),
              resource(3, :float)
            ]
          }
        ])

      bytes =
        Wick.Tlv.encode([
          %Wick.Tlv{type: :resource, id: 0, value: "ACME"},
          %Wick.Tlv{type: :resource, id: 1, value: <<1>>},
          %Wick.Tlv{type: :resource, id: 2, value: <<0, 3, 0, 0>>},
          %Wick.Tlv{type: :resource, id: 3, value: <<22.5::float-64>>}
        ])
        |> IO.iodata_to_binary()

      {:ok, pack} = Codec.decode(bytes, path: path!("/9/0"), model: model)

      assert [
               %Record{name: "/9/0/0", string_value: "ACME"},
               %Record{name: "/9/0/1", boolean_value: true},
               %Record{name: "/9/0/2", object_link_value: "3:0"},
               %Record{name: "/9/0/3", number_value: 22.5}
             ] = pack.records
    end

    test "without a model every value comes back opaque, with its bytes intact" do
      {:ok, pack} = Codec.decode(Base.decode16!("C10957"), path: path!("/3/0"))

      assert [%Record{name: "/3/0/9", opaque_value: <<87>>, number_value: nil}] = pack.records
    end

    test "a value the model cannot type is opaque rather than a guess" do
      {:ok, pack} =
        Codec.decode(Base.decode16!("C1FF57"), path: path!("/3/0"), model: device_model())

      assert [%Record{name: "/3/0/255", opaque_value: <<87>>}] = pack.records
    end

    test "propagates a malformed payload" do
      assert {:error, %{code: :malformed_tlv}} =
               Codec.decode(Base.decode16!("C109"), path: path!("/3/0"))
    end

    test "a value of the wrong length for its declared type is an error" do
      # Three bytes cannot be a float.
      model =
        Registry.from_definitions([
          %Definition{
            object_id: 9,
            name: "Types",
            multiple_instances: :single,
            mandatory: :optional,
            resources: [resource(0, :float)]
          }
        ])

      assert {:error, %{code: :malformed_tlv}} =
               Codec.decode(Base.decode16!("C300010203"), path: path!("/9/0"), model: model)
    end
  end

  describe "round-trips" do
    test "the §4.3.1 device example survives decode then encode" do
      bytes =
        Base.decode16!(
          "C800144F70656E204D6F62696C6520416C6C69616E6365C801164C69676874776569676874204D324D20436C69656E74C80209333435303030313233C303312E30860641000141010588070842000ED842011388870841007D42010384C10964C10A0F830B410000C40D5182428FC60E2B30323A3030C11055"
        )

      opts = [path: path!("/3/0"), model: device_model()]

      assert {:ok, pack} = Codec.decode(bytes, opts)
      assert {:ok, reencoded} = Codec.encode(pack, opts)
      assert IO.iodata_to_binary(reencoded) == bytes
    end

    test "a tree survives tree -> pack -> TLV -> pack -> tree" do
      tree =
        Tree.from_map(%{
          3 => %{
            0 => %{
              0 => {:string, "ACME"},
              9 => {:integer, 87},
              13 => {:time, 1_700_000_000}
            }
          }
        })

      model = device_model()
      opts = [path: path!("/3/0"), model: model]

      pack = Tree.to_pack(tree, [path!("/3/0")])
      assert {:ok, encoded} = Codec.encode(pack, opts)
      assert {:ok, decoded} = Codec.decode(IO.iodata_to_binary(encoded), opts)
      assert {:ok, rebuilt} = Tree.apply_pack(Tree.new(), decoded, model: model)

      assert Tree.subtree(rebuilt, path!("/3/0")) == Tree.subtree(tree, path!("/3/0"))
    end

    test "a multi-instance Resource survives the same trip" do
      tree = Tree.new() |> Tree.create_instance(3, 0)
      tree = Tree.put(tree, path!("/3/0/6/0"), {:integer, 1})
      tree = Tree.put(tree, path!("/3/0/6/1"), {:integer, 5})

      model = device_model()
      opts = [path: path!("/3/0"), model: model]

      pack = Tree.to_pack(tree, [path!("/3/0")])
      assert {:ok, encoded} = Codec.encode(pack, opts)
      assert {:ok, decoded} = Codec.decode(IO.iodata_to_binary(encoded), opts)
      assert {:ok, rebuilt} = Tree.apply_pack(Tree.new(), decoded, model: model)

      assert Tree.subtree(rebuilt, path!("/3/0")) == Tree.subtree(tree, path!("/3/0"))
    end
  end
end

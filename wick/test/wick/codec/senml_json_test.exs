defmodule Wick.Codec.SenmlJsonTest do
  use ExUnit.Case, async: true

  alias Wick.Codec.SenmlJson
  alias Wick.Error
  alias Wick.Senml.Pack
  alias Wick.Senml.Record

  doctest SenmlJson

  describe "content_format/0" do
    test "is the IANA-registered SenML JSON Content-Format integer" do
      assert SenmlJson.content_format() == 110
    end
  end

  describe "encode/2 — empty pack" do
    test "an empty pack encodes as the empty array" do
      assert {:ok, "[]"} = SenmlJson.encode(Pack.new([]))
    end
  end

  describe "encode/2 — single value records" do
    test "encodes a single integer-value record" do
      pack = Pack.new([%Record{name: "/3/0/9", number_value: 87}])
      assert {:ok, ~s|[{"n":"/3/0/9","v":87}]|} = SenmlJson.encode(pack)
    end

    test "encodes a single string-value record" do
      pack = Pack.new([%Record{name: "/3/0/0", string_value: "Open Mobile Alliance"}])
      assert {:ok, ~s|[{"n":"/3/0/0","vs":"Open Mobile Alliance"}]|} = SenmlJson.encode(pack)
    end

    test "encodes a boolean-true record" do
      pack = Pack.new([%Record{name: "/3303/0/5601", boolean_value: true}])
      assert {:ok, ~s|[{"n":"/3303/0/5601","vb":true}]|} = SenmlJson.encode(pack)
    end

    test "encodes a boolean-false record" do
      pack = Pack.new([%Record{name: "/3303/0/5601", boolean_value: false}])
      assert {:ok, ~s|[{"n":"/3303/0/5601","vb":false}]|} = SenmlJson.encode(pack)
    end

    test "encodes an opaque-value record using base64 with padding" do
      pack = Pack.new([%Record{name: "/3/0/3", opaque_value: <<0xDE, 0xAD, 0xBE, 0xEF>>}])
      assert {:ok, ~s|[{"n":"/3/0/3","vd":"3q2+7w=="}]|} = SenmlJson.encode(pack)
    end

    test "encodes an objlnk-value record" do
      pack = Pack.new([%Record{name: "/3/0/14", object_link_value: "1:0"}])
      assert {:ok, ~s|[{"n":"/3/0/14","vlo":"1:0"}]|} = SenmlJson.encode(pack)
    end

    test "encodes a float-value record using shortest decimal form" do
      pack = Pack.new([%Record{name: "/3303/0/5700", number_value: 1.5}])
      assert {:ok, ~s|[{"n":"/3303/0/5700","v":1.5}]|} = SenmlJson.encode(pack)
    end
  end

  describe "encode/2 — base-prefix fields" do
    test "emits map keys in Leshan declaration order — bn before n" do
      pack = Pack.new([%Record{base_name: "/3/0/", name: "9", number_value: 87}])
      assert {:ok, ~s|[{"bn":"/3/0/","n":"9","v":87}]|} = SenmlJson.encode(pack)
    end

    test "declaration order with base_time — bn, bt, n, v" do
      pack =
        Pack.new([
          %Record{base_name: "/3/0/", base_time: 1_700_000_000, name: "9", number_value: 87}
        ])

      assert {:ok, ~s|[{"bn":"/3/0/","bt":1700000000,"n":"9","v":87}]|} = SenmlJson.encode(pack)
    end

    test "skips empty base_name and empty name (Leshan isEmpty parity)" do
      pack = Pack.new([%Record{base_name: "", name: "", number_value: 5}])
      assert {:ok, ~s|[{"v":5}]|} = SenmlJson.encode(pack)
    end
  end

  describe "encode/2 — multi-record pack" do
    test "encodes a two-record pack as an array of two objects" do
      r1 = %Record{name: "/3/0/0", string_value: "Manufacturer"}
      r2 = %Record{name: "/3/0/9", number_value: 87}
      pack = Pack.new([r1, r2])

      assert {:ok, ~s|[{"n":"/3/0/0","vs":"Manufacturer"},{"n":"/3/0/9","v":87}]|} =
               SenmlJson.encode(pack)
    end
  end

  describe "encode/2 — error paths" do
    test "returns :missing_value for a record with no value field, by default" do
      pack = Pack.new([%Record{name: "/3/0/9"}])

      assert {:error, %Error{code: :missing_value, meta: %{index: 0}}} =
               SenmlJson.encode(pack)
    end

    test "allow_no_value: true emits records with metadata only" do
      pack = Pack.new([%Record{name: "/3/0/9"}])
      assert {:ok, ~s|[{"n":"/3/0/9"}]|} = SenmlJson.encode(pack, allow_no_value: true)
    end
  end

  describe "decode/2 — happy paths" do
    test "decodes a single integer-value record" do
      assert {:ok, %Pack{records: [r]}} = SenmlJson.decode(~s|[{"n":"/3/0/9","v":87}]|)
      assert r.name == "/3/0/9"
      assert r.number_value == 87
    end

    test "decodes a single string-value record" do
      assert {:ok, %Pack{records: [r]}} = SenmlJson.decode(~s|[{"n":"/3/0/0","vs":"hello"}]|)
      assert r.string_value == "hello"
    end

    test "decodes boolean-value records (both true and false)" do
      assert {:ok, %Pack{records: [%{boolean_value: true}]}} =
               SenmlJson.decode(~s|[{"n":"x","vb":true}]|)

      assert {:ok, %Pack{records: [%{boolean_value: false}]}} =
               SenmlJson.decode(~s|[{"n":"x","vb":false}]|)
    end

    test "decodes opaque values via base64 → raw bytes" do
      assert {:ok, %Pack{records: [r]}} =
               SenmlJson.decode(~s|[{"n":"/3/0/3","vd":"3q2+7w=="}]|)

      assert r.opaque_value == <<0xDE, 0xAD, 0xBE, 0xEF>>
    end

    test "decodes objlnk values" do
      assert {:ok, %Pack{records: [r]}} =
               SenmlJson.decode(~s|[{"n":"/3/0/14","vlo":"1:0"}]|)

      assert r.object_link_value == "1:0"
    end

    test "decodes float values" do
      assert {:ok, %Pack{records: [r]}} =
               SenmlJson.decode(~s|[{"n":"/3303/0/5700","v":1.5}]|)

      assert r.number_value == 1.5
    end

    test "decodes base_name and base_time fields" do
      json = ~s|[{"bn":"/3/0/","bt":1700000000,"n":"9","v":87}]|
      assert {:ok, %Pack{records: [r]}} = SenmlJson.decode(json)
      assert r.base_name == "/3/0/"
      assert r.base_time == 1_700_000_000
      assert r.name == "9"
      assert r.number_value == 87
    end

    test "decodes a multi-record pack preserving order" do
      json = ~s|[{"n":"a","v":1},{"n":"b","v":2}]|
      assert {:ok, %Pack{records: [r1, r2]}} = SenmlJson.decode(json)
      assert r1.name == "a"
      assert r2.name == "b"
    end

    test "decodes the empty pack" do
      assert {:ok, %Pack{records: []}} = SenmlJson.decode("[]")
    end

    test "decodes a record with no value field" do
      assert {:ok, %Pack{records: [r]}} = SenmlJson.decode(~s|[{"n":"/3/0/9"}]|)
      assert r.name == "/3/0/9"
      assert Wick.Senml.Record.value_type(r) == :none
    end
  end

  describe "decode/2 — round-trips" do
    test "encode/decode is the identity for every value type variant" do
      packs = [
        Pack.new([%Record{name: "i", number_value: 87}]),
        Pack.new([%Record{name: "f", number_value: 1.5}]),
        Pack.new([%Record{name: "n", number_value: -123}]),
        Pack.new([%Record{name: "s", string_value: "hello"}]),
        Pack.new([%Record{name: "b", boolean_value: true}]),
        Pack.new([%Record{name: "o", opaque_value: <<1, 2, 3>>}]),
        Pack.new([%Record{name: "l", object_link_value: "1:0"}]),
        Pack.new([%Record{base_name: "/3/0/", name: "9", number_value: 87}])
      ]

      for pack <- packs do
        {:ok, encoded} = SenmlJson.encode(pack)
        {:ok, decoded} = SenmlJson.decode(encoded)
        assert decoded == pack, "round-trip mismatch for #{inspect(pack)}"
      end
    end
  end

  describe "decode/2 — Leshan oracle interop" do
    @moduletag :oracle

    @fixtures Path.expand("../../fixtures/senml_json", __DIR__)

    test "decodes every shipped Leshan SenML JSON fixture" do
      bins =
        @fixtures
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".bin"))

      for name <- bins do
        bytes = File.read!(Path.join(@fixtures, name))

        assert {:ok, %Pack{}} = SenmlJson.decode(bytes), "decoder failed on #{name}"
      end
    end

    test "decodes 09_base_name_plus_base_time correctly" do
      bytes = File.read!(Path.join(@fixtures, "09_base_name_plus_base_time.bin"))

      assert {:ok, %Pack{records: [r]}} = SenmlJson.decode(bytes)
      assert r.base_name == "/3/0/"
      assert r.base_time == 1_700_000_000
      assert r.number_value == 87
    end

    test "decodes 05_opaque_record (base64 → raw bytes)" do
      bytes = File.read!(Path.join(@fixtures, "05_opaque_record.bin"))

      assert {:ok, %Pack{records: [r]}} = SenmlJson.decode(bytes)
      assert r.opaque_value == <<0xDE, 0xAD, 0xBE, 0xEF>>
    end
  end

  describe "decode/2 — error paths" do
    test ":malformed_json for invalid JSON input" do
      assert {:error, %Error{code: :malformed_json}} = SenmlJson.decode("not json")
    end

    test ":malformed_senml when the top-level JSON is not an array" do
      assert {:error, %Error{code: :malformed_senml, meta: %{got: :map}}} =
               SenmlJson.decode("{}")

      assert {:error, %Error{code: :malformed_senml, meta: %{got: :integer}}} =
               SenmlJson.decode("87")

      assert {:error, %Error{code: :malformed_senml, meta: %{got: :float}}} =
               SenmlJson.decode("1.5")

      assert {:error, %Error{code: :malformed_senml, meta: %{got: :boolean}}} =
               SenmlJson.decode("true")

      assert {:error, %Error{code: :malformed_senml, meta: %{got: nil}}} =
               SenmlJson.decode("null")

      assert {:error, %Error{code: :malformed_senml, meta: %{got: :binary}}} =
               SenmlJson.decode(~s|"hello"|)
    end

    test ":malformed_senml when a record is not an object" do
      assert {:error, %Error{code: :malformed_senml}} = SenmlJson.decode("[1]")
    end

    test ":malformed_senml when a text field carries a number" do
      assert {:error, %Error{code: :malformed_senml, message: msg}} =
               SenmlJson.decode(~s|[{"n":87}]|)

      assert msg =~ "expected text"
    end

    test ":malformed_senml when a number field carries text" do
      assert {:error, %Error{code: :malformed_senml, message: msg}} =
               SenmlJson.decode(~s|[{"v":"hello"}]|)

      assert msg =~ "expected number"
    end

    test ":malformed_senml when a boolean field carries an integer" do
      assert {:error, %Error{code: :malformed_senml, message: msg}} =
               SenmlJson.decode(~s|[{"vb":1}]|)

      assert msg =~ "expected boolean"
    end

    test ":malformed_senml for invalid base64 in vd" do
      assert {:error, %Error{code: :malformed_senml, message: msg}} =
               SenmlJson.decode(~s|[{"vd":"not!base64!"}]|)

      assert msg =~ "base64"
    end

    test ":malformed_senml when vd is not a string" do
      assert {:error, %Error{code: :malformed_senml, message: msg}} =
               SenmlJson.decode(~s|[{"vd":42}]|)

      assert msg =~ "expected base64"
    end
  end
end

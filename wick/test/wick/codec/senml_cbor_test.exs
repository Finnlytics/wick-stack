defmodule Wick.Codec.SenmlCborTest do
  use ExUnit.Case, async: true

  alias Wick.Codec.SenmlCbor
  alias Wick.Error
  alias Wick.Senml.Pack
  alias Wick.Senml.Record

  doctest SenmlCbor

  describe "content_format/0" do
    test "is the IANA-registered SenML CBOR Content-Format integer" do
      assert SenmlCbor.content_format() == 112
    end
  end

  describe "encode/2 — empty pack" do
    test "encodes an empty pack as the empty array 0x80" do
      assert {:ok, <<0x80>>} = SenmlCbor.encode(Pack.new([]))
    end
  end

  describe "encode/2 — single value records" do
    # 81           array(1)
    # A2           map(2)
    #   00         key 0 (n)
    #   66 …       text "/3/0/9" (length 6)
    #   02         key 2 (v)
    #   18 57      uint8 87
    test "encodes a single integer-value record" do
      pack = Pack.new([%Record{name: "/3/0/9", number_value: 87}])
      assert {:ok, bytes} = SenmlCbor.encode(pack)
      assert Base.encode16(bytes) == "81A200662F332F302F39021857"
    end

    # 81 A2 00 66 "/3/0/0" 03 74 "Open Mobile Alliance"
    test "encodes a single string-value record" do
      pack = Pack.new([%Record{name: "/3/0/0", string_value: "Open Mobile Alliance"}])
      assert {:ok, bytes} = SenmlCbor.encode(pack)

      assert Base.encode16(bytes) ==
               "81A200662F332F302F300374" <> Base.encode16("Open Mobile Alliance")
    end

    # 81 A2 00 6C "/3303/0/5601" 04 F5
    test "encodes a boolean-value record (true)" do
      pack = Pack.new([%Record{name: "/3303/0/5601", boolean_value: true}])
      assert {:ok, bytes} = SenmlCbor.encode(pack)
      assert Base.encode16(bytes) == "81A2006C2F333330332F302F3536303104F5"
    end

    test "encodes a boolean-value record (false)" do
      pack = Pack.new([%Record{name: "/3303/0/5601", boolean_value: false}])
      assert {:ok, bytes} = SenmlCbor.encode(pack)
      assert String.ends_with?(Base.encode16(bytes), "04F4")
    end

    # 81 A2 00 66 "/3/0/3" 08 44 DE AD BE EF
    test "encodes an opaque-value record (CBOR major type 2)" do
      pack = Pack.new([%Record{name: "/3/0/3", opaque_value: <<0xDE, 0xAD, 0xBE, 0xEF>>}])
      assert {:ok, bytes} = SenmlCbor.encode(pack)
      assert Base.encode16(bytes) == "81A200662F332F302F330844DEADBEEF"
    end

    # 81 A2 00 67 "/3/0/14" 63 "vlo" 63 "1:0"
    # objlnk uses the string key "vlo", not an integer label.
    test "encodes an objlnk-value record with the string key 'vlo'" do
      pack = Pack.new([%Record{name: "/3/0/14", object_link_value: "1:0"}])
      assert {:ok, bytes} = SenmlCbor.encode(pack)
      assert Base.encode16(bytes) == "81A200672F332F302F313463766C6F63313A30"
    end

    # ... 02 F9 3E 00   key v=2, then float16 1.5 (RFC 8949 §4.2.1 shortest form)
    test "encodes a float-value record using shortest-form float" do
      pack = Pack.new([%Record{name: "/3303/0/5700", number_value: 1.5}])
      assert {:ok, bytes} = SenmlCbor.encode(pack)
      assert String.ends_with?(Base.encode16(bytes), "02F93E00")
    end
  end

  describe "encode/2 — base-prefix fields" do
    # 81 A3                              array(1), map(3)
    #    00 61 "9"                       n      = "9"
    #    02 18 57                        v      = 87
    #    21 65 "/3/0/"                   bn     = "/3/0/"
    # Canonical CBOR key order: 0x00 < 0x02 < 0x21.
    test "emits map keys in canonical CBOR order — n, v, bn" do
      pack = Pack.new([%Record{base_name: "/3/0/", name: "9", number_value: 87}])
      assert {:ok, bytes} = SenmlCbor.encode(pack)
      assert Base.encode16(bytes) == "81A300613902185721652F332F302F"
    end

    # 81 A4                              array(1), map(4)
    #    00 61 "9"                       n      = "9"
    #    02 18 57                        v      = 87
    #    21 65 "/3/0/"                   bn     = "/3/0/"
    #    22 1A 65 53 F1 00               bt     = 1_700_000_000 (plain uint32; ADR 0003)
    # Canonical CBOR key order: 0x00 < 0x02 < 0x21 < 0x22.
    test "canonical key order with base_time present — n, v, bn, bt" do
      pack =
        Pack.new([
          %Record{base_name: "/3/0/", base_time: 1_700_000_000, name: "9", number_value: 87}
        ])

      assert {:ok, bytes} = SenmlCbor.encode(pack)
      assert Base.encode16(bytes) == "81A400613902185721652F332F302F221A6553F100"
    end

    # Map has only the value field — no n, no bn — when both empty.
    # 81 A1 02 05  →  array(1), map(1), key 2, value 5.
    test "skips empty base_name and empty name (matches Leshan isEmpty)" do
      pack = Pack.new([%Record{base_name: "", name: "", number_value: 5}])
      assert {:ok, bytes} = SenmlCbor.encode(pack)
      assert Base.encode16(bytes) == "81A10205"
    end

    test "treats nil base_name and empty base_name identically (both omitted)" do
      with_nil = Pack.new([%Record{base_name: nil, name: "n", number_value: 1}])
      with_empty = Pack.new([%Record{base_name: "", name: "n", number_value: 1}])

      assert SenmlCbor.encode(with_nil) == SenmlCbor.encode(with_empty)
    end
  end

  describe "encode/2 — value precedence (Leshan parity)" do
    test "boolean wins over number when both happen to be set" do
      pack = Pack.new([%Record{name: "x", boolean_value: true, number_value: 5}])
      assert {:ok, bytes} = SenmlCbor.encode(pack)
      assert String.ends_with?(Base.encode16(bytes), "04F5")
      refute Base.encode16(bytes) =~ "0205"
    end
  end

  describe "encode/2 — multi-record pack" do
    # 82
    #   A2 00 66 "/3/0/0" 03 6C "Manufacturer"
    #   A2 00 66 "/3/0/9" 02 18 57
    test "encodes a two-record pack as an array of two maps" do
      r1 = %Record{name: "/3/0/0", string_value: "Manufacturer"}
      r2 = %Record{name: "/3/0/9", number_value: 87}
      pack = Pack.new([r1, r2])

      assert {:ok, bytes} = SenmlCbor.encode(pack)

      assert Base.encode16(bytes) ==
               "82A200662F332F302F30036C4D616E7566616374757265" <>
                 "72A200662F332F302F39021857"
    end
  end

  describe "encode/2 — error paths" do
    test "returns :missing_value for a record with no value field, by default" do
      pack = Pack.new([%Record{name: "/3/0/9"}])

      assert {:error, %Error{code: :missing_value, meta: %{index: 0}}} =
               SenmlCbor.encode(pack)
    end

    test "the missing_value error reports the index of the offending record" do
      r0 = %Record{name: "/3/0/0", string_value: "ok"}
      r1 = %Record{name: "/3/0/9"}
      pack = Pack.new([r0, r1])

      assert {:error, %Error{code: :missing_value, meta: %{index: 1}}} =
               SenmlCbor.encode(pack)
    end

    test "allow_no_value: true emits records with metadata only" do
      pack = Pack.new([%Record{name: "/3/0/9"}])

      assert {:ok, bytes} = SenmlCbor.encode(pack, allow_no_value: true)
      # 81 A1 00 66 "/3/0/9" — array(1), map(1), key 0, name "/3/0/9"
      assert Base.encode16(bytes) == "81A100662F332F302F39"
    end
  end

  describe "decode/2 — happy paths" do
    test "decodes a single integer-value record" do
      pack = Pack.new([%Record{name: "/3/0/9", number_value: 87}])
      {:ok, encoded} = SenmlCbor.encode(pack)

      assert {:ok, %Pack{records: [decoded]}} = SenmlCbor.decode(encoded)
      assert decoded.name == "/3/0/9"
      assert decoded.number_value == 87
    end

    test "decodes a single string-value record" do
      pack = Pack.new([%Record{name: "/3/0/0", string_value: "hello"}])
      {:ok, encoded} = SenmlCbor.encode(pack)

      assert {:ok, %Pack{records: [decoded]}} = SenmlCbor.decode(encoded)
      assert decoded.string_value == "hello"
    end

    test "decodes a boolean-value record (both true and false)" do
      {:ok, b1} = SenmlCbor.encode(Pack.new([%Record{name: "x", boolean_value: true}]))
      {:ok, b2} = SenmlCbor.encode(Pack.new([%Record{name: "x", boolean_value: false}]))

      assert {:ok, %Pack{records: [%Record{boolean_value: true}]}} = SenmlCbor.decode(b1)
      assert {:ok, %Pack{records: [%Record{boolean_value: false}]}} = SenmlCbor.decode(b2)
    end

    test "decodes opaque bytes (CBOR major type 2 → :opaque_value field)" do
      pack = Pack.new([%Record{name: "x", opaque_value: <<0xDE, 0xAD>>}])
      {:ok, encoded} = SenmlCbor.encode(pack)

      assert {:ok, %Pack{records: [%Record{opaque_value: <<0xDE, 0xAD>>}]}} =
               SenmlCbor.decode(encoded)
    end

    test "decodes objlnk values from the 'vlo' string key" do
      pack = Pack.new([%Record{name: "x", object_link_value: "1:0"}])
      {:ok, encoded} = SenmlCbor.encode(pack)

      assert {:ok, %Pack{records: [%Record{object_link_value: "1:0"}]}} =
               SenmlCbor.decode(encoded)
    end

    test "decodes float values" do
      pack = Pack.new([%Record{name: "x", number_value: 1.5}])
      {:ok, encoded} = SenmlCbor.encode(pack)

      assert {:ok, %Pack{records: [%Record{number_value: 1.5}]}} = SenmlCbor.decode(encoded)
    end

    test "decodes base_name and base_time" do
      pack =
        Pack.new([
          %Record{base_name: "/3/0/", base_time: 1_700_000_000, name: "9", number_value: 87}
        ])

      {:ok, encoded} = SenmlCbor.encode(pack)

      assert {:ok, %Pack{records: [decoded]}} = SenmlCbor.decode(encoded)
      assert decoded.base_name == "/3/0/"
      assert decoded.base_time == 1_700_000_000
      assert decoded.name == "9"
      assert decoded.number_value == 87
    end

    test "decodes a multi-record pack preserving order" do
      pack =
        Pack.new([
          %Record{name: "a", number_value: 1},
          %Record{name: "b", number_value: 2}
        ])

      {:ok, encoded} = SenmlCbor.encode(pack)

      assert {:ok, %Pack{records: [r1, r2]}} = SenmlCbor.decode(encoded)
      assert r1.name == "a"
      assert r2.name == "b"
    end

    test "decodes the empty pack" do
      assert {:ok, %Pack{records: []}} = SenmlCbor.decode(<<0x80>>)
    end

    test "decodes a record with no value field (Read-Composite shape)" do
      pack = Pack.new([%Record{name: "/3/0/9"}])
      {:ok, encoded} = SenmlCbor.encode(pack, allow_no_value: true)

      assert {:ok, %Pack{records: [%Record{name: "/3/0/9"}]}} = SenmlCbor.decode(encoded)
    end
  end

  describe "decode/2 — encode/decode round-trips on every value type" do
    test "round-trips for every value type variant" do
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
        {:ok, encoded} = SenmlCbor.encode(pack)
        {:ok, decoded} = SenmlCbor.decode(encoded)
        assert decoded == pack, "round-trip mismatch for #{inspect(pack)}"
      end
    end
  end

  describe "decode/2 — Leshan oracle interop" do
    @moduletag :oracle

    @fixtures Path.expand("../../fixtures/senml_cbor", __DIR__)

    test "decodes 01_int_record (Leshan-emitted)" do
      bytes = File.read!(Path.join(@fixtures, "01_int_record.bin"))

      assert {:ok, %Pack{records: [%Record{name: "/3/0/9", number_value: 87}]}} =
               SenmlCbor.decode(bytes)
    end

    test "decodes 09_base_name_plus_base_time — tag-4 time becomes plain integer (ADR 0003)" do
      bytes = File.read!(Path.join(@fixtures, "09_base_name_plus_base_time.bin"))

      assert {:ok, %Pack{records: [r]}} = SenmlCbor.decode(bytes)
      assert r.base_name == "/3/0/"
      assert r.base_time == 1_700_000_000
      assert is_integer(r.base_time)
      assert r.name == "9"
      assert r.number_value == 87
    end

    test "decodes every shipped Leshan fixture without error" do
      bins =
        @fixtures
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".bin"))
        |> Enum.reject(&String.ends_with?(&1, ".wick.bin"))

      for name <- bins do
        bytes = File.read!(Path.join(@fixtures, name))

        assert {:ok, %Pack{}} = SenmlCbor.decode(bytes),
               "decoder failed on #{name}"
      end
    end
  end

  describe "decode/2 — error paths" do
    test ":malformed_cbor for invalid CBOR input" do
      assert {:error, %Error{code: :malformed_cbor}} = SenmlCbor.decode(<<0xFF>>)
    end

    test ":malformed_senml when top-level CBOR is not an array" do
      # Single integer 5
      assert {:error, %Error{code: :malformed_senml}} = SenmlCbor.decode(<<0x05>>)
    end

    test ":malformed_senml when a record entry is not a map" do
      # Array containing the integer 5
      assert {:error, %Error{code: :malformed_senml}} = SenmlCbor.decode(<<0x81, 0x05>>)
    end

    test ":malformed_senml when a text field carries an integer" do
      # Array of map { 0 => 87 } — n=0 should be text, not integer
      bytes = <<0x81, 0xA1, 0x00, 0x18, 87>>
      assert {:error, %Error{code: :malformed_senml}} = SenmlCbor.decode(bytes)
    end

    test ":malformed_senml when a text field carries bytes (specific text vs bytes mismatch)" do
      # { 0 => bytes(0xDE) } — n=0 should be text
      bytes = <<0x81, 0xA1, 0x00, 0x41, 0xDE>>
      assert {:error, %Error{code: :malformed_senml, message: msg}} = SenmlCbor.decode(bytes)
      assert msg =~ "expected text"
    end

    test ":malformed_senml when a number field carries text" do
      # { 2 => "x" } — v=2 should be a number
      bytes = <<0x81, 0xA1, 0x02, 0x61, "x">>
      assert {:error, %Error{code: :malformed_senml, message: msg}} = SenmlCbor.decode(bytes)
      assert msg =~ "expected number"
    end

    test ":malformed_senml when a boolean field carries an integer" do
      # { 4 => 1 } — vb=4 should be true/false, not 1
      bytes = <<0x81, 0xA1, 0x04, 0x01>>
      assert {:error, %Error{code: :malformed_senml, message: msg}} = SenmlCbor.decode(bytes)
      assert msg =~ "expected boolean"
    end

    test ":malformed_senml when a bytes field carries text" do
      # { 8 => "hi" } — vd=8 should be bytes, not text
      bytes = <<0x81, 0xA1, 0x08, 0x62, "hi">>
      assert {:error, %Error{code: :malformed_senml, message: msg}} = SenmlCbor.decode(bytes)
      assert msg =~ "expected bytes"
    end

    test ":malformed_senml when the top-level value is the empty text string" do
      assert {:error, %Error{code: :malformed_senml, meta: %{got: :binary}}} =
               SenmlCbor.decode(<<0x60>>)
    end

    test ":malformed_senml meta tags non-list top-level values with their type" do
      # Single integer 5
      assert {:error, %Error{meta: %{got: :integer}}} = SenmlCbor.decode(<<0x05>>)

      # Float 1.5
      assert {:error, %Error{meta: %{got: :float}}} = SenmlCbor.decode(<<0xF9, 0x3E, 0x00>>)

      # Boolean true
      assert {:error, %Error{meta: %{got: :boolean}}} = SenmlCbor.decode(<<0xF5>>)

      # Null
      assert {:error, %Error{meta: %{got: nil}}} = SenmlCbor.decode(<<0xF6>>)

      # Empty map
      assert {:error, %Error{meta: %{got: :map}}} = SenmlCbor.decode(<<0xA0>>)

      # Tagged value (passes through as {:tag, n, value})
      assert {:error, %Error{meta: %{got: :unknown}}} =
               SenmlCbor.decode(<<0xD8, 0x20, 0x60>>)
    end
  end
end

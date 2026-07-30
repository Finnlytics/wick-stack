defmodule Wick.CborTest do
  use ExUnit.Case, async: true

  alias Wick.Cbor

  doctest Cbor

  describe "encode_int/1" do
    test "encodes the immediate-value range 0..23 as a single byte" do
      for n <- 0..23 do
        bin = Cbor.encode_int(n)
        assert byte_size(bin) == 1
        <<0::3, ^n::5>> = bin
      end
    end

    test "encodes the negative immediate range -1..-24 as a single byte" do
      for n <- -1..-24//-1 do
        bin = Cbor.encode_int(n)
        assert byte_size(bin) == 1
        unsigned = -1 - n
        <<1::3, ^unsigned::5>> = bin
      end
    end

    test "round-trips the uint8 boundaries" do
      assert Cbor.encode_int(24) == <<0x18, 24>>
      assert Cbor.encode_int(255) == <<0x18, 255>>
    end

    test "round-trips the uint16 boundaries" do
      assert Cbor.encode_int(256) == <<0x19, 0x01, 0x00>>
      assert Cbor.encode_int(65_535) == <<0x19, 0xFF, 0xFF>>
    end

    test "round-trips the uint32 boundaries" do
      assert Cbor.encode_int(65_536) == <<0x1A, 0x00, 0x01, 0x00, 0x00>>
      assert Cbor.encode_int(4_294_967_295) == <<0x1A, 0xFF, 0xFF, 0xFF, 0xFF>>
    end

    test "round-trips a uint64-range value" do
      assert Cbor.encode_int(4_294_967_296) ==
               <<0x1B, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00>>
    end

    test "encodes negative ints with the -1-n shift" do
      assert Cbor.encode_int(-100) == <<0x38, 99>>
      assert Cbor.encode_int(-256) == <<0x38, 255>>
      assert Cbor.encode_int(-257) == <<0x39, 0x01, 0x00>>
    end
  end

  describe "encode_text/1" do
    test "empty string is just the head byte" do
      assert Cbor.encode_text("") == <<0x60>>
    end

    test "utf8 string carries its byte length, not character count" do
      # "café" is 5 bytes in UTF-8
      assert byte_size("café") == 5
      assert Cbor.encode_text("café") == <<0x65, "café"::binary>>
    end

    test "23-byte string still uses immediate length" do
      str = String.duplicate("a", 23)
      assert <<0x77, ^str::binary>> = Cbor.encode_text(str)
    end

    test "24-byte string uses uint8 length" do
      str = String.duplicate("a", 24)
      assert <<0x78, 24, ^str::binary>> = Cbor.encode_text(str)
    end
  end

  describe "encode_bytes/1" do
    test "empty byte string is just the head byte" do
      assert Cbor.encode_bytes(<<>>) == <<0x40>>
    end

    test "preserves arbitrary bytes" do
      assert Cbor.encode_bytes(<<0, 1, 2, 3, 0xFF>>) == <<0x45, 0, 1, 2, 3, 0xFF>>
    end
  end

  describe "encode_bool/1" do
    test "false is 0xf4, true is 0xf5" do
      assert Cbor.encode_bool(false) == <<0xF4>>
      assert Cbor.encode_bool(true) == <<0xF5>>
    end
  end

  describe "encode_float/1" do
    test "zero packs into float16" do
      assert Cbor.encode_float(0.0) == <<0xF9, 0x00, 0x00>>
    end

    test "1.0 packs into float16" do
      assert Cbor.encode_float(1.0) == <<0xF9, 0x3C, 0x00>>
    end

    test "1.5 packs into float16" do
      assert Cbor.encode_float(1.5) == <<0xF9, 0x3E, 0x00>>
    end

    test "65504.0 (max finite float16) packs into float16" do
      assert Cbor.encode_float(65_504.0) == <<0xF9, 0x7B, 0xFF>>
    end

    test "65505.0 (just outside float16) goes to float32" do
      result = Cbor.encode_float(65_505.0)
      assert <<0xFA, _::binary-size(4)>> = result
    end

    test "100.0 fits exactly in float16" do
      assert Cbor.encode_float(100.0) == <<0xF9, 0x56, 0x40>>
    end

    test "100000.0 exceeds float16 range and packs into float32" do
      assert Cbor.encode_float(100_000.0) == <<0xFA, 0x47, 0xC3, 0x50, 0x00>>
    end

    test "values requiring full float64 emit 0xfb" do
      result = Cbor.encode_float(1.1)
      assert <<0xFB, _::binary-size(8)>> = result
    end

    test "round-trip preservation: every encoded float decodes to the original value" do
      cases = [0.0, 1.0, -1.0, 1.5, 100.0, 1.1, 3.14, -3.14, 1.0e10, 1.0e-10]

      for value <- cases do
        encoded = Cbor.encode_float(value)
        decoded = decode_float_for_test(encoded)

        assert decoded == value,
               "round-trip failed for #{value}: encoded=#{Base.encode16(encoded)}, decoded=#{decoded}"
      end
    end
  end

  describe "encode_array_head/1" do
    test "empty array is 0x80" do
      assert Cbor.encode_array_head(0) == <<0x80>>
    end

    test "23-item array uses immediate length" do
      assert Cbor.encode_array_head(23) == <<0x97>>
    end

    test "24-item array uses uint8 length" do
      assert Cbor.encode_array_head(24) == <<0x98, 24>>
    end
  end

  describe "encode_map_head/1" do
    test "empty map is 0xa0" do
      assert Cbor.encode_map_head(0) == <<0xA0>>
    end

    test "3-pair map is 0xa3" do
      assert Cbor.encode_map_head(3) == <<0xA3>>
    end

    test "33-pair map crosses into uint8 length" do
      assert Cbor.encode_map_head(33) == <<0xB8, 33>>
    end
  end

  # Helper for the float round-trip test — pulls the value out of a float-tagged head byte.
  defp decode_float_for_test(<<0xF9, rest::binary-size(2)>>) do
    <<value::float-size(16)>> = rest
    value
  end

  defp decode_float_for_test(<<0xFA, rest::binary-size(4)>>) do
    <<value::float-size(32)>> = rest
    value
  end

  defp decode_float_for_test(<<0xFB, rest::binary-size(8)>>) do
    <<value::float-size(64)>> = rest
    value
  end

  describe "decode/1 — primitive round-trips" do
    test "decode is the inverse of encode_int across every width" do
      for n <- [0, 1, 23, 24, 100, 255, 256, 65_535, 65_536, 4_294_967_295, 4_294_967_296] do
        assert {:ok, ^n, ""} = Cbor.decode(Cbor.encode_int(n))
      end

      for n <- [-1, -24, -25, -100, -256, -257, -65_536, -65_537] do
        assert {:ok, ^n, ""} = Cbor.decode(Cbor.encode_int(n))
      end
    end

    test "decode is the inverse of encode_text" do
      for s <- ["", "a", "hello", "café", String.duplicate("x", 100)] do
        assert {:ok, ^s, ""} = Cbor.decode(Cbor.encode_text(s))
      end
    end

    test "decode returns byte strings as {:bytes, binary} (disambiguates from text)" do
      bytes = <<0xDE, 0xAD, 0xBE, 0xEF>>
      assert {:ok, {:bytes, ^bytes}, ""} = Cbor.decode(Cbor.encode_bytes(bytes))
    end

    test "decode booleans" do
      assert {:ok, true, ""} = Cbor.decode(Cbor.encode_bool(true))
      assert {:ok, false, ""} = Cbor.decode(Cbor.encode_bool(false))
    end

    test "null" do
      assert {:ok, nil, ""} = Cbor.decode(<<0xF6>>)
    end

    test "decode is the inverse of encode_float at every width" do
      for value <- [0.0, 1.0, 1.5, -3.14, 100.0, 100_000.0, 1.0e10, 1.0e-10] do
        assert {:ok, ^value, ""} = Cbor.decode(Cbor.encode_float(value))
      end
    end
  end

  describe "decode/1 — containers" do
    test "empty array" do
      assert {:ok, [], ""} = Cbor.decode(<<0x80>>)
    end

    test "small array of ints" do
      assert {:ok, [1, 2, 3], ""} = Cbor.decode(<<0x83, 0x01, 0x02, 0x03>>)
    end

    test "empty map" do
      assert {:ok, %{}, ""} = Cbor.decode(<<0xA0>>)
    end

    test "map with integer keys" do
      assert {:ok, %{0 => "hi", 2 => 87}, ""} =
               Cbor.decode(<<0xA2, 0x00, 0x62, "hi", 0x02, 0x18, 87>>)
    end

    test "nested array of maps (the SenML pack shape)" do
      bytes = <<0x81, 0xA1, 0x00, 0x62, "hi">>
      assert {:ok, [%{0 => "hi"}], ""} = Cbor.decode(bytes)
    end
  end

  describe "decode/1 — tags" do
    test "tag 4 decimal fraction with exponent 0 resolves to the mantissa as an integer" do
      # tag(4) [0, 1700000000]
      bytes = <<0xC4, 0x82, 0x00, 0x1A, 0x65, 0x53, 0xF1, 0x00>>
      assert {:ok, 1_700_000_000, ""} = Cbor.decode(bytes)
    end

    test "tag 4 with positive exponent multiplies into a whole integer" do
      # tag(4) [2, 5] = 5 * 10^2 = 500
      bytes = <<0xC4, 0x82, 0x02, 0x05>>
      assert {:ok, 500, ""} = Cbor.decode(bytes)
    end

    test "tag 4 with negative exponent yields a float" do
      # tag(4) [-1, 15] = 15 * 10^-1 = 1.5
      bytes = <<0xC4, 0x82, 0x20, 0x0F>>
      assert {:ok, 1.5, ""} = Cbor.decode(bytes)
    end

    test "unknown tags pass through as {:tag, n, value}" do
      # tag(32) "foo" — RFC 8949 §3.4.5.3 "URI"
      bytes = <<0xD8, 0x20, 0x63, "foo">>
      assert {:ok, {:tag, 32, "foo"}, ""} = Cbor.decode(bytes)
    end

    test "malformed tag 4 (not a 2-element array) is rejected" do
      # tag(4) "x" — not an array of [exp, mantissa]
      bytes = <<0xC4, 0x61, "x">>
      assert {:error, %Wick.Error{code: :malformed_cbor, message: msg}} = Cbor.decode(bytes)
      assert msg =~ "tag-4"
    end
  end

  describe "decode/1 — error paths" do
    test "empty input" do
      assert {:error, %Wick.Error{code: :malformed_cbor}} = Cbor.decode(<<>>)
    end

    test "truncated head" do
      assert {:error, %Wick.Error{code: :malformed_cbor}} = Cbor.decode(<<0x18>>)
    end

    test "truncated string body" do
      assert {:error, %Wick.Error{code: :malformed_cbor}} = Cbor.decode(<<0x65, "ab">>)
    end

    test "truncated float" do
      assert {:error, %Wick.Error{code: :malformed_cbor}} = Cbor.decode(<<0xF9>>)
      assert {:error, %Wick.Error{code: :malformed_cbor}} = Cbor.decode(<<0xFA, 0, 0>>)
      assert {:error, %Wick.Error{code: :malformed_cbor}} = Cbor.decode(<<0xFB, 0, 0, 0, 0>>)
    end

    test "indefinite-length items are rejected" do
      assert {:error, %Wick.Error{code: :malformed_cbor}} = Cbor.decode(<<0x9F, 0xFF>>)
    end

    test "reserved additional-info value" do
      # Additional 28 is reserved.
      assert {:error, %Wick.Error{code: :malformed_cbor}} = Cbor.decode(<<0x1C>>)
    end

    test "unsupported simple value" do
      assert {:error, %Wick.Error{code: :malformed_cbor}} = Cbor.decode(<<0xF7>>)
    end

    test "leftover bytes are returned in the rest position" do
      assert {:ok, 87, <<0xFF>>} = Cbor.decode(<<0x18, 87, 0xFF>>)
    end
  end
end

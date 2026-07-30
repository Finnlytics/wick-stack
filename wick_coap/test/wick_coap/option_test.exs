defmodule WickCoap.OptionTest do
  use ExUnit.Case, async: true

  alias WickCoap.Error
  alias WickCoap.Option

  doctest Option

  describe "from_uint/2 + value_as_uint/1 — minimal-byte uint encoding" do
    test "0 encodes as an empty value" do
      opt = Option.from_uint(14, 0)
      assert opt.value == <<>>
      assert Option.value_as_uint(opt) == 0
    end

    test "uint8 / uint16 / uint32 boundaries" do
      assert Option.from_uint(0, 1).value == <<1>>
      assert Option.from_uint(0, 255).value == <<255>>
      assert Option.from_uint(0, 256).value == <<1, 0>>
      assert Option.from_uint(0, 65_535).value == <<0xFF, 0xFF>>
      assert Option.from_uint(0, 65_536).value == <<1, 0, 0>>
      assert Option.from_uint(0, 0xFFFFFFFF).value == <<0xFF, 0xFF, 0xFF, 0xFF>>
    end

    test "round-trips arbitrary unsigned values" do
      for n <- [1, 12, 13, 14, 100, 255, 256, 269, 65_535, 65_536, 1_000_000] do
        assert Option.value_as_uint(Option.from_uint(0, n)) == n
      end
    end
  end

  describe "encode/1 — single-option blob" do
    test "Uri-Path 'rd' (delta=11, length=2)" do
      opts = [Option.new(11, "rd")]
      assert <<0xB2, ?r, ?d>> == Option.encode(opts)
    end

    test "Content-Format 112 (delta=12, length=1)" do
      opts = [Option.from_uint(12, 112)]
      assert <<0xC1, 112>> == Option.encode(opts)
    end

    test "empty option (length=0)" do
      opts = [Option.new(5)]
      assert <<0x50>> == Option.encode(opts)
    end
  end

  describe "encode/1 — multi-option blobs use deltas correctly" do
    test "two options with rising numbers (3, 11)" do
      opts = [Option.new(3, "host"), Option.new(11, "rd")]
      # Option 3: delta=3, length=4 → 0x34 + "host"
      # Option 11: delta=8, length=2 → 0x82 + "rd"
      assert <<0x34, ?h, ?o, ?s, ?t, 0x82, ?r, ?d>> == Option.encode(opts)
    end

    test "multiple Uri-Path options share the option number with delta 0" do
      # Each /3/0/9 segment is a separate Uri-Path
      opts = [Option.new(11, "3"), Option.new(11, "0"), Option.new(11, "9")]
      # First: delta=11, length=1 → 0xB1 + "3"
      # Second: delta=0, length=1 → 0x01 + "0"
      # Third: delta=0, length=1 → 0x01 + "9"
      assert <<0xB1, ?3, 0x01, ?0, 0x01, ?9>> == Option.encode(opts)
    end

    test "auto-sorts options if given out of order" do
      opts = [Option.new(11, "rd"), Option.new(3, "host")]
      assert <<0x34, ?h, ?o, ?s, ?t, 0x82, ?r, ?d>> == Option.encode(opts)
    end
  end

  describe "encode/1 — extension bytes" do
    test "delta in 13..268 uses 1-byte extension" do
      # Option 13 (= delta 13): delta_nibble=13, ext byte 0
      opts = [Option.new(13, "x")]
      assert <<0xD1, 0, ?x>> == Option.encode(opts)
    end

    test "delta in 269..65804 uses 2-byte extension" do
      # Option 270 (= delta 270): delta_nibble=14, ext = 270-269 = 1
      opts = [Option.new(270, "x")]
      assert <<0xE1, 0, 1, ?x>> == Option.encode(opts)
    end

    test "long value (length 13..268) uses 1-byte length extension" do
      value = String.duplicate("x", 50)
      opts = [Option.new(0, value)]
      # delta_nibble=0, length_nibble=13, length_ext = 50 - 13 = 37
      assert <<0x0D, 37, ^value::binary>> = Option.encode(opts)
    end
  end

  describe "decode/1 — round-trips encode/1" do
    test "empty options blob → empty list, no payload" do
      assert {:ok, [], <<>>} = Option.decode(<<>>)
    end

    test "encode then decode is identity for typical option sets" do
      cases = [
        [Option.new(11, "rd")],
        [Option.from_uint(12, 112)],
        [Option.new(3, "host"), Option.new(11, "rd")],
        [Option.new(11, "3"), Option.new(11, "0"), Option.new(11, "9")],
        [Option.from_uint(6, 0), Option.new(11, "rd")],
        [Option.new(13, "x")],
        [Option.new(270, "x")],
        # Long option value forcing the 1-byte length extension
        [Option.new(11, String.duplicate("p", 50))]
      ]

      for opts <- cases do
        encoded = Option.encode(opts)
        assert {:ok, decoded, <<>>} = Option.decode(encoded)
        assert decoded == Enum.sort_by(opts, & &1.number)
      end
    end

    test "splits payload correctly via the 0xFF marker" do
      bytes = <<0xB2, ?r, ?d, 0xFF, 1, 2, 3>>
      assert {:ok, [%Option{number: 11, value: "rd"}], <<1, 2, 3>>} = Option.decode(bytes)
    end
  end

  describe "decode/1 — error paths" do
    test "rejects truncated option header" do
      # Single byte 0xB but no data
      assert {:error, %Error{code: :malformed_option}} = Option.decode(<<0xB>>)
    end

    test "rejects truncated option value" do
      # Says length=2 but only one byte follows
      assert {:error, %Error{code: :malformed_option}} = Option.decode(<<0xB2, ?r>>)
    end

    test "rejects missing 1-byte extension" do
      # Delta nibble 13 → must be followed by an extension byte
      assert {:error, %Error{code: :malformed_option}} = Option.decode(<<0xD0>>)
    end

    test "rejects missing 2-byte extension" do
      # Delta nibble 14 → must be followed by 2 extension bytes
      assert {:error, %Error{code: :malformed_option}} = Option.decode(<<0xE0, 0>>)
    end

    test "rejects extension nibble 15 (reserved, not a real extension)" do
      # 0xFF as a *first* byte is the payload marker — handled separately. But if it
      # appears as a length nibble it's a malformed option.
      assert {:error, %Error{code: :malformed_option}} = Option.decode(<<0x0F>>)
    end
  end
end

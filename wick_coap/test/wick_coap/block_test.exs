defmodule WickCoap.BlockTest do
  use ExUnit.Case, async: true

  alias WickCoap.Block
  alias WickCoap.Error

  doctest Block

  describe "size/1" do
    test "covers SZX 0..6" do
      assert Block.size(0) == 16
      assert Block.size(1) == 32
      assert Block.size(2) == 64
      assert Block.size(3) == 128
      assert Block.size(4) == 256
      assert Block.size(5) == 512
      assert Block.size(6) == 1024
    end

    test "rejects SZX = 7 (reserved)" do
      assert_raise FunctionClauseError, fn -> Block.size(7) end
    end
  end

  describe "encode/1 and decode/1 — round-trips" do
    test "1-byte form (NUM 0..15)" do
      for num <- [0, 1, 5, 15], more <- [true, false], szx <- 0..6 do
        block = %Block{num: num, more: more, szx: szx}
        encoded = Block.encode(block)
        assert byte_size(encoded) == 1
        assert {:ok, ^block} = Block.decode(encoded)
      end
    end

    test "2-byte form (NUM 16..4095)" do
      for num <- [16, 100, 1000, 4095], more <- [true, false], szx <- 0..6 do
        block = %Block{num: num, more: more, szx: szx}
        encoded = Block.encode(block)
        assert byte_size(encoded) == 2
        assert {:ok, ^block} = Block.decode(encoded)
      end
    end

    test "3-byte form (NUM 4096..1048575)" do
      for num <- [4096, 65_536, 1_048_575], more <- [true, false], szx <- 0..6 do
        block = %Block{num: num, more: more, szx: szx}
        encoded = Block.encode(block)
        assert byte_size(encoded) == 3
        assert {:ok, ^block} = Block.decode(encoded)
      end
    end
  end

  describe "decode/1 — special cases" do
    test "empty bytes decode to NUM=0, M=false, SZX=0 (uint=0 form)" do
      assert {:ok, %Block{num: 0, more: false, szx: 0}} = Block.decode(<<>>)
    end

    test "RFC 7959 §2.2 example: NUM=0, M=true, SZX=6 (1024 byte block)" do
      # 0000 1 110 = 0x0E
      assert {:ok, %Block{num: 0, more: true, szx: 6}} = Block.decode(<<0x0E>>)
    end
  end

  describe "decode/1 — error paths" do
    test "rejects SZX = 7" do
      assert {:error, %Error{code: :malformed_block, meta: %{szx: 7}}} =
               Block.decode(<<0x07>>)
    end

    test "rejects byte sequences > 3 bytes" do
      assert {:error, %Error{code: :malformed_block}} = Block.decode(<<0, 0, 0, 0>>)
    end
  end

  describe "block1/0 and block2/0" do
    test "return the IANA-registered option numbers" do
      assert Block.block1() == 27
      assert Block.block2() == 23
    end
  end
end

defmodule WickCoap.BlockReceiverTest do
  use ExUnit.Case, async: true

  alias WickCoap.Block
  alias WickCoap.BlockReceiver
  alias WickCoap.Error

  doctest BlockReceiver

  describe "observe/3 — happy paths" do
    test "single-block transfer completes immediately" do
      r = BlockReceiver.new()
      block = %Block{num: 0, more: false, szx: 0}
      assert {:complete, "hello"} = BlockReceiver.observe(r, block, "hello")
    end

    test "in-order multi-block assembly" do
      r = BlockReceiver.new()
      b0 = %Block{num: 0, more: true, szx: 0}
      b1 = %Block{num: 1, more: true, szx: 0}
      b2 = %Block{num: 2, more: false, szx: 0}

      {:more, r} = BlockReceiver.observe(r, b0, :binary.copy("a", 16))
      {:more, r} = BlockReceiver.observe(r, b1, :binary.copy("b", 16))
      assert {:complete, payload} = BlockReceiver.observe(r, b2, "tail")

      assert payload == :binary.copy("a", 16) <> :binary.copy("b", 16) <> "tail"
    end

    test "out-of-order block delivery still assembles correctly" do
      r = BlockReceiver.new()
      b0 = %Block{num: 0, more: true, szx: 0}
      b1 = %Block{num: 1, more: true, szx: 0}
      b2 = %Block{num: 2, more: false, szx: 0}

      # Observe in reverse order
      {:more, r} = BlockReceiver.observe(r, b2, "tail")
      {:more, r} = BlockReceiver.observe(r, b0, :binary.copy("a", 16))
      assert {:complete, payload} = BlockReceiver.observe(r, b1, :binary.copy("b", 16))

      assert payload == :binary.copy("a", 16) <> :binary.copy("b", 16) <> "tail"
    end

    test "complete?/1 reflects assembly readiness" do
      r = BlockReceiver.new()
      refute BlockReceiver.complete?(r)

      {:more, r} = BlockReceiver.observe(r, %Block{num: 1, more: false, szx: 0}, "tail")
      # Got the final block, but block 0 is still missing
      refute BlockReceiver.complete?(r)
    end
  end

  describe "observe/3 — errors" do
    test "rejects blocks with mismatched SZX" do
      r = BlockReceiver.new()
      b0 = %Block{num: 0, more: true, szx: 0}
      b1 = %Block{num: 1, more: false, szx: 6}

      {:more, r} = BlockReceiver.observe(r, b0, :binary.copy("a", 16))

      assert {:error, %Error{code: :inconsistent_block_size, meta: meta}} =
               BlockReceiver.observe(r, b1, "tail")

      assert meta.expected_szx == 0
      assert meta.got_szx == 6
    end

    test "rejects non-final blocks whose chunk size doesn't match SZX" do
      r = BlockReceiver.new()
      block = %Block{num: 0, more: true, szx: 0}

      assert {:error, %Error{code: :inconsistent_block_size, meta: meta}} =
               BlockReceiver.observe(r, block, "short")

      assert meta.expected == 16
      assert meta.got == 5
    end

    test "tolerates a short final block (the last one is allowed to be partial)" do
      r = BlockReceiver.new()
      block = %Block{num: 0, more: false, szx: 0}
      assert {:complete, "short"} = BlockReceiver.observe(r, block, "short")
    end
  end
end

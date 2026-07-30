defmodule WickCoap.BlockSenderTest do
  use ExUnit.Case, async: true

  alias WickCoap.BlockSender

  doctest BlockSender

  describe "new/2 — payload sizing" do
    test "single-block payload (smaller than block size)" do
      sender = BlockSender.new("hi", szx: 6)
      assert sender.total_blocks == 1
      assert sender.block_size == 1024
    end

    test "exactly one block" do
      sender = BlockSender.new(:binary.copy("x", 16), szx: 0)
      assert sender.total_blocks == 1
    end

    test "rolls over to multiple blocks at boundary + 1" do
      sender = BlockSender.new(:binary.copy("x", 17), szx: 0)
      assert sender.total_blocks == 2
    end

    test "empty payload still has one block" do
      sender = BlockSender.new(<<>>, szx: 0)
      assert sender.total_blocks == 1
    end

    test "default szx is 6 (1024)" do
      sender = BlockSender.new("hi")
      assert sender.szx == 6
      assert sender.block_size == 1024
    end
  end

  describe "current/1" do
    test "first block of a multi-block payload" do
      sender = BlockSender.new(:binary.copy("a", 32), szx: 0)
      {chunk, block, ^sender} = BlockSender.current(sender)

      assert byte_size(chunk) == 16
      assert chunk == :binary.copy("a", 16)
      assert block.num == 0
      assert block.more == true
      assert block.szx == 0
    end

    test "single-block payload reports more = false" do
      sender = BlockSender.new("hello world", szx: 0)
      {chunk, block, _} = BlockSender.current(sender)

      assert chunk == "hello world"
      assert block.more == false
    end

    test "last partial block returns only the remaining bytes" do
      payload = :binary.copy("x", 20)
      sender = BlockSender.new(payload, szx: 0)
      # Skip to last block
      {:ok, sender} = BlockSender.advance(sender)
      {chunk, block, _} = BlockSender.current(sender)

      assert byte_size(chunk) == 4
      assert block.num == 1
      assert block.more == false
    end
  end

  describe "advance/1" do
    test "returns :complete when on the last block" do
      sender = BlockSender.new(:binary.copy("x", 16), szx: 0)
      assert :complete = BlockSender.advance(sender)
    end

    test "yields the next sender for multi-block payloads" do
      sender = BlockSender.new(:binary.copy("x", 100), szx: 0)
      assert sender.total_blocks == 7

      {:ok, sender} = BlockSender.advance(sender)
      assert sender.num == 1

      sender =
        Enum.reduce(1..5, sender, fn _, s ->
          {:ok, s2} = BlockSender.advance(s)
          s2
        end)

      assert sender.num == 6

      assert :complete = BlockSender.advance(sender)
    end
  end

  describe "more?/1" do
    test "true while blocks remain, false on the last block" do
      sender = BlockSender.new(:binary.copy("x", 32), szx: 0)
      assert BlockSender.more?(sender)

      {:ok, sender} = BlockSender.advance(sender)
      refute BlockSender.more?(sender)
    end
  end
end

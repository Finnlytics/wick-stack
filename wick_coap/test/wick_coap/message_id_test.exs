defmodule WickCoap.MessageIdTest do
  use ExUnit.Case, async: true

  alias WickCoap.MessageId

  doctest MessageId

  describe "next/1" do
    test "yields successive integers, advancing the allocator" do
      a = MessageId.new(0)
      {0, a} = MessageId.next(a)
      {1, a} = MessageId.next(a)
      {2, _} = MessageId.next(a)
    end

    test "wraps at 65535 → 0" do
      a = MessageId.new(0xFFFF)
      {0xFFFF, a} = MessageId.next(a)
      {0, _} = MessageId.next(a)
    end
  end

  describe "random/0" do
    test "returns a value in 0..65535" do
      for _ <- 1..50 do
        v = MessageId.random()
        assert is_integer(v)
        assert v in 0..0xFFFF
      end
    end
  end
end

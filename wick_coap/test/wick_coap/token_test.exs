defmodule WickCoap.TokenTest do
  use ExUnit.Case, async: true

  alias WickCoap.Token

  doctest Token

  describe "new/1" do
    test "default length is 8 bytes" do
      assert byte_size(Token.new()) == 8
    end

    test "any length 0..8 works" do
      for len <- 0..8 do
        assert byte_size(Token.new(len)) == len
      end
    end

    test "rejects lengths > 8" do
      assert_raise FunctionClauseError, fn -> Token.new(9) end
    end

    test "two consecutive 8-byte tokens are different (collision is astronomically unlikely)" do
      refute Token.new(8) == Token.new(8)
    end
  end
end

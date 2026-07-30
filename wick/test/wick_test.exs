defmodule WickTest do
  use ExUnit.Case, async: true

  doctest Wick

  describe "version/0" do
    test "returns the running library version as a string" do
      version = Wick.version()
      assert is_binary(version)
      assert version =~ ~r/^\d+\.\d+\.\d+/
    end
  end
end

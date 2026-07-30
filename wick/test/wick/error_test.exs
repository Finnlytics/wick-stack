defmodule Wick.ErrorTest do
  use ExUnit.Case, async: true

  alias Wick.Error

  doctest Error

  describe "new/3" do
    test "builds an error with default empty meta" do
      err = Error.new(:invalid_path, "bad")
      assert err.code == :invalid_path
      assert err.message == "bad"
      assert err.meta == %{}
    end

    test "accepts meta as a keyword list and stores it as a map" do
      err = Error.new(:malformed_cbor, "bad", offset: 12, expected: :array)
      assert err.meta == %{offset: 12, expected: :array}
    end
  end
end

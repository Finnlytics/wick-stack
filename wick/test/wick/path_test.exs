defmodule Wick.PathTest do
  use ExUnit.Case, async: true

  alias Wick.Path

  doctest Path

  describe "parse/1" do
    test "parses a single object path" do
      assert {:ok, %Path{object_id: 3}} = Path.parse("/3")
    end

    test "parses a full four-component path" do
      assert {:ok, path} = Path.parse("/3/0/9/2")

      assert %Path{
               object_id: 3,
               object_instance_id: 0,
               resource_id: 9,
               resource_instance_id: 2
             } = path
    end

    test "accepts paths without a leading slash" do
      assert {:ok, %Path{object_id: 3, object_instance_id: 0}} = Path.parse("3/0")
    end

    test "accepts the maximum id value" do
      assert {:ok, %Path{object_id: 65_535}} = Path.parse("/65535")
    end

    test "rejects ids above the maximum" do
      assert {:error, %Wick.Error{code: :invalid_path}} = Path.parse("/65536")
    end

    test "rejects non-integer components" do
      assert {:error, %Wick.Error{code: :invalid_path}} = Path.parse("/abc")
    end

    test "rejects negative ids" do
      assert {:error, %Wick.Error{code: :invalid_path}} = Path.parse("/-1")
    end

    test "rejects empty input" do
      assert {:error, %Wick.Error{code: :invalid_path}} = Path.parse("")
    end

    test "rejects bare slash" do
      assert {:error, %Wick.Error{code: :invalid_path}} = Path.parse("/")
    end

    test "rejects paths with more than four components" do
      assert {:error, %Wick.Error{code: :invalid_path}} = Path.parse("/3/0/9/2/extra")
    end

    test "rejects empty components inside a path" do
      assert {:error, %Wick.Error{code: :invalid_path}} = Path.parse("/3//9")
    end
  end

  describe "format/1" do
    test "formats every prefix of a four-component path" do
      assert Path.format(%Path{object_id: 3}) == "/3"
      assert Path.format(%Path{object_id: 3, object_instance_id: 0}) == "/3/0"
      assert Path.format(%Path{object_id: 3, object_instance_id: 0, resource_id: 9}) == "/3/0/9"

      assert Path.format(%Path{
               object_id: 3,
               object_instance_id: 0,
               resource_id: 9,
               resource_instance_id: 2
             }) == "/3/0/9/2"
    end
  end

  describe "round trip" do
    test "parse |> format is identity for all valid prefixes" do
      for path <- ["/0", "/3", "/3/0", "/3/0/9", "/3/0/9/2", "/65535/0/0/0"] do
        assert {:ok, parsed} = Path.parse(path)
        assert Path.format(parsed) == path
      end
    end
  end
end

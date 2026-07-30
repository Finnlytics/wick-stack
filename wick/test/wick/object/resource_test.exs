defmodule Wick.Object.ResourceTest do
  use ExUnit.Case, async: true

  alias Wick.Object.Resource

  doctest Resource

  defp build(operations, multiple_instances \\ :single) do
    %Resource{
      resource_id: 0,
      name: "Test",
      description: nil,
      type: :integer,
      operations: operations,
      multiple_instances: multiple_instances,
      mandatory: :optional,
      range_enumeration: nil,
      units: nil
    }
  end

  describe "readable?/1, writable?/1, executable?/1" do
    test "read-only resource" do
      r = build([:read])
      assert Resource.readable?(r)
      refute Resource.writable?(r)
      refute Resource.executable?(r)
    end

    test "read-write resource" do
      r = build([:read, :write])
      assert Resource.readable?(r)
      assert Resource.writable?(r)
      refute Resource.executable?(r)
    end

    test "execute-only resource" do
      r = build([:execute])
      refute Resource.readable?(r)
      refute Resource.writable?(r)
      assert Resource.executable?(r)
    end

    test "no operations" do
      r = build([])
      refute Resource.readable?(r)
      refute Resource.writable?(r)
      refute Resource.executable?(r)
    end
  end

  describe "multi_instance?/1" do
    test "single-instance resource" do
      refute Resource.multi_instance?(build([:read], :single))
    end

    test "multi-instance resource" do
      assert Resource.multi_instance?(build([:read], :multiple))
    end
  end
end

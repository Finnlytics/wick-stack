defmodule Wick.Senml.RecordTest do
  use ExUnit.Case, async: true

  alias Wick.Senml.Record

  doctest Record

  describe "struct construction" do
    test "all fields default to nil when omitted" do
      r = %Record{}

      assert r.base_name == nil
      assert r.base_time == nil
      assert r.name == nil
      assert r.time == nil
      assert r.number_value == nil
      assert r.string_value == nil
      assert r.boolean_value == nil
      assert r.opaque_value == nil
      assert r.object_link_value == nil
    end

    test "preserves all set fields" do
      r = %Record{
        base_name: "/3/0/",
        base_time: 1_700_000_000,
        name: "9",
        time: 5,
        number_value: 87,
        string_value: nil,
        boolean_value: nil,
        opaque_value: nil,
        object_link_value: nil
      }

      assert r.base_name == "/3/0/"
      assert r.base_time == 1_700_000_000
      assert r.name == "9"
      assert r.time == 5
      assert r.number_value == 87
    end
  end

  describe "value_type/1" do
    test "returns :number when number_value is set" do
      assert Record.value_type(%Record{number_value: 87}) == :number
      assert Record.value_type(%Record{number_value: 0}) == :number
      assert Record.value_type(%Record{number_value: -1}) == :number
      assert Record.value_type(%Record{number_value: 3.14}) == :number
    end

    test "returns :string when string_value is set" do
      assert Record.value_type(%Record{string_value: "hello"}) == :string
      assert Record.value_type(%Record{string_value: ""}) == :string
    end

    test "returns :boolean for both true and false" do
      assert Record.value_type(%Record{boolean_value: true}) == :boolean
      assert Record.value_type(%Record{boolean_value: false}) == :boolean
    end

    test "returns :opaque when opaque_value is set" do
      assert Record.value_type(%Record{opaque_value: <<1, 2, 3>>}) == :opaque
      assert Record.value_type(%Record{opaque_value: <<>>}) == :opaque
    end

    test "returns :objlnk when object_link_value is set" do
      assert Record.value_type(%Record{object_link_value: "1:0"}) == :objlnk
    end

    test "returns :none when no value field is set" do
      assert Record.value_type(%Record{}) == :none
      assert Record.value_type(%Record{name: "/3/0/9"}) == :none
      assert Record.value_type(%Record{base_name: "/3/0/"}) == :none
    end

    test "precedence matches Leshan: boolean > number > objlnk > string > opaque" do
      both = %Record{boolean_value: true, number_value: 5, string_value: "x", opaque_value: <<1>>}
      assert Record.value_type(both) == :boolean

      no_bool = %Record{number_value: 5, string_value: "x", opaque_value: <<1>>}
      assert Record.value_type(no_bool) == :number

      with_objlnk = %Record{object_link_value: "1:0", string_value: "x", opaque_value: <<1>>}
      assert Record.value_type(with_objlnk) == :objlnk

      str_and_opaque = %Record{string_value: "x", opaque_value: <<1>>}
      assert Record.value_type(str_and_opaque) == :string
    end
  end

  describe "value/1" do
    test "returns the value matching value_type/1" do
      assert Record.value(%Record{number_value: 87}) == 87
      assert Record.value(%Record{string_value: "hello"}) == "hello"
      assert Record.value(%Record{boolean_value: false}) == false
      assert Record.value(%Record{opaque_value: <<1, 2>>}) == <<1, 2>>
      assert Record.value(%Record{object_link_value: "1:0"}) == "1:0"
    end

    test "returns nil when no value field is set" do
      assert Record.value(%Record{}) == nil
      assert Record.value(%Record{name: "/3/0/9"}) == nil
    end

    test "obeys precedence" do
      assert Record.value(%Record{boolean_value: true, number_value: 5}) == true
      assert Record.value(%Record{number_value: 5, string_value: "x"}) == 5
    end
  end
end

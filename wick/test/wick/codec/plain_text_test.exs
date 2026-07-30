defmodule Wick.Codec.PlainTextTest do
  use ExUnit.Case, async: true

  alias Wick.Codec.PlainText
  alias Wick.Error

  doctest PlainText

  describe "content_format/0" do
    test "is the IANA-registered text/plain CoAP Content-Format" do
      assert PlainText.content_format() == 0
    end
  end

  describe "encode/2 — integer" do
    test "encodes positive integers as decimal digits" do
      assert {:ok, "0"} = PlainText.encode({:integer, 0})
      assert {:ok, "87"} = PlainText.encode({:integer, 87})
      assert {:ok, "1700000000"} = PlainText.encode({:integer, 1_700_000_000})
    end

    test "encodes negative integers with a minus sign" do
      assert {:ok, "-1"} = PlainText.encode({:integer, -1})
      assert {:ok, "-100"} = PlainText.encode({:integer, -100})
    end
  end

  describe "encode/2 — float" do
    test "encodes typical sensor readings as plain decimal" do
      assert {:ok, "0.0"} = PlainText.encode({:float, 0.0})
      assert {:ok, "1.5"} = PlainText.encode({:float, 1.5})
      assert {:ok, "3.14"} = PlainText.encode({:float, 3.14})
      assert {:ok, "-3.14"} = PlainText.encode({:float, -3.14})
      assert {:ok, "100.0"} = PlainText.encode({:float, 100.0})
    end
  end

  describe "encode/2 — string" do
    test "encodes ASCII strings as raw bytes" do
      assert {:ok, "hello"} = PlainText.encode({:string, "hello"})
      assert {:ok, ""} = PlainText.encode({:string, ""})
    end

    test "encodes UTF-8 strings as raw bytes (no escaping)" do
      assert {:ok, "café"} = PlainText.encode({:string, "café"})
      assert {:ok, "日本語"} = PlainText.encode({:string, "日本語"})
    end
  end

  describe "encode/2 — boolean" do
    test "true → 1, false → 0 (per OMA LwM2M 1.2 §6.4.4)" do
      assert {:ok, "1"} = PlainText.encode({:boolean, true})
      assert {:ok, "0"} = PlainText.encode({:boolean, false})
    end
  end

  describe "encode/2 — time" do
    test "encodes Unix-epoch seconds as a plain integer" do
      assert {:ok, "0"} = PlainText.encode({:time, 0})
      assert {:ok, "1700000000"} = PlainText.encode({:time, 1_700_000_000})
    end
  end

  describe "encode/2 — objlnk" do
    test "formats as object_id:instance_id" do
      assert {:ok, "1:0"} = PlainText.encode({:objlnk, {1, 0}})
      assert {:ok, "33000:42"} = PlainText.encode({:objlnk, {33_000, 42}})
    end

    test "rejects negative IDs" do
      assert {:error, %Error{code: :invalid_type}} = PlainText.encode({:objlnk, {-1, 0}})
      assert {:error, %Error{code: :invalid_type}} = PlainText.encode({:objlnk, {0, -1}})
    end
  end

  describe "encode/2 — opaque" do
    test "base64-encodes with standard alphabet and padding" do
      assert {:ok, "3q2+7w=="} = PlainText.encode({:opaque, <<0xDE, 0xAD, 0xBE, 0xEF>>})
      assert {:ok, ""} = PlainText.encode({:opaque, <<>>})
    end
  end

  describe "encode/2 — error paths" do
    test "rejects unknown type tags" do
      assert {:error, %Error{code: :invalid_type}} = PlainText.encode({:nope, 1})
    end

    test "rejects mismatched value type for a tag" do
      assert {:error, %Error{code: :invalid_type}} = PlainText.encode({:integer, "87"})
      assert {:error, %Error{code: :invalid_type}} = PlainText.encode({:float, 1})
      assert {:error, %Error{code: :invalid_type}} = PlainText.encode({:opaque, 123})
      assert {:error, %Error{code: :invalid_type}} = PlainText.encode({:objlnk, {1, "0"}})
    end

    test "treats strings as binaries when tagged :opaque (Elixir strings ARE binaries)" do
      # No way to distinguish at the type level — `{:opaque, "hello"}` is a deliberate
      # choice by the caller to base64-encode whatever bytes the binary contains.
      assert {:ok, "aGVsbG8="} = PlainText.encode({:opaque, "hello"})
    end

    test "rejects bare values without a type tag" do
      assert {:error, %Error{code: :invalid_type}} = PlainText.encode(87)
      assert {:error, %Error{code: :invalid_type}} = PlainText.encode("hello")
    end
  end

  describe "decode/2 — happy paths" do
    test "decodes integers" do
      assert {:ok, {:integer, 87}} = PlainText.decode("87", as: :integer)
      assert {:ok, {:integer, 0}} = PlainText.decode("0", as: :integer)
      assert {:ok, {:integer, -1}} = PlainText.decode("-1", as: :integer)
    end

    test "decodes floats" do
      assert {:ok, {:float, 1.5}} = PlainText.decode("1.5", as: :float)
      assert {:ok, {:float, -3.14}} = PlainText.decode("-3.14", as: :float)
    end

    test "decodes strings (raw bytes pass through)" do
      assert {:ok, {:string, "hello"}} = PlainText.decode("hello", as: :string)
      assert {:ok, {:string, ""}} = PlainText.decode("", as: :string)
      assert {:ok, {:string, "café"}} = PlainText.decode("café", as: :string)
    end

    test "decodes booleans (1 → true, 0 → false)" do
      assert {:ok, {:boolean, true}} = PlainText.decode("1", as: :boolean)
      assert {:ok, {:boolean, false}} = PlainText.decode("0", as: :boolean)
    end

    test "decodes time as Unix-epoch seconds (integer)" do
      assert {:ok, {:time, 0}} = PlainText.decode("0", as: :time)
      assert {:ok, {:time, 1_700_000_000}} = PlainText.decode("1700000000", as: :time)
    end

    test "decodes objlnk as {object_id, instance_id}" do
      assert {:ok, {:objlnk, {1, 0}}} = PlainText.decode("1:0", as: :objlnk)
      assert {:ok, {:objlnk, {33_000, 42}}} = PlainText.decode("33000:42", as: :objlnk)
    end

    test "decodes opaque from standard-alphabet base64 with padding" do
      assert {:ok, {:opaque, <<0xDE, 0xAD, 0xBE, 0xEF>>}} =
               PlainText.decode("3q2+7w==", as: :opaque)

      assert {:ok, {:opaque, <<>>}} = PlainText.decode("", as: :opaque)
    end
  end

  describe "decode/2 — round-trips against encode/2" do
    test "encode then decode is the identity for every value type variant" do
      cases = [
        {:integer, 87},
        {:integer, -123},
        {:float, 1.5},
        {:float, -3.14},
        {:string, "hello"},
        {:string, "café"},
        {:string, ""},
        {:boolean, true},
        {:boolean, false},
        {:time, 0},
        {:time, 1_700_000_000},
        {:objlnk, {1, 0}},
        {:objlnk, {33_000, 42}},
        {:opaque, <<0xDE, 0xAD, 0xBE, 0xEF>>},
        {:opaque, <<>>}
      ]

      for {type, _value} = original <- cases do
        {:ok, encoded} = PlainText.encode(original)
        assert {:ok, ^original} = PlainText.decode(encoded, as: type)
      end
    end
  end

  describe "decode/2 — error paths" do
    test "missing :as type hint errors with :missing_type" do
      assert {:error, %Error{code: :missing_type}} = PlainText.decode("hello")
      assert {:error, %Error{code: :missing_type}} = PlainText.decode("hello", [])
    end

    test "unrecognised :as value errors with :invalid_type" do
      assert {:error, %Error{code: :invalid_type, meta: %{type: :nope}}} =
               PlainText.decode("x", as: :nope)
    end

    test ":malformed_text when integer text is malformed" do
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("abc", as: :integer)
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("1.5", as: :integer)
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("", as: :integer)
    end

    test ":malformed_text when float text is malformed" do
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("abc", as: :float)
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("", as: :float)
    end

    test ":malformed_text for boolean values other than 0 / 1" do
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("true", as: :boolean)
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("2", as: :boolean)
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("", as: :boolean)
    end

    test ":malformed_text for time text that isn't an integer" do
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("now", as: :time)
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("1.5", as: :time)
    end

    test ":malformed_text for objlnk that isn't 'O:I' with non-negative ints" do
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("1", as: :objlnk)
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("a:b", as: :objlnk)
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("-1:0", as: :objlnk)
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("1:-1", as: :objlnk)
      assert {:error, %Error{code: :malformed_text}} = PlainText.decode("1:0:extra", as: :objlnk)
    end

    test ":malformed_text for invalid base64 in :opaque" do
      assert {:error, %Error{code: :malformed_text}} =
               PlainText.decode("not!base64!", as: :opaque)
    end
  end
end

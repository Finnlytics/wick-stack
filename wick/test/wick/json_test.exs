defmodule Wick.JsonTest do
  use ExUnit.Case, async: true

  alias Wick.Json

  describe "encode_text/1" do
    test "wraps a plain ASCII string in double quotes" do
      assert Json.encode_text("hello") == ~s|"hello"|
    end

    test "the empty string encodes as two quotes" do
      assert Json.encode_text("") == ~s|""|
    end

    test "passes raw UTF-8 multi-byte sequences through verbatim" do
      assert Json.encode_text("café") == <<?", "café"::binary, ?">>
      assert Json.encode_text("日本語") == <<?", "日本語"::binary, ?">>
    end

    test "escapes the JSON-mandatory characters" do
      assert Json.encode_text(~s|he said "hi"|) == ~s|"he said \\"hi\\""|
      assert Json.encode_text("a\\b") == ~s|"a\\\\b"|
      assert Json.encode_text("line1\nline2") == ~s|"line1\\nline2"|
      assert Json.encode_text("tab\there") == ~s|"tab\\there"|
      assert Json.encode_text("\r") == ~s|"\\r"|
      assert Json.encode_text("\b") == ~s|"\\b"|
      assert Json.encode_text("\f") == ~s|"\\f"|
    end

    test "escapes other control bytes as \\u00XX" do
      assert Json.encode_text(<<0x01>>) == ~s|"\\u0001"|
      assert Json.encode_text(<<0x1F>>) == ~s|"\\u001f"|
      assert Json.encode_text(<<0x00>>) == ~s|"\\u0000"|
    end
  end

  describe "encode_int/1" do
    test "encodes positive integers" do
      assert Json.encode_int(0) == "0"
      assert Json.encode_int(87) == "87"
      assert Json.encode_int(1_700_000_000) == "1700000000"
    end

    test "encodes negative integers" do
      assert Json.encode_int(-1) == "-1"
      assert Json.encode_int(-100) == "-100"
    end
  end

  describe "encode_float/1" do
    test "emits clean fixed-decimal form for typical SenML values" do
      assert Json.encode_float(0.0) == "0.0"
      assert Json.encode_float(1.0) == "1.0"
      assert Json.encode_float(1.5) == "1.5"
      assert Json.encode_float(3.14) == "3.14"
      assert Json.encode_float(100.0) == "100.0"
      assert Json.encode_float(-3.14) == "-3.14"
    end

    test "uses Erlang's :short scientific notation for large magnitudes" do
      # Note: Erlang switches to scientific at >= 1e6, Java's Double.toString at >= 1e7.
      # Diverges from Jackson at the 1e6..1e7 range — flag if a real fixture lands there.
      assert Json.encode_float(1.0e6) == "1.0e6"
      assert Json.encode_float(1.0e10) == "1.0e10"
    end
  end

  describe "encode_bool/1 and encode_null/0" do
    test "true and false encode literally" do
      assert Json.encode_bool(true) == "true"
      assert Json.encode_bool(false) == "false"
    end

    test "null encodes literally" do
      assert Json.encode_null() == "null"
    end
  end

  describe "encode_array/1" do
    test "empty array is just brackets" do
      assert Json.encode_array([]) == "[]"
    end

    test "single-item array" do
      assert Json.encode_array(["1"]) == "[1]"
    end

    test "comma-separates pre-encoded items, no spaces" do
      assert Json.encode_array(["1", "2", "3"]) == "[1,2,3]"
      assert Json.encode_array([~s|"a"|, ~s|"b"|]) == ~s|["a","b"]|
    end
  end

  describe "encode_object/1" do
    test "empty object is just braces" do
      assert Json.encode_object([]) == "{}"
    end

    test "single key-value pair" do
      assert Json.encode_object([{~s|"n"|, ~s|"x"|}]) == ~s|{"n":"x"}|
    end

    test "preserves caller-supplied key order, no spaces" do
      pairs = [{~s|"bn"|, ~s|"/3/0/"|}, {~s|"n"|, ~s|"9"|}, {~s|"v"|, "87"}]
      assert Json.encode_object(pairs) == ~s|{"bn":"/3/0/","n":"9","v":87}|
    end
  end

  doctest Json

  describe "decode/1 — primitives" do
    test "decodes positive and negative integers" do
      assert {:ok, 0} = Json.decode("0")
      assert {:ok, 87} = Json.decode("87")
      assert {:ok, -1} = Json.decode("-1")
      assert {:ok, 1_700_000_000} = Json.decode("1700000000")
    end

    test "decodes floats including negative and exponent forms" do
      assert {:ok, +0.0} = Json.decode("0.0")
      assert {:ok, -0.0} = Json.decode("-0.0")
      assert {:ok, 1.5} = Json.decode("1.5")
      assert {:ok, -3.14} = Json.decode("-3.14")
      assert {:ok, 1.0e10} = Json.decode("1e10")
      assert {:ok, 0.0015} = Json.decode("1.5e-3")
    end

    test "no fraction or exponent → integer (preserves type fidelity)" do
      assert {:ok, value} = Json.decode("87")
      assert is_integer(value)

      assert {:ok, value} = Json.decode("1.5")
      assert is_float(value)
    end

    test "decodes the three keyword literals" do
      assert {:ok, true} = Json.decode("true")
      assert {:ok, false} = Json.decode("false")
      assert {:ok, nil} = Json.decode("null")
    end
  end

  describe "decode/1 — strings" do
    test "ASCII string round-trip via encode_text" do
      for s <- ["", "a", "hello", "Open Mobile Alliance"] do
        encoded = Json.encode_text(s)
        assert {:ok, ^s} = Json.decode(encoded)
      end
    end

    test "decodes \\\" \\\\ \\b \\f \\n \\r \\t escapes" do
      assert {:ok, ~s|he said "hi"|} = Json.decode(~s|"he said \\"hi\\""|)
      assert {:ok, "a\\b"} = Json.decode(~s|"a\\\\b"|)
      assert {:ok, "line1\nline2"} = Json.decode(~s|"line1\\nline2"|)
      assert {:ok, "tab\there"} = Json.decode(~s|"tab\\there"|)
      assert {:ok, "\b\f\r"} = Json.decode(~s|"\\b\\f\\r"|)
    end

    test "decodes \\/ escape (optional in JSON but valid)" do
      assert {:ok, "a/b"} = Json.decode(~s|"a\\/b"|)
    end

    test "decodes BMP \\uXXXX escapes" do
      assert {:ok, "café"} = Json.decode(~s|"caf\\u00e9"|)
      assert {:ok, "日本"} = Json.decode(~s|"\\u65e5\\u672c"|)
    end

    test "accepts uppercase hex digits in \\uXXXX escapes" do
      assert {:ok, "café"} = Json.decode(~s|"caf\\u00E9"|)
    end

    test "decodes surrogate-pair \\uXXXX\\uXXXX (non-BMP codepoints)" do
      # U+1F600 (😀) → surrogate pair D83D / DE00
      assert {:ok, "😀"} = Json.decode(~s|"\\ud83d\\ude00"|)
    end

    test "passes raw UTF-8 through unchanged" do
      assert {:ok, "café"} = Json.decode(~s|"café"|)
    end
  end

  describe "decode/1 — arrays and objects" do
    test "empty array and empty object" do
      assert {:ok, []} = Json.decode("[]")
      assert {:ok, %{}} = Json.decode("{}")
    end

    test "nested structures" do
      assert {:ok, [%{"n" => "/3/0/9", "v" => 87}]} =
               Json.decode(~s|[{"n":"/3/0/9","v":87}]|)
    end

    test "tolerates whitespace between every token" do
      input = ~s|  [  {  "n"  :  "/3/0/9"  ,  "v"  :  87  }  ]  |
      assert {:ok, [%{"n" => "/3/0/9", "v" => 87}]} = Json.decode(input)
    end

    test "duplicate keys follow Map.put semantics — last write wins" do
      assert {:ok, %{"a" => 2}} = Json.decode(~s|{"a":1,"a":2}|)
    end
  end

  describe "decode/1 — error paths" do
    test "rejects empty input" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode("")
    end

    test "rejects unknown identifiers" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode("nope")
    end

    test "rejects unterminated string" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode(~s|"unfinished|)
    end

    test "rejects unescaped control characters in strings" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode(<<?", 0x01, ?">>)
    end

    test "rejects invalid escape sequences" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode(~s|"\\x"|)
    end

    test "rejects malformed surrogate pairs" do
      # high surrogate not followed by \\u
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode(~s|"\\ud83dx"|)
      # high surrogate followed by non-low-surrogate \\u
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode(~s|"\\ud83d\\u0041"|)
      # lone low surrogate
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode(~s|"\\ude00"|)
    end

    test "rejects invalid hex digits in \\uXXXX" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode(~s|"\\uZZZZ"|)
    end

    test "rejects malformed numbers" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode("1.")
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode("1e")
    end

    test "rejects a lone minus sign" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode("-")
    end

    test "rejects unterminated objects" do
      assert {:error, %Wick.Error{code: :malformed_json, message: msg}} =
               Json.decode(~s|{"a":1 garbage}|)

      assert msg =~ "',' or '}'"
    end

    test "rejects trailing content after a complete value" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode("87 garbage")
    end

    test "rejects malformed arrays" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode("[1, 2,")
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode("[1 2]")
    end

    test "rejects malformed objects" do
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode(~s|{"a"|)
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode(~s|{"a":1,}|)
      assert {:error, %Wick.Error{code: :malformed_json}} = Json.decode(~s|{1:2}|)
    end
  end
end

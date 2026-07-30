defmodule Wick.Codec.OpaqueTest do
  use ExUnit.Case, async: true

  alias Wick.Codec.Opaque
  alias Wick.Error

  doctest Opaque

  describe "content_format/0" do
    test "is the IANA-registered application/octet-stream Content-Format" do
      assert Opaque.content_format() == 42
    end
  end

  describe "encode/2" do
    test "is the identity function on binary input" do
      assert {:ok, <<0xDE, 0xAD, 0xBE, 0xEF>>} = Opaque.encode(<<0xDE, 0xAD, 0xBE, 0xEF>>)
    end

    test "preserves empty binaries" do
      assert {:ok, <<>>} = Opaque.encode(<<>>)
    end

    test "preserves arbitrary byte sequences including null bytes" do
      bytes = <<0, 1, 2, 0xFF, 0, 0xAA>>
      assert {:ok, ^bytes} = Opaque.encode(bytes)
    end

    test "rejects non-binary input" do
      assert {:error, %Error{code: :invalid_type}} = Opaque.encode([1, 2, 3])
      assert {:error, %Error{code: :invalid_type}} = Opaque.encode(87)
      assert {:error, %Error{code: :invalid_type}} = Opaque.encode(nil)
    end
  end

  describe "decode/2" do
    test "is the identity function on binary input" do
      assert {:ok, <<0xCA, 0xFE>>} = Opaque.decode(<<0xCA, 0xFE>>)
    end

    test "preserves empty binaries" do
      assert {:ok, <<>>} = Opaque.decode(<<>>)
    end

    test "encode/decode round-trip is the identity" do
      bytes = :crypto.strong_rand_bytes(64)
      assert {:ok, encoded} = Opaque.encode(bytes)
      assert {:ok, ^bytes} = Opaque.decode(encoded)
    end

    test "rejects non-binary input" do
      assert {:error, %Error{code: :invalid_type}} = Opaque.decode([1, 2, 3])
      assert {:error, %Error{code: :invalid_type}} = Opaque.decode(nil)
    end
  end
end

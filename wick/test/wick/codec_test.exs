defmodule Wick.CodecTest do
  use ExUnit.Case, async: true

  doctest Wick.Codec

  alias Wick.Codec

  describe "for_content_format/1" do
    test "every registered format resolves to a module implementing the behaviour" do
      for content_format <- Codec.content_formats() do
        assert module = Codec.for_content_format(content_format)
        assert Kernel.apply(module, :content_format, []) == content_format
      end
    end

    test "returns nil for unregistered formats" do
      for content_format <- [1, 41, 60, 111, 11_542, 11_543] do
        assert Codec.for_content_format(content_format) == nil
      end
    end
  end

  describe "senml_codec/1" do
    test "resolves only the two SenML formats" do
      assert Codec.senml_codec(110) == {:ok, Wick.Codec.SenmlJson}
      assert Codec.senml_codec(112) == {:ok, Wick.Codec.SenmlCbor}
    end

    test "rejects the non-SenML codecs Wick ships" do
      assert Codec.senml_codec(0) == :error
      assert Codec.senml_codec(42) == :error
    end

    test "accepts nil so an absent Content-Format needs no special-casing" do
      assert Codec.senml_codec(nil) == :error
      refute Codec.senml?(nil)
    end
  end

  describe "content_formats/0" do
    test "is ascending and matches the modules' own declarations" do
      formats = Codec.content_formats()

      assert formats == Enum.sort(formats)
      assert formats == [0, 42, 110, 112]
    end
  end
end

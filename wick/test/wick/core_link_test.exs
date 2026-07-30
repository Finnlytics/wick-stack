defmodule Wick.CoreLinkTest do
  use ExUnit.Case, async: true

  doctest Wick.CoreLink

  alias Wick.CoreLink
  alias Wick.CoreLink.Link

  describe "encode/1" do
    test "single target with no params" do
      assert CoreLink.encode([%Link{target: "/1/0"}]) == "</1/0>"
    end

    test "multiple links comma-separated" do
      links = [
        %Link{target: "/1/0"},
        %Link{target: "/3/0"},
        %Link{target: "/5"}
      ]

      assert CoreLink.encode(links) == "</1/0>,</3/0>,</5>"
    end

    test "params are sorted by key for deterministic output" do
      link = %Link{target: "/3", params: %{"rt" => "oma.lwm2m", "ct" => 11_543}}
      assert CoreLink.encode([link]) == "</3>;ct=11543;rt=\"oma.lwm2m\""
    end

    test "string values are always quoted; integers stay bare" do
      link = %Link{
        target: "/x",
        params: %{
          "rt" => "oma.lwm2m",
          "sz" => 1024,
          "title" => "hello world"
        }
      }

      assert CoreLink.encode([link]) ==
               ~s(</x>;rt="oma.lwm2m";sz=1024;title="hello world")
    end

    test "quotes and backslashes inside values are escaped" do
      link = %Link{target: "/x", params: %{"title" => ~s(a "quote" and \\slash)}}
      assert CoreLink.encode([link]) == ~s(</x>;title="a \\"quote\\" and \\\\slash")
    end
  end

  describe "decode/1" do
    test "single target with no params" do
      assert {:ok, [%Link{target: "/1/0", params: %{}}]} = CoreLink.decode("</1/0>")
    end

    test "multiple links with mixed params" do
      input = ~s(</1/0>,</3>;rt="oma.lwm2m",</5/0/1>;dim=8)

      assert {:ok, links} = CoreLink.decode(input)

      assert links == [
               %Link{target: "/1/0", params: %{}},
               %Link{target: "/3", params: %{"rt" => "oma.lwm2m"}},
               %Link{target: "/5/0/1", params: %{"dim" => "8"}}
             ]
    end

    test "quoted-string with embedded escaped quote and backslash" do
      input = ~s(</x>;title="a \\"q\\" and \\\\s")
      assert {:ok, [%Link{params: %{"title" => ~s(a "q" and \\s)}}]} = CoreLink.decode(input)
    end

    test "tolerates whitespace between separators" do
      input = ~s(</1/0> , </3>; rt="oma.lwm2m")
      assert {:ok, links} = CoreLink.decode(input)
      assert length(links) == 2
      assert Enum.at(links, 1).params == %{"rt" => "oma.lwm2m"}
    end

    test "errors on unterminated target" do
      assert {:error, %Wick.Error{code: :malformed_link_format}} = CoreLink.decode("</1/0")
    end

    test "errors on unterminated quoted-string" do
      assert {:error, %Wick.Error{code: :malformed_link_format}} =
               CoreLink.decode(~s(</x>;rt="never-ends))
    end

    test "errors when separator between links is missing" do
      assert {:error, %Wick.Error{code: :malformed_link_format}} =
               CoreLink.decode("</1/0>;rt=x </3>")
    end
  end

  describe "round-trip" do
    # Semantic round-trip: decode/encode is not byte-identical because the encoder always
    # quotes string values (interop with Leshan) and sorts params, while the decoder
    # always returns string values regardless of bare-or-quoted on the wire. The
    # invariant is `decode . encode . decode == decode`.
    test "semantic identity for an LwM2M-style registration body" do
      body = ~s(</>;rt="oma.lwm2m";ct=11543,</1/0>,</3/0>,</5>)

      assert {:ok, links} = CoreLink.decode(body)
      assert {:ok, ^links} = CoreLink.decode(CoreLink.encode(links))
    end
  end
end

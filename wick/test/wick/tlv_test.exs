defmodule Wick.TlvTest do
  use ExUnit.Case, async: true

  doctest Wick.Tlv

  alias Wick.Tlv

  defp hex(tlvs), do: tlvs |> Tlv.encode() |> IO.iodata_to_binary() |> Base.encode16()

  describe "encode/1 — the type byte" do
    test "packs a value shorter than 8 bytes into bits 2-0, with no length field" do
      # C1 = 0b11_0_00_001: Resource, 8-bit id, inline length, length 1.
      assert hex([%Tlv{type: :resource, id: 9, value: <<87>>}]) == "C10957"
    end

    test "an 8-bit length field once the value reaches 8 bytes" do
      # C8 = 0b11_0_01_000: length form 01, so one length byte follows the identifier.
      value = :binary.copy(<<0xAA>>, 8)

      assert hex([%Tlv{type: :resource, id: 1, value: value}]) ==
               "C80108" <> String.duplicate("AA", 8)
    end

    test "a 16-bit length field past 255 bytes" do
      value = :binary.copy(<<0xAB>>, 300)
      assert "D001012C" <> _rest = hex([%Tlv{type: :resource, id: 1, value: value}])
    end

    test "a 24-bit length field past 65535 bytes" do
      # 70_000 = 0x011170, so the length occupies three bytes after the identifier.
      value = :binary.copy(<<0xCD>>, 70_000)
      assert "D801011170" <> _rest = hex([%Tlv{type: :resource, id: 1, value: value}])
    end

    test "a 16-bit identifier once the ID reaches 256" do
      # E1 = 0b11_1_00_001: bit 5 set, so the identifier is two bytes.
      assert hex([%Tlv{type: :resource, id: 300, value: <<1>>}]) == "E1012C01"
    end

    test "each entry type takes its own bits 7-6" do
      assert "C1" <> _ = hex([%Tlv{type: :resource, id: 0, value: <<1>>}])
      assert "41" <> _ = hex([%Tlv{type: :resource_instance, id: 0, value: <<1>>}])

      assert "83" <> _ =
               hex([
                 %Tlv{
                   type: :multiple_resource,
                   id: 0,
                   children: [%Tlv{type: :resource_instance, id: 0, value: <<1>>}]
                 }
               ])

      assert "03" <> _ =
               hex([
                 %Tlv{
                   type: :object_instance,
                   id: 0,
                   children: [%Tlv{type: :resource, id: 0, value: <<1>>}]
                 }
               ])
    end
  end

  describe "decode/1" do
    test "rejects a truncated identifier" do
      assert {:error, %{code: :malformed_tlv}} = Tlv.decode(<<0xC1>>)
    end

    test "rejects a truncated length field" do
      assert {:error, %{code: :malformed_tlv}} = Tlv.decode(Base.decode16!("C801"))
    end

    test "rejects a length that runs past the end of the payload" do
      assert {:error, error} = Tlv.decode(Base.decode16!("C109"))
      assert error.code == :malformed_tlv
      assert error.message =~ "exceeds"
    end

    test "rejects a nested length that runs past its container" do
      # An Object Instance claiming 2 bytes of children, holding a Resource claiming 5.
      assert {:error, %{code: :malformed_tlv}} = Tlv.decode(Base.decode16!("0302C505"))
    end

    test "an empty payload decodes to an empty list" do
      assert Tlv.decode(<<>>) == {:ok, []}
    end
  end

  describe "LwM2M specification examples" do
    # Every vector below is an example from the LwM2M specification's §4.3. Decoding then
    # re-encoding must be byte-identical: that is the strongest statement available that both
    # directions agree with the spec rather than merely with each other.
    @vectors %{
      "§4.3.1 device, resources only" =>
        "C800144F70656E204D6F62696C6520416C6C69616E6365C801164C69676874776569676874204D324D20436C69656E74C80209333435303030313233C303312E30860641000141010588070842000ED842011388870841007D42010384C10964C10A0F830B410000C40D5182428FC60E2B30323A3030C11055",
      "§4.3.2 A) device, one Object Instance" =>
        "080079C800144F70656E204D6F62696C6520416C6C69616E6365C801164C69676874776569676874204D324D20436C69656E74C80209333435303030313233C303312E30860641000141010588070842000ED842011388870841007D42010384C10964C10A0F830B410000C40D5182428FC60E2B30323A3030C11055",
      "§4.3.2 B) ACL, two Object Instances" =>
        "08000EC10001C101008302417F07C1037F080212C10003C101008702417F0761013601C1037F",
      "§4.3.2 C) server" => "08000FC10001C40100015180C10601C10755",
      "§4.3.3 1) object 65, three resources" =>
        "88000C440000420000440100420001C8010D38363133383030373535353030C40212345678",
      "§4.3.3 2) object 66, two instances" =>
        "080026C8000B6D79536572766963652031C8010F496E7465726E65742E31352E323334C40200430000080126C8000B6D79536572766963652032C8010F496E7465726E65742E31352E323335C402FFFFFFFF"
    }

    for {label, hex} <- @vectors do
      test "round-trips #{label}" do
        bytes = Base.decode16!(unquote(hex))

        assert {:ok, tlvs} = Tlv.decode(bytes)
        assert IO.iodata_to_binary(Tlv.encode(tlvs)) == bytes
      end
    end

    test "§4.3.1 decodes to the structure the spec describes" do
      {:ok, tlvs} = Tlv.decode(Base.decode16!(@vectors["§4.3.1 device, resources only"]))

      assert %Tlv{type: :resource, id: 0, value: "Open Mobile Alliance"} =
               Enum.find(tlvs, &(&1.id == 0))

      assert %Tlv{type: :multiple_resource, id: 6, children: instances} =
               Enum.find(tlvs, &(&1.id == 6))

      assert [
               %Tlv{type: :resource_instance, id: 0, value: <<1>>},
               %Tlv{type: :resource_instance, id: 1, value: <<5>>}
             ] = instances
    end

    test "§4.3.2 A) wraps the same resources in one Object Instance" do
      {:ok, [instance]} =
        Tlv.decode(Base.decode16!(@vectors["§4.3.2 A) device, one Object Instance"]))

      {:ok, bare} = Tlv.decode(Base.decode16!(@vectors["§4.3.1 device, resources only"]))

      assert %Tlv{type: :object_instance, id: 0} = instance
      assert instance.children == bare
    end
  end

  describe "value codecs" do
    test "integers take the shortest signed width" do
      assert Tlv.encode_integer(0) == <<0>>
      assert Tlv.encode_integer(127) == <<127>>
      assert Tlv.encode_integer(128) == <<0, 128>>
      assert Tlv.encode_integer(-128) == <<128>>
      assert Tlv.encode_integer(-129) == <<255, 127>>
      assert byte_size(Tlv.encode_integer(2_147_483_647)) == 4
      assert byte_size(Tlv.encode_integer(2_147_483_648)) == 8
    end

    test "integers round-trip at every width boundary" do
      for value <- [
            0,
            1,
            -1,
            127,
            -128,
            128,
            -129,
            32_767,
            -32_768,
            32_768,
            2_147_483_647,
            -2_147_483_648,
            2_147_483_648,
            9_223_372_036_854_775_807
          ] do
        assert Tlv.decode_integer(Tlv.encode_integer(value)) == {:ok, value},
               "failed at #{value}"
      end
    end

    test "an unsigned value above the signed byte range widens rather than wrapping" do
      # 200 in one byte would read back as -56, which is why the encoder uses two.
      assert Tlv.encode_integer(200) == <<0, 200>>
      assert Tlv.decode_integer(<<0, 200>>) == {:ok, 200}
    end

    test "integers decode at the odd widths peers emit" do
      assert Tlv.decode_integer(<<0, 0, 1>>) == {:ok, 1}
      assert Tlv.decode_integer(<<0, 0, 0, 0, 1>>) == {:ok, 1}
    end

    test "an integer longer than 8 bytes is rejected" do
      assert {:error, %{code: :malformed_tlv}} = Tlv.decode_integer(:binary.copy(<<1>>, 9))
    end

    test "floats encode as doubles and accept both widths on the way back" do
      assert byte_size(Tlv.encode_float(22.5)) == 8
      assert Tlv.decode_float(Tlv.encode_float(22.5)) == {:ok, 22.5}
      assert Tlv.decode_float(<<0x41, 0xB4, 0x00, 0x00>>) == {:ok, 22.5}
    end

    test "a float of any other width is rejected" do
      assert {:error, %{code: :malformed_tlv}} = Tlv.decode_float(<<1, 2, 3>>)
    end

    test "booleans" do
      assert Tlv.decode_boolean(Tlv.encode_boolean(true)) == {:ok, true}
      assert Tlv.decode_boolean(Tlv.encode_boolean(false)) == {:ok, false}
      assert Tlv.decode_boolean(<<2>>) == {:ok, true}
      assert {:error, %{code: :malformed_tlv}} = Tlv.decode_boolean(<<0, 1>>)
    end

    test "objlnk is two 16-bit identifiers" do
      assert Tlv.encode_objlnk({3, 0}) == <<0, 3, 0, 0>>
      assert Tlv.decode_objlnk(<<0, 3, 0, 0>>) == {:ok, {3, 0}}
      assert Tlv.decode_objlnk(<<0xFF, 0xFF, 0xFF, 0xFF>>) == {:ok, {65_535, 65_535}}
      assert {:error, %{code: :malformed_tlv}} = Tlv.decode_objlnk(<<1, 2>>)
    end
  end
end

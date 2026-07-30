defmodule Wick.UplinkTest do
  use ExUnit.Case, async: true

  alias Wick.Uplink

  describe "Wick.Uplink.Notify" do
    test "carries content_format, payload, and observe_seq" do
      n = %Uplink.Notify{
        content_format: 112,
        payload: <<0x81, 0xA1, 0x02, 0x05>>,
        observe_seq: 42
      }

      assert n.content_format == 112
      assert n.payload == <<0x81, 0xA1, 0x02, 0x05>>
      assert n.observe_seq == 42
    end

    test "all three keys are required at construction" do
      assert_raise ArgumentError, fn -> struct!(Uplink.Notify, []) end

      assert_raise ArgumentError, fn ->
        struct!(Uplink.Notify, content_format: 112, payload: <<>>)
      end
    end

    test "deliberately does not carry path — path is resolved by the gateway" do
      n = %Uplink.Notify{content_format: 0, payload: "x", observe_seq: 0}
      refute Map.has_key?(n, :path)
    end
  end

  describe "Wick.Uplink.Send" do
    test "carries content_format and payload" do
      s = %Uplink.Send{content_format: 112, payload: <<0x80>>}

      assert s.content_format == 112
      assert s.payload == <<0x80>>
    end

    test "deliberately does not carry observe_seq — Send has no prior relation" do
      s = %Uplink.Send{content_format: 0, payload: <<>>}
      refute Map.has_key?(s, :observe_seq)
    end

    test "missing required keys raise" do
      assert_raise ArgumentError, fn -> struct!(Uplink.Send, []) end
      assert_raise ArgumentError, fn -> struct!(Uplink.Send, content_format: 112) end
    end
  end

  describe "pattern matching across uplink types" do
    test "structs are distinguishable" do
      messages = [
        %Uplink.Notify{content_format: 112, payload: <<>>, observe_seq: 1},
        %Uplink.Send{content_format: 112, payload: <<>>}
      ]

      tags =
        Enum.map(messages, fn
          %Uplink.Notify{} -> :notify
          %Uplink.Send{} -> :send
        end)

      assert tags == [:notify, :send]
    end
  end
end

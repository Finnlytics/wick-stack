defmodule Wick.UplinkWireTest do
  use ExUnit.Case, async: true

  alias Wick.Status
  alias Wick.Uplink
  alias Wick.Wire

  describe "Send" do
    test "is a POST to /dp" do
      wire = Uplink.to_wire(%Uplink.Send{content_format: 112, payload: <<0x80>>})

      assert wire.method == :post
      assert wire.path == Uplink.data_path()
      assert wire.path == ["dp"]
      assert wire.observe == nil
    end

    test "round-trips through the CoAP option representation" do
      send = %Uplink.Send{content_format: 110, payload: ~s|[{"n":"/3303/0/5700","v":22.5}]|}
      wire = Uplink.to_wire(send)

      assert {:ok, parsed} = Wire.parse(wire.method, Wire.to_coap_options(wire), wire.payload)
      assert Uplink.from_wire(parsed) == {:ok, send}
    end

    test "a POST elsewhere is not an uplink" do
      {:ok, wire} = Wire.parse(:post, [{11, "rd"}, {12, <<40>>}], "</3/0>")

      assert {:error, err} = Uplink.from_wire(wire)
      assert err.code == :not_an_uplink
      assert err.meta == %{method: :post, path: ["rd"]}
    end

    test "a GET to /dp is not an uplink" do
      {:ok, wire} = Wire.parse(:get, [{11, "dp"}], "")

      assert {:error, %{code: :not_an_uplink}} = Uplink.from_wire(wire)
    end

    test "a Send with no Content-Format cannot be interpreted" do
      {:ok, wire} = Wire.parse(:post, [{11, "dp"}], <<0x80>>)

      assert {:error, err} = Uplink.from_wire(wire)
      assert err.code == :missing_content_format
    end
  end

  describe "Notify" do
    test "is a 2.05 Content carrying the Observe sequence" do
      notify = %Uplink.Notify{content_format: 112, payload: <<0x80>>, observe_seq: 7}
      wire = Uplink.to_wire(notify)

      assert wire.status == :content
      assert wire.observe_seq == 7
      assert Wire.Response.to_coap_options(wire) == [{6, <<7>>}, {12, <<112>>}]
    end

    test "sequence 0 still emits the Observe option" do
      notify = %Uplink.Notify{content_format: 112, payload: <<0x80>>, observe_seq: 0}

      assert Wire.Response.to_coap_options(Uplink.to_wire(notify)) == [{6, ""}, {12, <<112>>}]
    end

    test "round-trips through the CoAP option representation" do
      notify = %Uplink.Notify{content_format: 112, payload: <<0x81, 0xA1>>, observe_seq: 16_777_215}
      wire = Uplink.to_wire(notify)

      assert {:ok, parsed} =
               Wire.Response.parse(
                 Status.to_coap(wire.status),
                 Wire.Response.to_coap_options(wire),
                 wire.payload
               )

      assert Uplink.from_wire(parsed) == {:ok, notify}
    end

    test "a response with no Observe option is not a Notify" do
      {:ok, wire} = Wire.Response.parse({2, 5}, [{12, <<112>>}], <<0x80>>)

      assert {:error, err} = Uplink.from_wire(wire)
      assert err.code == :not_an_uplink
      assert err.message =~ "Observe"
    end

    test "a Notify with no Content-Format cannot be interpreted" do
      {:ok, wire} = Wire.Response.parse({2, 5}, [{6, <<1>>}], <<0x80>>)

      assert {:error, %{code: :missing_content_format}} = Uplink.from_wire(wire)
    end
  end

  describe "from_wire/1 dispatch" do
    test "one call handles both directions" do
      send = Uplink.to_wire(%Uplink.Send{content_format: 112, payload: <<0x80>>})

      notify =
        Uplink.to_wire(%Uplink.Notify{content_format: 112, payload: <<0x80>>, observe_seq: 1})

      assert {:ok, %Uplink.Send{}} = Uplink.from_wire(send)
      assert {:ok, %Uplink.Notify{}} = Uplink.from_wire(notify)
    end
  end
end

defmodule Wick.ResponseWireTest do
  use ExUnit.Case, async: true

  alias Wick.Path
  alias Wick.Response
  alias Wick.Status
  alias Wick.Wire

  describe "to_wire/2" do
    test "a payload-free response carries no options" do
      wire = Response.to_wire(Response.changed())

      assert wire == %Wire.Response{status: :changed, payload: "", location_path: []}
      assert Wire.Response.to_coap_options(wire) == []
    end

    test "nil payload normalises to an empty binary" do
      assert Response.to_wire(%Response{status: :content, content_format: 0}).payload == ""
    end

    test "a Create response's location becomes Location-Path segments" do
      path = %Path{object_id: 1, object_instance_id: 3}

      assert Response.to_wire(Response.created(path)).location_path == ["1", "3"]
    end

    test "observe_seq is opt-in via the second argument" do
      response = Response.content(112, <<0x80>>)

      assert Response.to_wire(response).observe_seq == nil
      assert Response.to_wire(response, 0).observe_seq == 0
      assert Response.to_wire(response, 16_777_215).observe_seq == 16_777_215
    end
  end

  describe "from_wire/1" do
    test "an empty payload becomes nil, matching the constructors" do
      wire = %Wire.Response{status: :changed, payload: ""}

      assert Response.from_wire(wire) == Response.changed()
    end

    test "a non-LwM2M location path is dropped rather than erroring" do
      wire = %Wire.Response{status: :created, location_path: ["rd", "abc123"]}

      assert Response.from_wire(wire).location_path == nil
    end

    test "an error response keeps its diagnostic payload" do
      wire = %Wire.Response{status: :bad_request, payload: "missing ep"}

      assert Response.from_wire(wire) == Response.error(:bad_request, "missing ep")
    end
  end

  describe "round-trip" do
    test "every constructor survives to_wire/from_wire" do
      responses = [
        Response.changed(),
        Response.deleted(),
        Response.content(112, <<0x80>>),
        Response.created(%Path{object_id: 1, object_instance_id: 3}),
        Response.error(:not_found),
        Response.error(:bad_request, "missing required field")
      ]

      for response <- responses do
        assert response |> Response.to_wire() |> Response.from_wire() == response
      end
    end

    test "survives the full CoAP option representation" do
      response = Response.content(112, <<0x81, 0xA1, 0x02, 0x05>>)
      wire = Response.to_wire(response, 42)

      assert {:ok, parsed} =
               Wire.Response.parse(
                 Status.to_coap(wire.status),
                 Wire.Response.to_coap_options(wire),
                 wire.payload
               )

      assert parsed.observe_seq == 42
      assert Response.from_wire(parsed) == response
    end

    test "a Create response survives the full CoAP option representation" do
      response = Response.created(%Path{object_id: 1, object_instance_id: 3})
      wire = Response.to_wire(response)

      assert {:ok, parsed} =
               Wire.Response.parse(
                 Status.to_coap(wire.status),
                 Wire.Response.to_coap_options(wire),
                 wire.payload
               )

      assert Response.from_wire(parsed) == response
    end
  end
end

defmodule Wick.WireTest do
  use ExUnit.Case, async: true

  doctest Wick.Wire
  doctest Wick.Wire.Response

  alias Wick.Wire
  alias Wick.Wire.Response

  describe "option numbers" do
    test "match the CoAP registry" do
      assert Wire.observe_option() == 6
      assert Wire.location_path_option() == 8
      assert Wire.uri_path_option() == 11
      assert Wire.content_format_option() == 12
      assert Wire.uri_query_option() == 15
      assert Wire.accept_option() == 17
    end
  end

  describe "encode_uint/1 and decode_uint/1" do
    test "zero is the empty binary per RFC 7252 §3.2" do
      assert Wire.encode_uint(0) == <<>>
      assert Wire.decode_uint(<<>>) == 0
    end

    test "uses the shortest big-endian representation" do
      assert Wire.encode_uint(1) == <<1>>
      assert Wire.encode_uint(255) == <<255>>
      assert Wire.encode_uint(256) == <<1, 0>>
      assert Wire.encode_uint(0xFFFFFF) == <<255, 255, 255>>
    end

    test "round-trips across the Observe sequence space" do
      for value <- [0, 1, 42, 255, 256, 65_535, 65_536, 0xFFFFFF] do
        assert value |> Wire.encode_uint() |> Wire.decode_uint() == value
      end
    end
  end

  describe "to_coap_options/1" do
    test "orders options by number ascending" do
      wire = %Wire{
        method: :get,
        path: ["3", "0"],
        query: [{"pmin", 10}],
        content_format: 112,
        accept: 11_542,
        observe: 0
      }

      numbers = wire |> Wire.to_coap_options() |> Enum.map(&elem(&1, 0))
      assert numbers == Enum.sort(numbers)
      assert numbers == [6, 11, 11, 12, 15, 17]
    end

    test "preserves the relative order of repeated Uri-Path segments" do
      wire = %Wire{method: :get, path: ["3303", "0", "5700"]}

      assert Wire.to_coap_options(wire) == [{11, "3303"}, {11, "0"}, {11, "5700"}]
    end

    test "preserves the relative order of repeated Uri-Query parameters" do
      wire = %Wire{method: :post, query: [{"ep", "d1"}, {"lwm2m", "1.2"}, {"lt", 60}]}

      assert Wire.to_coap_options(wire) == [{15, "ep=d1"}, {15, "lwm2m=1.2"}, {15, "lt=60"}]
    end

    test "omits absent options entirely" do
      assert Wire.to_coap_options(%Wire{method: :delete, path: ["3", "0"]}) ==
               [{11, "3"}, {11, "0"}]
    end

    test "Observe: 0 encodes as an empty value, not a zero byte" do
      assert Wire.to_coap_options(%Wire{method: :get, observe: 0}) == [{6, ""}]
      assert Wire.to_coap_options(%Wire{method: :get, observe: 1}) == [{6, <<1>>}]
    end

    test "encodes float query values in shortest round-trip form" do
      wire = %Wire{method: :put, query: [{"gt", 22.5}, {"lt", 18.0}]}

      assert Wire.to_coap_options(wire) == [{15, "gt=22.5"}, {15, "lt=18.0"}]
    end

    test "emits a bare flag for a nil query value" do
      assert Wire.to_coap_options(%Wire{method: :post, query: [{"Q", nil}]}) == [{15, "Q"}]
    end
  end

  describe "parse/3" do
    test "accepts every method LwM2M uses" do
      for method <- [:get, :post, :put, :delete, :fetch, :ipatch] do
        assert {:ok, %Wire{method: ^method}} = Wire.parse(method, [], "")
      end
    end

    test "rejects methods LwM2M defines no operation for" do
      assert {:error, err} = Wire.parse(:patch, [], "")
      assert err.code == :unsupported_method
      assert err.meta == %{method: :patch}
    end

    test "ignores options Wick does not model" do
      # 23 is Block2, 3 is Uri-Host — a CoAP layer may legitimately carry both.
      assert {:ok, wire} = Wire.parse(:get, [{3, "example.org"}, {11, "3"}, {23, <<0x08>>}], "")

      assert wire.path == ["3"]
      assert wire.content_format == nil
    end

    test "distinguishes an absent Observe option from Observe: 0" do
      assert {:ok, %Wire{observe: nil}} = Wire.parse(:get, [{11, "3"}], "")
      assert {:ok, %Wire{observe: 0}} = Wire.parse(:get, [{6, ""}, {11, "3"}], "")
      assert {:ok, %Wire{observe: 1}} = Wire.parse(:get, [{6, <<1>>}, {11, "3"}], "")
    end

    test "splits query parameters on the first = only" do
      assert {:ok, wire} = Wire.parse(:post, [{15, "uri=coap://host/a=b"}], "")

      assert wire.query == [{"uri", "coap://host/a=b"}]
    end
  end

  describe "to_coap_options/1 and parse/3 round-trip" do
    test "a fully-populated wire survives the round trip" do
      original = %Wire{
        method: :fetch,
        path: [],
        query: [{"pmin", "10"}, {"Q", nil}],
        payload: <<0x81, 0xA1, 0x02, 0x05>>,
        content_format: 112,
        accept: 11_542,
        observe: 0
      }

      assert {:ok, parsed} =
               Wire.parse(original.method, Wire.to_coap_options(original), original.payload)

      assert parsed == original
    end
  end

  describe "collect/2 and first_uint/2" do
    test "collect/2 keeps order and skips other numbers" do
      assert Wire.collect([{11, "a"}, {12, <<1>>}, {11, "b"}], 11) == ["a", "b"]
      assert Wire.collect([], 11) == []
    end

    test "first_uint/2 distinguishes absent from zero" do
      assert Wire.first_uint([], 6) == nil
      assert Wire.first_uint([{6, ""}], 6) == 0
    end

    test "first_uint/2 ignores later duplicates" do
      assert Wire.first_uint([{12, <<112>>}, {12, <<60>>}], 12) == 112
    end
  end

  describe "fetch_query/2" do
    test "returns nil for a bare flag and :error when absent" do
      query = [{"ep", "device-1"}, {"Q", nil}]

      assert Wire.fetch_query(query, "ep") == {:ok, "device-1"}
      assert Wire.fetch_query(query, "Q") == {:ok, nil}
      assert Wire.fetch_query(query, "lt") == :error
    end
  end

  describe "Response.to_coap_options/1" do
    test "orders options by number ascending" do
      response = %Response{
        status: :content,
        content_format: 112,
        location_path: ["3", "0"],
        observe_seq: 7
      }

      numbers = response |> Response.to_coap_options() |> Enum.map(&elem(&1, 0))
      assert numbers == [6, 8, 8, 12]
    end

    test "an empty response carries no options" do
      assert Response.to_coap_options(%Response{status: :changed}) == []
    end

    test "observe_seq 0 encodes as an empty value" do
      assert Response.to_coap_options(%Response{status: :content, observe_seq: 0}) == [{6, ""}]
    end
  end

  describe "Response.parse/3" do
    test "rejects CoAP codes outside the LwM2M status set" do
      assert {:error, err} = Response.parse({4, 3}, [], "")
      assert err.code == :unrecognised_status
      assert err.message =~ "4.03"
      assert err.meta == %{code: {4, 3}}
    end

    test "pads the detail in the diagnostic message" do
      assert {:error, err} = Response.parse({4, 9}, [], "")
      assert err.message =~ "4.09"
    end

    test "distinguishes an absent Observe option from sequence 0" do
      assert {:ok, %Response{observe_seq: nil}} = Response.parse({2, 5}, [{12, <<112>>}], "x")
      assert {:ok, %Response{observe_seq: 0}} = Response.parse({2, 5}, [{6, ""}], "x")
    end
  end

  describe "Response round-trip" do
    test "a fully-populated response survives the round trip" do
      original = %Response{
        status: :created,
        payload: "diagnostic",
        content_format: 112,
        location_path: ["3", "0"],
        observe_seq: 42
      }

      assert {:ok, parsed} =
               Response.parse(
                 Wick.Status.to_coap(original.status),
                 Response.to_coap_options(original),
                 original.payload
               )

      assert parsed == original
    end

    test "every LwM2M status round-trips" do
      for status <- Wick.Status.all() do
        assert {:ok, %Response{status: ^status}} =
                 Response.parse(Wick.Status.to_coap(status), [], "")
      end
    end
  end
end

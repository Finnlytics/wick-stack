defmodule Wick.RequestWireTest do
  @moduledoc """
  The Device Management wire layer: `Wick.Request.to_wire/1` and `from_wire/1`.

  Two things are being pinned down here. First, that each operation maps to the method and
  options LwM2M 1.2 §6.4 specifies — the table in `Wick.Request.to_wire/1`'s docs. Second,
  that `from_wire/1` recovers the *right* operation despite several sharing a method, which
  is where the interesting failure modes live.
  """

  use ExUnit.Case, async: true

  alias Wick.Attributes
  alias Wick.Codec.SenmlCbor
  alias Wick.Codec.SenmlJson
  alias Wick.Path
  alias Wick.Request
  alias Wick.Senml.Pack
  alias Wick.Wire

  defp path!(string) do
    {:ok, path} = Path.parse(string)
    path
  end

  # Round-trip through the CoAP option representation too, not just the Wire struct —
  # that's the path real traffic takes.
  defp round_trip(request) do
    wire = Request.to_wire(request)
    {:ok, parsed} = Wire.parse(wire.method, Wire.to_coap_options(wire), wire.payload)
    Request.from_wire(parsed)
  end

  describe "Read" do
    test "is a GET on the path" do
      wire = Request.to_wire(%Request.Read{path: path!("/3/0/9")})

      assert wire.method == :get
      assert wire.path == ["3", "0", "9"]
      assert wire.payload == ""
      assert wire.accept == nil
      assert wire.observe == nil
    end

    test "carries Accept when a Content-Format is requested" do
      wire = Request.to_wire(%Request.Read{path: path!("/3"), accept_content_format: 112})

      assert Wire.to_coap_options(wire) == [{11, "3"}, {17, <<112>>}]
    end

    test "round-trips" do
      request = %Request.Read{path: path!("/3/0/9"), accept_content_format: 112}

      assert {:ok, ^request} = round_trip(request)
    end

    test "round-trips at every path depth" do
      for string <- ["/3", "/3/0", "/3/0/9", "/3/0/9/1"] do
        request = %Request.Read{path: path!(string)}
        assert {:ok, ^request} = round_trip(request)
      end
    end
  end

  describe "Write" do
    test "replace mode is a PUT" do
      wire =
        Request.to_wire(%Request.Write{
          path: path!("/3/0/14"),
          content_format: 0,
          payload: "+02:00"
        })

      assert wire.method == :put
      assert wire.content_format == 0
      assert wire.payload == "+02:00"
    end

    test "partial-update mode is a POST" do
      wire =
        Request.to_wire(%Request.Write{
          path: path!("/1/0"),
          content_format: 112,
          payload: <<0x80>>,
          mode: :partial_update
        })

      assert wire.method == :post
    end

    test "replace round-trips" do
      request = %Request.Write{path: path!("/3/0/14"), content_format: 0, payload: "+02:00"}

      assert {:ok, ^request} = round_trip(request)
    end

    test "partial-update round-trips on an Object Instance path" do
      request = %Request.Write{
        path: path!("/1/0"),
        content_format: 112,
        payload: <<0x80>>,
        mode: :partial_update
      }

      assert {:ok, ^request} = round_trip(request)
    end

    test "an empty payload is still a Write when Content-Format is present" do
      request = %Request.Write{path: path!("/3/0/14"), content_format: 0, payload: ""}

      assert {:ok, %Request.Write{payload: ""}} = round_trip(request)
    end
  end

  describe "Execute" do
    test "is a POST with the arguments as a text/plain body" do
      wire = Request.to_wire(%Request.Execute{path: path!("/3/0/4"), arguments: "1='delay'"})

      assert wire.method == :post
      assert wire.payload == "1='delay'"
      assert wire.content_format == 0
    end

    test "sends no body and no Content-Format without arguments" do
      wire = Request.to_wire(%Request.Execute{path: path!("/3/0/4")})

      assert wire.payload == ""
      assert wire.content_format == nil
      assert Wire.to_coap_options(wire) == [{11, "3"}, {11, "0"}, {11, "4"}]
    end

    test "treats empty-string arguments as no arguments" do
      wire = Request.to_wire(%Request.Execute{path: path!("/3/0/4"), arguments: ""})

      assert wire.content_format == nil
    end

    test "round-trips with and without arguments" do
      with_args = %Request.Execute{path: path!("/3/0/4"), arguments: "1='x'"}
      without = %Request.Execute{path: path!("/3/0/4"), arguments: nil}

      assert {:ok, ^with_args} = round_trip(with_args)
      assert {:ok, ^without} = round_trip(without)
    end
  end

  describe "Discover" do
    test "is a GET asking for application/link-format" do
      wire = Request.to_wire(%Request.Discover{path: path!("/3")})

      assert wire.method == :get
      assert wire.accept == 40
    end

    test "round-trips, and is not confused with a Read" do
      request = %Request.Discover{path: path!("/3/0")}

      assert {:ok, ^request} = round_trip(request)
    end

    test "a Read that happens to accept link-format is read back as a Discover" do
      # This is inherent to LwM2M's wire encoding, not a bug: Discover *is* a GET with
      # Accept: 40. Pinned so the behaviour is a decision rather than a surprise.
      request = %Request.Read{path: path!("/3"), accept_content_format: 40}

      assert {:ok, %Request.Discover{}} = round_trip(request)
    end
  end

  describe "Create" do
    test "is a POST on the Object path" do
      wire =
        Request.to_wire(%Request.Create{
          path: path!("/1"),
          content_format: 112,
          payload: <<0x81>>
        })

      assert wire.method == :post
      assert wire.path == ["1"]
    end

    test "round-trips" do
      request = %Request.Create{path: path!("/1"), content_format: 112, payload: <<0x81>>}

      assert {:ok, ^request} = round_trip(request)
    end
  end

  describe "Delete" do
    test "is a DELETE with no body" do
      wire = Request.to_wire(%Request.Delete{path: path!("/1/2")})

      assert wire.method == :delete
      assert wire.payload == ""
      assert wire.content_format == nil
    end

    test "round-trips" do
      request = %Request.Delete{path: path!("/1/2")}

      assert {:ok, ^request} = round_trip(request)
    end
  end

  describe "WriteAttributes" do
    test "is a PUT with attributes in the query and no body" do
      wire =
        Request.to_wire(%Request.WriteAttributes{
          path: path!("/3303/0/5700"),
          attributes: %Attributes{pmin: 10, pmax: 60, st: 1}
        })

      assert wire.method == :put
      assert wire.payload == ""
      assert wire.content_format == nil
      assert wire.query == [{"pmin", 10}, {"pmax", 60}, {"st", 1}]
    end

    test "round-trips" do
      request = %Request.WriteAttributes{
        path: path!("/3303/0/5700"),
        attributes: %Attributes{pmin: 10, pmax: 60, gt: 25.5}
      }

      assert {:ok, ^request} = round_trip(request)
    end

    test "round-trips a clear" do
      request = %Request.WriteAttributes{
        path: path!("/3303/0"),
        attributes: %Attributes{pmin: :clear}
      }

      assert {:ok, ^request} = round_trip(request)
    end

    test "an attribute set with no attributes is still a valid PUT" do
      request = %Request.WriteAttributes{path: path!("/3"), attributes: %Attributes{}}

      assert {:ok, ^request} = round_trip(request)
    end

    test "a malformed attribute surfaces as an error, not a Write" do
      {:ok, wire} = Wire.parse(:put, [{11, "3"}, {15, "pmin=soon"}], "")

      assert {:error, err} = Request.from_wire(wire)
      assert err.code == :invalid_attribute
    end
  end

  describe "ReadComposite" do
    test "is a FETCH on the root carrying a SenML path list" do
      paths = [path!("/3/0/9"), path!("/3303/0/5700")]
      wire = Request.to_wire(%Request.ReadComposite{paths: paths, accept_content_format: 112})

      assert wire.method == :fetch
      assert wire.path == []
      assert wire.content_format == 112
      assert {:ok, pack} = SenmlCbor.decode(wire.payload, [])
      assert {:ok, ^paths} = Pack.to_paths(pack)
    end

    test "encodes the body with the codec named by :content_format" do
      wire =
        Request.to_wire(%Request.ReadComposite{paths: [path!("/3/0/9")], content_format: 110})

      assert wire.content_format == 110
      assert {:ok, _pack} = SenmlJson.decode(wire.payload, [])
    end

    test "round-trips through both SenML formats" do
      for content_format <- [110, 112] do
        request = %Request.ReadComposite{
          paths: [path!("/3/0/9"), path!("/6/0/0")],
          content_format: content_format,
          accept_content_format: 112
        }

        assert {:ok, ^request} = round_trip(request)
      end
    end

    test "rejects a non-SenML body format at encode time" do
      request = %Request.ReadComposite{paths: [path!("/3/0/9")], content_format: 0}

      assert_raise ArgumentError, ~r/SenML Content-Format/, fn -> Request.to_wire(request) end
    end

    test "rejects a non-SenML body format at decode time" do
      {:ok, wire} = Wire.parse(:fetch, [{12, <<0>>}], "/3/0/9")

      assert {:error, err} = Request.from_wire(wire)
      assert err.code == :unsupported_operation
    end

    test "a FETCH with no Content-Format is an error, not a crash" do
      {:ok, wire} = Wire.parse(:fetch, [], "")

      assert {:error, err} = Request.from_wire(wire)
      assert err.code == :unsupported_operation
    end

    test "a body whose records carry no valid path is an error" do
      {:ok, pack_bytes} =
        SenmlCbor.encode(Pack.new([%Wick.Senml.Record{name: "/not-a-path"}]),
          allow_no_value: true
        )

      {:ok, wire} =
        Wire.parse(:fetch, [{12, <<112>>}], IO.iodata_to_binary(pack_bytes))

      assert {:error, err} = Request.from_wire(wire)
      assert err.code == :invalid_path
    end
  end

  describe "WriteComposite" do
    test "is an iPATCH on the root" do
      wire = Request.to_wire(%Request.WriteComposite{content_format: 112, payload: <<0x81>>})

      assert wire.method == :ipatch
      assert wire.path == []
      assert wire.content_format == 112
    end

    test "round-trips" do
      request = %Request.WriteComposite{content_format: 112, payload: <<0x81, 0xA1>>}

      assert {:ok, ^request} = round_trip(request)
    end

    test "an iPATCH with no Content-Format is an error" do
      {:ok, wire} = Wire.parse(:ipatch, [], "body")

      assert {:error, err} = Request.from_wire(wire)
      assert err.code == :unsupported_operation
    end
  end

  describe "Observe and CancelObserve" do
    test "Observe is a GET with Observe: 0" do
      wire = Request.to_wire(%Request.Observe{path: path!("/3303/0/5700")})

      assert wire.method == :get
      assert wire.observe == 0
    end

    test "CancelObserve is a GET with Observe: 1" do
      wire = Request.to_wire(%Request.CancelObserve{path: path!("/3303/0/5700")})

      assert wire.method == :get
      assert wire.observe == 1
    end

    test "both round-trip and stay distinguishable" do
      observe = %Request.Observe{path: path!("/3303/0/5700"), accept_content_format: 112}
      cancel = %Request.CancelObserve{path: path!("/3303/0/5700")}

      assert {:ok, ^observe} = round_trip(observe)
      assert {:ok, ^cancel} = round_trip(cancel)
    end

    test "Observe wins over Accept: 40 — an observed Discover is not a thing" do
      wire = %Wire{method: :get, path: ["3"], accept: 40, observe: 0}

      assert {:ok, %Request.Observe{}} = Request.from_wire(wire)
    end
  end

  describe "ObserveComposite" do
    test "is a FETCH with Observe: 0 and a SenML path list" do
      wire = Request.to_wire(%Request.ObserveComposite{paths: [path!("/3/0/9")]})

      assert wire.method == :fetch
      assert wire.observe == 0
      assert wire.payload != ""
    end

    test "round-trips and stays distinct from ReadComposite" do
      paths = [path!("/3/0/9"), path!("/6/0/0")]
      observe = %Request.ObserveComposite{paths: paths, accept_content_format: 112}
      read = %Request.ReadComposite{paths: paths, accept_content_format: 112}

      assert {:ok, ^observe} = round_trip(observe)
      assert {:ok, ^read} = round_trip(read)
    end
  end

  describe "from_wire/1 — POST disambiguation by path depth" do
    test "Object path is a Create" do
      {:ok, wire} = Wire.parse(:post, [{11, "1"}, {12, <<112>>}], <<0x81>>)

      assert {:ok, %Request.Create{}} = Request.from_wire(wire)
    end

    test "Object Instance path is a partial-update Write" do
      {:ok, wire} = Wire.parse(:post, [{11, "1"}, {11, "0"}, {12, <<112>>}], <<0x81>>)

      assert {:ok, %Request.Write{mode: :partial_update}} = Request.from_wire(wire)
    end

    test "Resource path is an Execute" do
      {:ok, wire} = Wire.parse(:post, [{11, "3"}, {11, "0"}, {11, "4"}], "")

      assert {:ok, %Request.Execute{}} = Request.from_wire(wire)
    end

    test "Resource Instance path is not a defined POST target" do
      {:ok, wire} = Wire.parse(:post, [{11, "3"}, {11, "0"}, {11, "4"}, {11, "0"}], "")

      assert {:error, err} = Request.from_wire(wire)
      assert err.code == :unsupported_operation
      assert err.meta == %{path: "/3/0/4/0"}
    end
  end

  describe "from_wire/1 — non-LwM2M paths" do
    test "registration and bootstrap traffic is rejected as an invalid path" do
      for segments <- [["rd"], ["rd", "r0"], ["bs"], ["bs-finish"]] do
        {:ok, wire} = Wire.parse(:post, Enum.map(segments, &{11, &1}), "")

        assert {:error, %{code: :invalid_path}} = Request.from_wire(wire)
      end
    end

    test "an empty path on a non-composite method is an invalid path" do
      {:ok, wire} = Wire.parse(:get, [], "")

      assert {:error, %{code: :invalid_path}} = Request.from_wire(wire)
    end
  end
end

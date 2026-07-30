defmodule WickDemoServer.WebTest do
  @moduledoc """
  The HTTP surface, driven through `Plug.Test` rather than over a socket.

  No device is registered here, so this covers the router's own behaviour: routing, parameter
  validation, and the distinction the API rests on — a `4xx` means *you asked wrongly*, while a
  `2xx` carrying an LwM2M error status means *the device said no*. Conflating those would leave
  the UI unable to tell a bad request from a `4.04`.

  The end-to-end path, where operations actually reach a device, is covered by
  `wick_demo_client`'s `test/device_management_test.exs`.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias WickDemoServer.Events
  alias WickDemoServer.Web.Api
  alias WickDemoServer.Web.Router

  @opts Router.init([])

  defp get(path), do: :get |> conn(path) |> Router.call(@opts)

  defp post(path, body) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "the UI" do
    test "GET / serves a complete HTML document" do
      conn = get("/")

      assert conn.status == 200
      assert ["text/html" <> _charset] = get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "<!doctype html>"
      assert conn.resp_body =~ "</html>"
      assert conn.resp_body =~ "Wick"
    end

    test "the page is self-contained — no external scripts or stylesheets to fetch" do
      html = get("/").resp_body

      refute html =~ ~r/<script[^>]+src=/
      refute html =~ ~r/<link[^>]+rel=["']stylesheet/
    end
  end

  describe "read endpoints" do
    test "registrations lists what the store holds" do
      conn = get("/api/registrations")

      assert conn.status == 200
      assert %{"registrations" => registrations} = body(conn)
      assert is_list(registrations)
    end

    test "summary reports the CoAP port and live counts" do
      assert %{"port" => port, "registrations" => _r, "observations" => _o} =
               body(get("/api/summary"))

      assert is_integer(port)
    end

    test "observations and readings are always lists" do
      assert %{"observations" => []} = body(get("/api/observations"))
      assert %{"readings" => readings} = body(get("/api/readings"))
      assert is_list(readings)
    end

    test "an unknown registration is 404" do
      conn = get("/api/registrations/nope")

      assert conn.status == 404
      assert %{"error" => error} = body(conn)
      assert error =~ "nope"
    end

    test "an unrouted path is 404 with a useful message" do
      conn = get("/api/nothing-here")

      assert conn.status == 404
      assert body(conn)["error"] =~ "GET /api/nothing-here"
    end
  end

  describe "parameter validation" do
    test "a missing path is rejected before any protocol work happens" do
      for op <- ["read", "write", "execute", "discover", "delete", "attributes"] do
        conn = post("/api/registrations/r0/#{op}", %{})

        assert conn.status == 400, "#{op} accepted a request with no path"
        assert body(conn)["error"] =~ "path"
      end
    end

    test "an unparseable path is rejected" do
      conn = post("/api/registrations/r0/read", %{path: "/not-a-path"})

      assert conn.status == 400
      assert body(conn)["error"] =~ "invalid path component"
    end

    test "a write with a value that does not match its type is rejected" do
      conn =
        post("/api/registrations/r0/write", %{
          path: "/3/0/9",
          value: %{type: "float", value: "warm"}
        })

      assert conn.status == 400
      assert body(conn)["error"] =~ "not a float"
    end

    test "an unknown value type is rejected" do
      conn =
        post("/api/registrations/r0/write", %{path: "/3/0/9", value: %{type: "wat", value: 1}})

      assert conn.status == 400
      assert body(conn)["error"] =~ "unsupported value type"
    end

    test "an unknown write mode is rejected" do
      conn =
        post("/api/registrations/r0/write", %{
          path: "/3/0/9",
          value: %{type: "integer", value: 1},
          mode: "sideways"
        })

      assert conn.status == 400
      assert body(conn)["error"] =~ "sideways"
    end

    test "a bad attribute value is rejected" do
      conn =
        post("/api/registrations/r0/attributes", %{
          path: "/3/0/9",
          attributes: %{"pmin" => "soon"}
        })

      assert conn.status == 400
    end

    test "cancel requires a handle" do
      conn = post("/api/registrations/r0/cancel", %{path: "/3/0/9"})

      assert conn.status == 400
      assert body(conn)["error"] =~ "handle"
    end

    test "non-integer resource ids in a create are rejected" do
      conn =
        post("/api/registrations/r0/create", %{
          path: "/3303",
          resources: %{"temperature" => %{type: "float", value: 1.0}}
        })

      assert conn.status == 400
      assert body(conn)["error"] =~ "integers"
    end
  end

  describe "unknown registrations" do
    test "an operation against a registration that does not exist is 404, not a crash" do
      conn = post("/api/registrations/ghost/read", %{path: "/3/0/0"})

      assert conn.status == 404
      assert body(conn)["error"] =~ "unknown registration"
    end
  end

  describe "Api.parse_value/1" do
    test "accepts both native JSON types and their string forms" do
      assert Api.parse_value(%{"type" => "integer", "value" => 42}) == {:ok, {:integer, 42}}
      assert Api.parse_value(%{"type" => "integer", "value" => "42"}) == {:ok, {:integer, 42}}
      assert Api.parse_value(%{"type" => "float", "value" => 1.5}) == {:ok, {:float, 1.5}}
      assert Api.parse_value(%{"type" => "float", "value" => "1.5"}) == {:ok, {:float, 1.5}}
      assert Api.parse_value(%{"type" => "boolean", "value" => true}) == {:ok, {:boolean, true}}
      assert Api.parse_value(%{"type" => "boolean", "value" => "true"}) == {:ok, {:boolean, true}}
    end

    test "an integer JSON value widens to a float when a float was asked for" do
      assert Api.parse_value(%{"type" => "float", "value" => 42}) == {:ok, {:float, 42.0}}
    end

    test "opaque round-trips through Base64" do
      encoded = Api.value({:opaque, <<0xDE, 0xAD, 0xBE, 0xEF>>})

      assert encoded == %{type: "opaque", value: "3q2+7w=="}

      assert Api.parse_value(%{"type" => "opaque", "value" => encoded.value}) ==
               {:ok, {:opaque, <<0xDE, 0xAD, 0xBE, 0xEF>>}}
    end

    test "invalid Base64 is rejected rather than stored as garbage" do
      assert {:error, message} = Api.parse_value(%{"type" => "opaque", "value" => "not base64!"})
      assert message =~ "Base64"
    end

    test "objlnk round-trips through its SenML form" do
      assert Api.value({:objlnk, {1, 0}}) == %{type: "objlnk", value: "1:0"}
      assert Api.parse_value(%{"type" => "objlnk", "value" => "1:0"}) == {:ok, {:objlnk, {1, 0}}}
      assert {:error, _malformed} = Api.parse_value(%{"type" => "objlnk", "value" => "1"})
    end

    test "a payload with no type or value is rejected" do
      assert {:error, _message} = Api.parse_value(%{})
    end
  end

  describe "Api.parse_attributes/1" do
    test "absent means leave alone, null means clear, a value means set" do
      assert {:ok, attrs} =
               Api.parse_attributes(%{"pmin" => 10, "pmax" => nil, "st" => "1.5"})

      assert attrs.pmin == 10
      assert attrs.pmax == :clear
      assert attrs.st == 1.5
      assert attrs.gt == nil
    end

    test "property attributes are ignored — only a client reports those" do
      assert {:ok, attrs} = Api.parse_attributes(%{"dim" => 3, "ver" => "1.1"})

      assert attrs.dim == nil
      assert attrs.ver == nil
    end
  end

  describe "Api.handle_key/1" do
    test "is stable for the same handle and differs between handles" do
      handle = {{{127, 0, 0, 1}, 5683}, <<1, 2, 3>>}
      other = {{{127, 0, 0, 1}, 5683}, <<9, 9, 9>>}

      assert Api.handle_key(handle) == Api.handle_key(handle)
      refute Api.handle_key(handle) == Api.handle_key(other)
      assert is_binary(Api.handle_key(handle))
    end
  end

  describe "Events" do
    test "publish reaches a subscriber and carries the tag plus a timestamp" do
      :ok = Events.subscribe()
      :ok = Events.publish(:register, endpoint_name: "device-1", registration_id: "r0")

      assert_receive {:wick_demo_event, event}
      assert event.event == :register
      assert event.endpoint_name == "device-1"
      assert is_integer(event.at)

      Events.unsubscribe()
    end

    test "an explicit timestamp is preserved" do
      :ok = Events.subscribe()
      :ok = Events.publish(:notify, at: 42)

      assert_receive {:wick_demo_event, %{at: 42}}
      Events.unsubscribe()
    end

    test "unsubscribing stops delivery" do
      :ok = Events.subscribe()
      :ok = Events.unsubscribe()
      :ok = Events.publish(:register, [])

      refute_receive {:wick_demo_event, _event}, 100
    end

    test "publishing with nobody listening is a no-op, not an error" do
      assert Events.publish(:notify, []) == :ok
    end

    test "subscriber_count reflects live subscribers" do
      before = Events.subscriber_count()
      :ok = Events.subscribe()

      assert Events.subscriber_count() == before + 1

      Events.unsubscribe()
      assert Events.subscriber_count() == before
    end
  end

  describe "Api.event/1" do
    test "renders peers, paths, and readings into JSON-friendly shapes" do
      {:ok, path} = Wick.Path.parse("/3303/0/5700")

      event =
        Api.event(%{
          event: :notify,
          at: 1,
          peer: {{127, 0, 0, 1}, 5683},
          paths: [path],
          readings: [{"/3303/0/5700", 22.5}]
        })

      assert event.peer == "127.0.0.1:5683"
      assert event.paths == ["/3303/0/5700"]
      assert event.readings == [%{path: "/3303/0/5700", value: 22.5}]
      assert Jason.encode!(event)
    end
  end
end

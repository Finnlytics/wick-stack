defmodule Wick.RegistrationTest do
  use ExUnit.Case, async: true

  alias Wick.CoreLink
  alias Wick.Registration
  alias Wick.Registration.Deregister
  alias Wick.Registration.Record
  alias Wick.Registration.Register
  alias Wick.Registration.Server
  alias Wick.Registration.Store
  alias Wick.Registration.Update
  alias Wick.Wire

  describe "to_wire/1 — Register" do
    test "happy path includes ep, lwm2m, and payload" do
      req = %Register{
        endpoint_name: "device-1",
        objects: [%CoreLink.Link{target: "/3/0"}]
      }

      assert %Wire{
               method: :post,
               path: ["rd"],
               query: [{"ep", "device-1"}, {"lwm2m", "1.2"}],
               payload: "</3/0>",
               content_format: 40
             } = Registration.to_wire(req)
    end

    test "optional fields land in the query in spec order" do
      req = %Register{
        endpoint_name: "dev",
        lifetime: 60,
        binding: "U",
        queue_mode: true,
        sms_number: "+447700900000",
        profile_id: "p1",
        objects: []
      }

      wire = Registration.to_wire(req)

      assert wire.query == [
               {"ep", "dev"},
               {"lwm2m", "1.2"},
               {"lt", 60},
               {"b", "U"},
               {"Q", nil},
               {"sms", "+447700900000"},
               {"pid", "p1"}
             ]
    end
  end

  describe "to_wire/1 — Update" do
    test "empty objects → no payload, no Content-Format" do
      wire = Registration.to_wire(%Update{location: "r1", lifetime: 120})
      assert wire.method == :post
      assert wire.path == ["rd", "r1"]
      assert wire.payload == ""
      assert wire.content_format == nil
      assert wire.query == [{"lt", 120}]
    end

    test "with new objects: payload + Content-Format set" do
      wire =
        Registration.to_wire(%Update{
          location: "r1",
          objects: [%CoreLink.Link{target: "/3/0"}]
        })

      assert wire.payload == "</3/0>"
      assert wire.content_format == 40
    end
  end

  describe "to_wire/1 — Deregister" do
    test "method DELETE on /rd/<id>, empty payload" do
      assert %Wire{method: :delete, path: ["rd", "r42"], payload: ""} =
               Registration.to_wire(%Deregister{location: "r42"})
    end
  end

  describe "Server.handle/2 — Register" do
    test "stores the record, returns 2.01 Created with Location-Path" do
      req = %{
        method: :post,
        path: ["rd"],
        query: [{"ep", "device-1"}, {"lt", "60"}, {"lwm2m", "1.2"}],
        payload: "</3/0>,</5>",
        peer: {{127, 0, 0, 1}, 60_000},
        now: 1_000
      }

      {%Server.Response{code: :created, location_path: ["rd", id]}, store} =
        Server.handle(req, Store.new())

      assert String.starts_with?(id, "r")
      assert {:ok, %Record{endpoint_name: "device-1", lifetime: 60}} = Store.fetch(store, id)
    end

    test "missing ep → 4.00 Bad Request" do
      req = %{
        method: :post,
        path: ["rd"],
        query: [],
        payload: "</3/0>",
        peer: nil,
        now: 0
      }

      {%Server.Response{code: :bad_request}, _} = Server.handle(req, Store.new())
    end

    test "empty payload → 4.00 Bad Request" do
      req = %{
        method: :post,
        path: ["rd"],
        query: [{"ep", "dev"}],
        payload: "",
        peer: nil,
        now: 0
      }

      {%Server.Response{code: :bad_request, diagnostic: msg}, _} = Server.handle(req, Store.new())
      assert msg =~ "missing registration payload"
    end

    test "re-registering the same endpoint replaces the previous record" do
      store = Store.new()

      base = %{
        method: :post,
        path: ["rd"],
        query: [{"ep", "device-1"}],
        payload: "</3/0>",
        peer: nil,
        now: 0
      }

      {%Server.Response{code: :created, location_path: ["rd", id1]}, store} =
        Server.handle(base, store)

      {%Server.Response{code: :created, location_path: ["rd", id2]}, store} =
        Server.handle(base, store)

      refute id1 == id2
      assert :error = Store.fetch(store, id1)
      assert {:ok, _} = Store.fetch(store, id2)
    end
  end

  describe "Server.handle/2 — Update" do
    setup do
      register_req = %{
        method: :post,
        path: ["rd"],
        query: [{"ep", "dev"}],
        payload: "</3/0>",
        peer: nil,
        now: 1_000
      }

      {response, store} = Server.handle(register_req, Store.new())
      [_, id] = response.location_path
      %{id: id, store: store}
    end

    test "updates lifetime + updated_at", ctx do
      update_req = %{
        method: :post,
        path: ["rd", ctx.id],
        query: [{"lt", "120"}],
        payload: "",
        peer: nil,
        now: 5_000
      }

      {%Server.Response{code: :changed}, store} = Server.handle(update_req, ctx.store)
      assert {:ok, %Record{lifetime: 120, updated_at: 5_000}} = Store.fetch(store, ctx.id)
    end

    test "unknown location → 4.04 Not Found", ctx do
      req = %{
        method: :post,
        path: ["rd", "nope"],
        query: [],
        payload: "",
        peer: nil,
        now: 0
      }

      assert {%Server.Response{code: :not_found}, _} = Server.handle(req, ctx.store)
    end
  end

  describe "Server.handle/2 — Deregister" do
    test "removes the record, returns 2.02 Deleted" do
      register_req = %{
        method: :post,
        path: ["rd"],
        query: [{"ep", "dev"}],
        payload: "</3/0>",
        peer: nil,
        now: 0
      }

      {response, store} = Server.handle(register_req, Store.new())
      [_, id] = response.location_path

      dereg = %{method: :delete, path: ["rd", id], query: [], payload: "", peer: nil, now: 0}
      {%Server.Response{code: :deleted}, store} = Server.handle(dereg, store)

      assert :error = Store.fetch(store, id)
    end

    test "unknown location → 4.04 Not Found" do
      req = %{method: :delete, path: ["rd", "nope"], query: [], payload: "", peer: nil, now: 0}
      assert {%Server.Response{code: :not_found}, _} = Server.handle(req, Store.new())
    end
  end

  describe "Server.handle/2 — unknown route" do
    test "anything else → 4.04 Not Found" do
      req = %{method: :get, path: ["foo"], query: [], payload: "", peer: nil, now: 0}
      assert {%Server.Response{code: :not_found}, _} = Server.handle(req, Store.new())
    end
  end
end

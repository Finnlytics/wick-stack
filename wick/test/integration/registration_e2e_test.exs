defmodule Wick.Integration.RegistrationE2ETest do
  @moduledoc """
  End-to-end test of the LwM2M Registration interface over WickCoap.Endpoint.

  This is the first test where Wick and WickCoap exercise each other in real CoAP
  traffic, and the closest thing to a demo server in the codebase so far. The flow:

      1. Spin up a WickCoap server bound to an ephemeral UDP port. Its handler is
         `Wick.Test.CoapRegistrationHandler`, which dispatches `/rd*` requests through
         `Wick.Registration.Server`.
      2. Build a Register message via `Wick.Registration.to_wire/1`, hand it to the
         client endpoint as a CoAP CON POST, and assert the server returns
         `2.01 Created` with a `Location-Path`.
      3. Send an Update with a new lifetime, assert `2.04 Changed`.
      4. Send a Deregister, assert `2.02 Deleted`.

  The test exercises every public path in `Wick.Registration` and the new
  test-support adapter. If anything regresses end-to-end, this test will catch it
  before the demo server is built.
  """

  use ExUnit.Case, async: false

  alias Wick.CoreLink
  alias Wick.Registration
  alias Wick.Registration.Deregister
  alias Wick.Registration.Register
  alias Wick.Registration.Store
  alias Wick.Registration.Update
  alias Wick.Test.CoapRegistrationHandler
  alias Wick.Wire
  alias WickCoap.Endpoint
  alias WickCoap.Message
  alias WickCoap.Option

  setup do
    {:ok, store} = CoapRegistrationHandler.start_store()

    {:ok, server} =
      Endpoint.start_link(
        handler: CoapRegistrationHandler,
        handler_state: %{store: store}
      )

    {:ok, client} = Endpoint.start_link([])

    on_exit(fn ->
      stop_quietly(client)
      stop_quietly(server)
    end)

    %{server: server, client: client, store: store}
  end

  describe "Register / Update / Deregister round-trip" do
    test "happy path against WickCoap.Endpoint", ctx do
      peer = {{127, 0, 0, 1}, Endpoint.port(ctx.server)}

      # ── 1. Register ─────────────────────────────────────────────────────────
      reg =
        Registration.to_wire(%Register{
          endpoint_name: "device-1",
          lifetime: 60,
          binding: "U",
          objects: [
            %CoreLink.Link{target: "/3/0"},
            %CoreLink.Link{target: "/5"}
          ]
        })

      assert {:ok, register_response} = send_wire(ctx.client, peer, reg)
      assert register_response.code == :created
      location = location_path(register_response)
      assert [<<"rd">>, location_id] = location
      assert is_binary(location_id)
      assert byte_size(location_id) > 0

      # ── 2. Update ───────────────────────────────────────────────────────────
      upd =
        Registration.to_wire(%Update{
          location: location_id,
          lifetime: 120
        })

      assert {:ok, update_response} = send_wire(ctx.client, peer, upd)
      assert update_response.code == :changed

      # Store side-effect: lifetime is now 120.
      assert %{lifetime: 120} =
               Agent.get(ctx.store, fn store ->
                 {:ok, record} = Store.fetch(store, location_id)
                 record
               end)

      # ── 3. Deregister ──────────────────────────────────────────────────────
      dereg = Registration.to_wire(%Deregister{location: location_id})

      assert {:ok, dereg_response} = send_wire(ctx.client, peer, dereg)
      assert dereg_response.code == :deleted

      # Now the location is gone.
      assert :error =
               Agent.get(ctx.store, fn store ->
                 Store.fetch(store, location_id)
               end)
    end

    test "missing ep on Register → 4.00 Bad Request", ctx do
      peer = {{127, 0, 0, 1}, Endpoint.port(ctx.server)}

      # Build a register wire spec manually with no ep query.
      wire = %Wire{
        method: :post,
        path: ["rd"],
        query: [{"lwm2m", "1.2"}],
        payload: "</3/0>",
        content_format: CoreLink.content_format()
      }

      assert {:ok, response} = send_wire(ctx.client, peer, wire)
      assert response.code == :bad_request
      assert response.payload =~ "ep"
    end

    test "Update to unknown location → 4.04 Not Found", ctx do
      peer = {{127, 0, 0, 1}, Endpoint.port(ctx.server)}

      upd =
        Registration.to_wire(%Update{
          location: "does-not-exist",
          lifetime: 60
        })

      assert {:ok, response} = send_wire(ctx.client, peer, upd)
      assert response.code == :not_found
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp send_wire(client, peer, %Wire{} = wire) do
    request = %Message{
      type: :con,
      code: wire.method,
      message_id: 0,
      token: <<>>,
      options: Enum.map(Wire.to_coap_options(wire), fn {n, v} -> Option.new(n, v) end),
      payload: wire.payload
    }

    Endpoint.request(client, peer, request, timeout: 2_000)
  end

  defp location_path(%Message{options: options}) do
    options
    |> Enum.filter(&(&1.number == Wire.location_path_option()))
    |> Enum.map(& &1.value)
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: Endpoint.stop(pid)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end

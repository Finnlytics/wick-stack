defmodule WickDemoServerTest do
  use ExUnit.Case, async: false

  alias Wick.CoreLink
  alias Wick.Registration
  alias Wick.Registration.Deregister
  alias Wick.Registration.Register
  alias Wick.Registration.Update
  alias WickCoap.Endpoint
  alias WickCoap.Message

  setup do
    # The app is already started via Application; we just need its port for client
    # exchanges. Clear the store between tests so each runs against a fresh state.
    clear_store()
    :ok
  end

  describe "boot" do
    test "the demo server is up and listening on an ephemeral port" do
      port = WickDemoServer.port()
      assert is_integer(port) and port > 0
    end

    test "registrations list is initially empty" do
      assert WickDemoServer.registrations() == []
    end
  end

  describe "Register / Update / Deregister round-trip" do
    test "register / update / deregister against the running app" do
      {:ok, client} = Endpoint.start_link([])
      peer = {{127, 0, 0, 1}, WickDemoServer.port()}

      reg =
        Registration.to_wire(%Register{
          endpoint_name: "device-smoke",
          lifetime: 60,
          objects: [%CoreLink.Link{target: "/3/0"}]
        })

      assert {:ok, response} = send_wire(client, peer, reg)
      assert response.code == :created
      [<<"rd">>, location_id] = location_path(response)
      assert is_binary(location_id) and byte_size(location_id) > 0

      # Store reflects the new registration
      assert [record] = WickDemoServer.registrations()
      assert record.endpoint_name == "device-smoke"
      assert record.lifetime == 60

      # Update — change lifetime
      upd = Registration.to_wire(%Update{location: location_id, lifetime: 120})
      assert {:ok, response} = send_wire(client, peer, upd)
      assert response.code == :changed
      assert [%{lifetime: 120}] = WickDemoServer.registrations()

      # Deregister
      dereg = Registration.to_wire(%Deregister{location: location_id})
      assert {:ok, response} = send_wire(client, peer, dereg)
      assert response.code == :deleted

      assert WickDemoServer.registrations() == []
      Endpoint.stop(client)
    end

    test "the reaper evicts expired registrations" do
      {:ok, client} = Endpoint.start_link([])
      peer = {{127, 0, 0, 1}, WickDemoServer.port()}

      # 1-second lifetime → expired ~1s after the Update timestamp; reaper interval is
      # 100ms in test config so eviction lands within ~1.1s. We wait 1.5s to be safe.
      reg =
        Registration.to_wire(%Register{
          endpoint_name: "device-shortlived",
          lifetime: 1,
          objects: [%CoreLink.Link{target: "/3/0"}]
        })

      assert {:ok, response} = send_wire(client, peer, reg)
      assert response.code == :created
      assert length(WickDemoServer.registrations()) == 1

      Process.sleep(1_500)

      assert WickDemoServer.registrations() == []
      Endpoint.stop(client)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp send_wire(client, peer, %Wick.Wire{} = wire) do
    request = WickDemoServer.Coap.to_message(wire)
    Endpoint.request(client, peer, request, timeout: 2_000)
  end

  defp location_path(%Message{options: options}) do
    options
    |> Enum.filter(&(&1.number == Wick.Wire.location_path_option()))
    |> Enum.map(& &1.value)
  end

  defp clear_store do
    for record <- WickDemoServer.registrations() do
      dereg = Registration.to_wire(%Deregister{location: record.location_id})
      {:ok, client} = Endpoint.start_link([])
      send_wire(client, {{127, 0, 0, 1}, WickDemoServer.port()}, dereg)
      Endpoint.stop(client)
    end
  end
end

defmodule WickDemoClientTest do
  use ExUnit.Case, async: false

  # The application starts WickDemoClient.Endpoint + WickDemoClient.Registrar.
  # `autostart: false` (from config/test.exs) keeps the Registrar idle so each test
  # can drive registration explicitly. The wick_demo_server app is started here too —
  # it binds an ephemeral port that we patch into the client's runtime config before
  # the Registrar's first Register call.

  setup_all do
    {:ok, _} = Application.ensure_all_started(:wick_demo_server)
    server_port = WickDemoServer.port()

    Application.put_env(:wick_demo_client, :server_host, {127, 0, 0, 1})
    Application.put_env(:wick_demo_client, :server_port, server_port)

    :ok
  end

  setup do
    # Each test starts from a clean state: drop any previous registration cleanly.
    if match?({:registered, _}, WickDemoClient.status()) do
      WickDemoClient.deregister()
    end

    :ok
  end

  describe "Registrar lifecycle" do
    test "register → server has the record" do
      assert :ok = WickDemoClient.register()
      assert {:registered, location_id} = WickDemoClient.status()
      assert is_binary(location_id) and byte_size(location_id) > 0

      assert [record] = WickDemoServer.registrations()
      assert record.endpoint_name == "wick-demo-client-test"
      assert record.lifetime == 60
      # Object 3 instance from the client should appear in the stored record.
      assert Enum.any?(record.objects, &(&1.target == "/3/0"))
    end

    test "update → server's record advances updated_at" do
      assert :ok = WickDemoClient.register()
      [original] = WickDemoServer.registrations()

      # Sleep at least one monotonic-time tick so updated_at can actually move.
      Process.sleep(15)
      assert :ok = WickDemoClient.update()

      [refreshed] = WickDemoServer.registrations()
      assert refreshed.location_id == original.location_id
      assert refreshed.updated_at >= original.updated_at + 10
    end

    test "deregister → server forgets the record" do
      assert :ok = WickDemoClient.register()
      assert {:registered, _} = WickDemoClient.status()

      assert :ok = WickDemoClient.deregister()
      assert :idle = WickDemoClient.status()
      assert WickDemoServer.registrations() == []
    end

    test "update without prior register → {:error, :not_registered}" do
      assert :idle = WickDemoClient.status()
      assert {:error, :not_registered} = WickDemoClient.update()
    end
  end

  describe "Reaper resilience" do
    test "client recovers when the server has reaped its record" do
      # Manually delete the server-side record after registration, then trigger an
      # Update. The client should see 4.04, re-register, and end up healthy.
      assert :ok = WickDemoClient.register()
      {:registered, original_id} = WickDemoClient.status()

      # Yank the record out from under the client by sending a Deregister directly.
      {:ok, scratch} = WickCoap.Endpoint.start_link([])
      peer = {{127, 0, 0, 1}, WickDemoServer.port()}

      dereg =
        Wick.Registration.to_wire(%Wick.Registration.Deregister{location: original_id})

      send_wire(scratch, peer, dereg)
      WickCoap.Endpoint.stop(scratch)

      # Server should have no record now.
      assert WickDemoServer.registrations() == []

      # Client thinks it's still registered as `original_id`. Triggering an Update
      # should hit 4.04 server-side, the Registrar re-registers, and we land in a
      # healthy state with a fresh location id.
      assert :ok = WickDemoClient.update()
      assert {:registered, new_id} = WickDemoClient.status()
      refute new_id == original_id
      assert [%{location_id: ^new_id}] = WickDemoServer.registrations()
    end
  end

  defp send_wire(client, peer, %Wick.Wire{} = wire) do
    request = WickDemoClient.Coap.to_message(wire)
    WickCoap.Endpoint.request(client, peer, request, timeout: 2_000)
  end
end

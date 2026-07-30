defmodule WickDemoClient.DeviceManagementTest do
  @moduledoc """
  The demo server driving the demo client over real CoAP/UDP.

  Both apps boot in the same VM, but they talk to each other only through UDP sockets — no
  shared process state, no function calls across the boundary. So this is the test that
  actually says "the Wick stack works": a server issues an operation, a datagram crosses, a
  device answers, and the effect is visible on both sides.

  Everything runs through the same path a real deployment would:

      WickDemoServer.Client -> Wick.Request.to_wire -> CoAP -> UDP
        -> WickDemoClient.Handler -> Wick.Request.from_wire -> WickDemoClient.Device
        -> Wick.Response.to_wire -> CoAP -> UDP -> Wick.Response.from_wire
  """

  use ExUnit.Case, async: false

  alias Wick.Attributes
  alias Wick.CoreLink
  alias Wick.Object.Tree
  alias Wick.Path
  alias Wick.Response
  alias WickDemoServer.Observations

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:wick_demo_server)

    Application.put_env(:wick_demo_client, :server_host, {127, 0, 0, 1})
    Application.put_env(:wick_demo_client, :server_port, WickDemoServer.port())

    :ok
  end

  setup do
    if match?({:registered, _id}, WickDemoClient.status()) do
      WickDemoClient.deregister()
    end

    # The reading log and the device's tree are both process state that outlives a test — the
    # attributes one test writes would otherwise gate the next test's notifications. Reset
    # both rather than letting order matter.
    :ok = Observations.clear_readings()
    :ok = WickDemoClient.Device.reset()

    assert :ok = WickDemoClient.register()
    {:registered, location_id} = WickDemoClient.status()

    on_exit(fn ->
      if match?({:registered, _id}, WickDemoClient.status()), do: WickDemoClient.deregister()
    end)

    %{id: location_id}
  end

  describe "Read" do
    test "reads a single Resource as text/plain", %{id: id} do
      assert {:ok, response} = WickDemoServer.read(id, "/3/0/0", accept: 0)

      assert response.status == :content
      assert response.content_format == 0
      assert response.payload == "Finnlytics"
    end

    test "reads an Object Instance as SenML", %{id: id} do
      assert {:ok, response} = WickDemoServer.read(id, "/3303/0")

      assert response.status == :content
      assert response.content_format == 112

      assert names(response) == [
               "/3303/0/5601",
               "/3303/0/5602",
               "/3303/0/5700",
               "/3303/0/5701"
             ]
    end

    test "an unknown path is 4.04", %{id: id} do
      assert {:ok, %Response{status: :not_found}} = WickDemoServer.read(id, "/9999/0/1")
    end
  end

  describe "Write" do
    test "replaces a Resource value on the device", %{id: id} do
      assert {:ok, %Response{status: :changed}} =
               WickDemoServer.write(id, "/3/0/15", {:string, "+02:00"})

      assert Tree.fetch(WickDemoClient.tree(), path!("/3/0/15")) == {:ok, {:string, "+02:00"}}
    end

    test "writes a float and it stays a float", %{id: id} do
      assert {:ok, %Response{status: :changed}} =
               WickDemoServer.write(id, "/3303/0/5700", {:float, 27.5})

      assert Tree.fetch(WickDemoClient.tree(), path!("/3303/0/5700")) == {:ok, {:float, 27.5}}
    end

    test "the Security Object is refused outside a bootstrap session", %{id: id} do
      assert {:ok, response} = WickDemoServer.write(id, "/0/0/0", {:string, "coap://evil"})

      assert response.status == :unauthorized
    end
  end

  describe "Execute" do
    test "Reboot increments the device's reboot count", %{id: id} do
      before = WickDemoClient.Device.reboot_count()

      assert {:ok, %Response{status: :changed}} = WickDemoServer.execute(id, "/3/0/4")

      assert WickDemoClient.Device.reboot_count() == before + 1
    end

    test "arguments are carried across", %{id: id} do
      assert {:ok, %Response{status: :changed}} =
               WickDemoServer.execute(id, "/3/0/4", "1='immediate'")
    end
  end

  describe "Discover" do
    test "lists the Resources under an Object Instance", %{id: id} do
      assert {:ok, response} = WickDemoServer.discover(id, "/3303/0")

      assert response.content_format == 40
      assert {:ok, links} = CoreLink.decode(response.payload)
      assert "/3303/0" in Enum.map(links, & &1.target)
      assert "/3303/0/5700" in Enum.map(links, & &1.target)
    end

    test "reports attributes the server has written", %{id: id} do
      assert {:ok, _changed} =
               WickDemoServer.write_attributes(id, "/3303/0/5700", %Attributes{pmin: 7, pmax: 70})

      assert {:ok, response} = WickDemoServer.discover(id, "/3303/0")
      assert {:ok, links} = CoreLink.decode(response.payload)

      link = Enum.find(links, &(&1.target == "/3303/0/5700"))
      assert link.params["pmin"] == "7"
      assert link.params["pmax"] == "70"
    end
  end

  describe "Create and Delete" do
    test "Create returns the new Instance path, Delete removes it", %{id: id} do
      assert {:ok, response} =
               WickDemoServer.create(id, "/3303", %{
                 5700 => {:float, 5.0},
                 5701 => {:string, "Cel"}
               })

      assert response.status == :created
      assert Path.format(response.location_path) == "/3303/1"

      assert Tree.fetch(WickDemoClient.tree(), path!("/3303/1/5700")) == {:ok, {:float, 5.0}}

      assert {:ok, %Response{status: :deleted}} = WickDemoServer.delete(id, "/3303/1")
      refute Tree.instance?(WickDemoClient.tree(), 3303, 1)
    end

    test "Delete of a missing Instance is 4.04", %{id: id} do
      assert {:ok, %Response{status: :not_found}} = WickDemoServer.delete(id, "/3303/9")
    end
  end

  describe "Write-Attributes" do
    test "the device stores them and Discover reflects a clear", %{id: id} do
      assert {:ok, _set} =
               WickDemoServer.write_attributes(id, "/3303/0/5700", %Attributes{pmin: 5, st: 1.5})

      assert {:ok, _cleared} =
               WickDemoServer.write_attributes(id, "/3303/0/5700", %Attributes{st: :clear})

      assert Tree.attributes(WickDemoClient.tree(), path!("/3303/0/5700")) ==
               %Attributes{pmin: 5}
    end
  end

  describe "Composite operations" do
    test "Read-Composite spans Objects in one exchange", %{id: id} do
      assert {:ok, response} =
               WickDemoServer.read_composite(id, ["/3/0/0", "/3303/0/5700"])

      assert response.status == :content
      assert names(response) == ["/3/0/0", "/3303/0/5700"]
    end

    test "Write-Composite writes across Objects in one exchange", %{id: id} do
      assert {:ok, %Response{status: :changed}} =
               WickDemoServer.write_composite(id, %{
                 "/3/0/15" => {:string, "+05:30"},
                 "/3303/0/5701" => {:string, "K"}
               })

      tree = WickDemoClient.tree()
      assert Tree.fetch(tree, path!("/3/0/15")) == {:ok, {:string, "+05:30"}}
      assert Tree.fetch(tree, path!("/3303/0/5701")) == {:ok, {:string, "K"}}
    end
  end

  describe "Observe / Notify / Cancel-Observe" do
    test "the full loop with the server correlating notifications", %{id: id} do
      # No attributes: any change notifies. Attribute gating is covered separately below.
      assert {:ok, handle} = WickDemoServer.observe(id, "/3303/0/5700")

      assert [observation] = Observations.list()
      assert observation.registration_id == id
      assert Enum.map(observation.paths, &Path.format/1) == ["/3303/0/5700"]

      # The device takes a reading; the notification should carry the new value and the
      # server should decode it back to a path/value pair.
      before = reading_count()
      assert :notified = WickDemoClient.set_temperature(24.25)

      assert %{source: :notify, readings: [{"/3303/0/5700", 24.25}]} = await_reading(before)

      # Cancel, then confirm a further change produces nothing.
      assert {:ok, %Response{}} = WickDemoServer.cancel_observe(id, "/3303/0/5700", handle)
      assert Observations.list() == []

      count_before = reading_count()
      WickDemoClient.set_temperature(30.0)
      Process.sleep(150)

      assert reading_count() == count_before
    end

    test "notification attributes suppress notifications the server did not ask for", %{id: id} do
      # st: 5 means "only tell me about changes of 5 degrees or more".
      assert {:ok, _changed} =
               WickDemoServer.write_attributes(id, "/3303/0/5700", %Attributes{st: 5.0})

      # The Observe response carries the current value (20.0 after a reset), and the device
      # records it as the baseline the step is measured from — so no extra priming is needed.
      assert {:ok, handle} = WickDemoServer.observe(id, "/3303/0/5700")

      # A one-degree change is below the step: the device stays quiet.
      assert :quiet = WickDemoClient.set_temperature(21.0)
      assert :quiet = WickDemoClient.set_temperature(24.9)

      # Six degrees clears it.
      before = reading_count()
      assert :notified = WickDemoClient.set_temperature(26.0)

      assert %{readings: [{"/3303/0/5700", 26.0}]} = await_reading(before)

      WickDemoServer.cancel_observe(id, "/3303/0/5700", handle)
    end

    test "sequence numbers advance across notifications", %{id: id} do
      assert {:ok, handle} = WickDemoServer.observe(id, "/3303/0/5700")

      for reading <- [21.0, 22.0, 23.0] do
        before = reading_count()
        assert :notified = WickDemoClient.set_temperature(reading)
        await_reading(before)
      end

      sequences =
        WickDemoServer.readings()
        |> Enum.filter(&(&1.source == :notify))
        |> Enum.map(& &1.observe_seq)
        |> Enum.reverse()

      assert length(sequences) >= 3
      assert sequences == Enum.sort(sequences)

      WickDemoServer.cancel_observe(id, "/3303/0/5700", handle)
    end

    test "deregistering drops the device's observations", %{id: id} do
      assert {:ok, _handle} = WickDemoServer.observe(id, "/3303/0/5700")
      assert length(Observations.list()) == 1

      assert :ok = WickDemoClient.deregister()

      assert Observations.list() == []
    end
  end

  describe "Send" do
    test "the client pushes a value with no prior Observe", %{id: _id} do
      before = length(WickDemoServer.readings())

      assert {:ok, %Response{status: :changed}} = WickDemoClient.send_values()

      assert [latest | _rest] = WickDemoServer.readings()
      assert length(WickDemoServer.readings()) == before + 1
      assert latest.source == :send
      assert [{"/3303/0/5700", value}] = latest.readings
      assert is_float(value)
    end

    test "several paths in one Send", %{id: _id} do
      assert {:ok, %Response{status: :changed}} =
               WickDemoClient.send_values([path!("/3303/0"), path!("/3/0/0")])

      assert [latest | _rest] = WickDemoServer.readings()
      names = Enum.map(latest.readings, &elem(&1, 0))

      assert "/3/0/0" in names
      assert "/3303/0/5700" in names
    end
  end

  describe "Registration reflects the live tree" do
    test "an Instance created by the server is advertised on the next Register", %{id: id} do
      assert {:ok, %Response{status: :created}} =
               WickDemoServer.create(id, "/3303", %{5700 => {:float, 1.0}})

      assert :ok = WickDemoClient.deregister()
      assert :ok = WickDemoClient.register()

      assert [record] = WickDemoServer.registrations()
      targets = Enum.map(record.objects, & &1.target)

      assert "/3303/0" in targets
      assert "/3303/1" in targets, "a Create should change what the client advertises"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Notifications are Non-confirmable and travel over UDP, so they arrive asynchronously with
  # respect to the call that triggered them. Wait for the log to *grow* past `since` rather
  # than for it to be non-empty — otherwise a previous notification satisfies the wait and the
  # assertion runs against stale data.
  defp await_reading(since, attempts \\ 50) do
    readings = WickDemoServer.readings()

    cond do
      length(readings) > since -> hd(readings)
      attempts > 0 -> Process.sleep(20) && await_reading(since, attempts - 1)
      true -> flunk("no new reading arrived within 1s (log still has #{since})")
    end
  end

  defp reading_count, do: length(WickDemoServer.readings())

  defp names(%Response{} = response) do
    {:ok, readings} = Observations.decode_readings(response.content_format, response.payload)
    Enum.map(readings, &elem(&1, 0))
  end

  defp path!(string) do
    {:ok, path} = Path.parse(string)
    path
  end
end

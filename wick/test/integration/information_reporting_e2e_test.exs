defmodule Wick.Integration.InformationReportingE2ETest do
  @moduledoc """
  End-to-end test of the Information Reporting interface (LwM2M 1.2 §6.5) over real CoAP/UDP.

  Observe is the operation with the most moving parts in LwM2M, because it is the only one
  where the response arrives more than once and where the two sides must agree on state that
  outlives a single exchange. The full loop is exercised here:

      Observe -> immediate Notify (the current value)
              -> value changes on the device -> Notify
              -> Cancel-Observe -> no further Notify

  plus `Send`, the uplink that needs no prior Observe.

  `WickCoap.Endpoint` owns the relations and the RFC 7641 sequence numbers; Wick supplies the
  payloads and the interpretation. `Wick.Observation` is what lets the server side turn a
  Notification — which carries no path — back into "the value of /3303/0/5700 changed".
  """

  use ExUnit.Case, async: false

  alias Wick.Attributes
  alias Wick.Codec.SenmlCbor
  alias Wick.Object.Tree
  alias Wick.Observation
  alias Wick.Observation.Store
  alias Wick.Path
  alias Wick.Request
  alias Wick.Response
  alias Wick.Senml.Pack
  alias Wick.Test.CoapDeviceHandler
  alias Wick.Uplink
  alias Wick.Wire
  alias WickCoap.Endpoint
  alias WickCoap.Message
  alias WickCoap.Option

  @temperature "/3303/0/5700"

  setup do
    tree = Tree.from_map(%{3303 => %{0 => %{5700 => {:float, 22.5}, 5701 => {:string, "Cel"}}}})

    {:ok, device} = CoapDeviceHandler.start_device(tree)

    {:ok, device_endpoint} =
      Endpoint.start_link(handler: CoapDeviceHandler, handler_state: %{device: device})

    {:ok, server} = Endpoint.start_link([])

    on_exit(fn ->
      stop_quietly(server)
      stop_quietly(device_endpoint)
    end)

    %{
      device: device,
      device_endpoint: device_endpoint,
      server: server,
      peer: {{127, 0, 0, 1}, Endpoint.port(device_endpoint)}
    }
  end

  describe "Observe / Notify / Cancel-Observe" do
    test "the full loop, with the server tracking the relation", ctx do
      path = path!(@temperature)

      # ── 1. Observe. The response carries the current value plus a sequence number. ──
      assert {:ok, handle, initial} = observe(ctx, %Request.Observe{path: path})

      assert {:ok, wire} = response_wire(initial)
      assert wire.status == :content
      assert wire.observe_seq != nil, "the initial response to an Observe must carry Observe"
      assert value_of(wire.payload) == 22.5

      # The server records what it asked for, so later Notifications are interpretable.
      store =
        Store.put(
          Store.new(),
          handle,
          Observation.new("r0", [path], content_format: wire.content_format, now: 0)
        )

      {:ok, observation} = Store.fetch(store, handle)
      refute Observation.composite?(observation)

      # ── 2. The device's value changes and it notifies. ──────────────────────
      CoapDeviceHandler.update_tree(ctx.device, &Tree.put(&1, path, {:float, 30.0}))
      assert CoapDeviceHandler.notify(ctx.device_endpoint, ctx.device, path) == 1

      assert_receive {:wick_coap_notification, ^handle, notification}, 2_000

      # A Notify is interpretable only via the stored relation — it carries no path itself.
      assert {:ok, wire} = response_wire(notification)
      assert {:ok, %Uplink.Notify{} = notify} = Uplink.from_wire(wire)
      assert value_of(notify.payload) == 30.0

      assert {:ok, observation} =
               Observation.accept_seq(observation, notify.observe_seq,
                 now: 1_000,
                 value: value_of(notify.payload)
               )

      assert [^path] = observation.paths
      assert observation.last_value == 30.0

      # ── 3. Cancel-Observe. The device stops being notified about. ───────────
      assert {:ok, _cancelled} = send_request(ctx, %Request.CancelObserve{path: path})
      assert Endpoint.observed_paths(ctx.device_endpoint) == []

      CoapDeviceHandler.update_tree(ctx.device, &Tree.put(&1, path, {:float, 99.0}))
      assert CoapDeviceHandler.notify(ctx.device_endpoint, ctx.device, path) == 0

      refute_receive {:wick_coap_notification, _handle, _message}, 200
    end

    test "successive Notifications carry increasing sequence numbers", ctx do
      path = path!(@temperature)
      assert {:ok, handle, _initial} = observe(ctx, %Request.Observe{path: path})

      sequences =
        for reading <- [23.0, 24.0, 25.0] do
          CoapDeviceHandler.update_tree(ctx.device, &Tree.put(&1, path, {:float, reading}))
          CoapDeviceHandler.notify(ctx.device_endpoint, ctx.device, path)

          assert_receive {:wick_coap_notification, ^handle, notification}, 2_000
          assert {:ok, wire} = response_wire(notification)
          wire.observe_seq
        end

      assert sequences == Enum.sort(sequences)
      assert length(Enum.uniq(sequences)) == 3
    end

    test "an observation survives the reordering filter across a run of notifications", ctx do
      path = path!(@temperature)
      assert {:ok, handle, _initial} = observe(ctx, %Request.Observe{path: path})

      observation = Observation.new("r0", [path], now: 0)

      final =
        Enum.reduce(1..3, observation, fn step, acc ->
          CoapDeviceHandler.update_tree(ctx.device, &Tree.put(&1, path, {:float, 20.0 + step}))
          CoapDeviceHandler.notify(ctx.device_endpoint, ctx.device, path)

          assert_receive {:wick_coap_notification, ^handle, notification}, 2_000
          assert {:ok, wire} = response_wire(notification)
          assert {:ok, notify} = Uplink.from_wire(wire)

          assert {:ok, updated} =
                   Observation.accept_seq(acc, notify.observe_seq,
                     now: step * 1_000,
                     value: value_of(notify.payload)
                   )

          updated
        end)

      assert final.last_value == 23.0
      assert final.notified_at == 3_000
    end

    test "a Notification that arrives out of order is rejected by the server's filter" do
      path = path!(@temperature)
      observation = Observation.new("r0", [path], now: 0)

      assert {:ok, observation} = Observation.accept_seq(observation, 5, now: 1_000, value: 22.5)
      # A duplicate or late datagram — UDP gives no ordering guarantee.
      assert Observation.accept_seq(observation, 4, now: 1_100, value: 99.9) == :stale
      assert observation.last_value == 22.5
    end

    test "Observe on an Object Instance notifies with every Resource under it", ctx do
      path = path!("/3303/0")
      assert {:ok, handle, initial} = observe(ctx, %Request.Observe{path: path})

      assert {:ok, wire} = response_wire(initial)
      assert names_of(wire.payload) == ["/3303/0/5700", "/3303/0/5701"]

      CoapDeviceHandler.update_tree(ctx.device, &Tree.put(&1, path!(@temperature), {:float, 31.0}))
      CoapDeviceHandler.notify(ctx.device_endpoint, ctx.device, path)

      assert_receive {:wick_coap_notification, ^handle, notification}, 2_000
      assert {:ok, wire} = response_wire(notification)
      assert names_of(wire.payload) == ["/3303/0/5700", "/3303/0/5701"]
    end

    test "Observe on an unknown path fails and establishes no relation", ctx do
      assert {:ok, _handle, response} = observe(ctx, %Request.Observe{path: path!("/9999/0/1")})

      assert {:ok, wire} = response_wire(response)
      assert wire.status == :not_found
    end
  end

  describe "notification attributes drive when a device notifies" do
    test "the device stores pmin/pmax/st and they gate should_notify?/3", ctx do
      path = path!(@temperature)

      assert {:ok, %{status: :changed}} =
               send_request(ctx, %Request.WriteAttributes{
                 path: path,
                 attributes: %Attributes{pmin: 10, pmax: 60, st: 2}
               })

      attributes = CoapDeviceHandler.attributes(ctx.device, path)
      assert attributes == %Attributes{pmin: 10, pmax: 60, st: 2}

      # The stored attributes plus an observation are all a device needs to decide.
      observation = Observation.new("r0", [path], now: 0)
      {:ok, observation} = Observation.accept_seq(observation, 0, now: 1_000, value: 22.5)

      # Inside pmin: suppressed however big the change.
      refute Attributes.should_notify?(attributes, Observation.state(observation, 5_000), 99.0)
      # Past pmin but below the step: still suppressed.
      refute Attributes.should_notify?(attributes, Observation.state(observation, 20_000), 23.0)
      # Past pmin and past the step: notify.
      assert Attributes.should_notify?(attributes, Observation.state(observation, 20_000), 25.0)
      # Past pmax: notify even though nothing changed.
      assert Attributes.should_notify?(attributes, Observation.state(observation, 70_000), 22.5)
    end
  end

  describe "Observe-Composite" do
    test "one relation covers several paths and notifies with all of them", ctx do
      paths = [path!(@temperature), path!("/3303/0/5701")]

      assert {:ok, _handle, initial} = observe(ctx, %Request.ObserveComposite{paths: paths})

      assert {:ok, wire} = response_wire(initial)
      assert wire.status == :content
      assert names_of(wire.payload) == ["/3303/0/5700", "/3303/0/5701"]

      observation = Observation.new("r0", paths, now: 0)
      assert Observation.composite?(observation)
    end
  end

  describe "Send" do
    test "a client pushes values with no prior Observe", ctx do
      # Roles reverse here: the device is the requester, so the *server* endpoint needs a
      # handler. The device builds the uplink through Wick and posts it to /dp.
      {:ok, collector} = Agent.start_link(fn -> [] end)

      {:ok, receiver} =
        Endpoint.start_link(
          handler: __MODULE__.SendCollector,
          handler_state: %{collector: collector}
        )

      on_exit(fn -> stop_quietly(receiver) end)

      tree = CoapDeviceHandler.tree(ctx.device)
      {:ok, payload} = SenmlCbor.encode(Tree.to_pack(tree, [path!("/3303/0")]), [])

      send_uplink = %Uplink.Send{
        content_format: 112,
        payload: IO.iodata_to_binary(payload)
      }

      wire = Uplink.to_wire(send_uplink)
      assert wire.path == ["dp"]

      assert {:ok, reply} =
               Endpoint.request(
                 ctx.device_endpoint,
                 {{127, 0, 0, 1}, Endpoint.port(receiver)},
                 to_message(wire),
                 timeout: 2_000
               )

      assert reply.code == :changed

      assert [%Uplink.Send{} = received] = Agent.get(collector, & &1)
      assert received == send_uplink
      assert names_of(received.payload) == ["/3303/0/5700", "/3303/0/5701"]
    end

    test "a POST somewhere other than /dp is not accepted as a Send", ctx do
      {:ok, collector} = Agent.start_link(fn -> [] end)

      {:ok, receiver} =
        Endpoint.start_link(
          handler: __MODULE__.SendCollector,
          handler_state: %{collector: collector}
        )

      on_exit(fn -> stop_quietly(receiver) end)

      message = %Message{
        type: :con,
        code: :post,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "elsewhere"), Option.from_uint(12, 112)],
        payload: <<0x80>>
      }

      assert {:ok, reply} =
               Endpoint.request(
                 ctx.device_endpoint,
                 {{127, 0, 0, 1}, Endpoint.port(receiver)},
                 message,
                 timeout: 2_000
               )

      assert reply.code == :bad_request
      assert Agent.get(collector, & &1) == []
    end
  end

  defmodule SendCollector do
    @moduledoc """
    A minimal LwM2M server-side collector for uplinks: parses inbound CoAP through
    `Wick.Uplink.from_wire/1` and accumulates whatever it recognises.
    """

    @behaviour WickCoap.Handler

    alias Wick.Uplink
    alias Wick.Wire
    alias WickCoap.Message

    @impl WickCoap.Handler
    def handle_request(%Message{} = message, _peer, %{collector: collector}) do
      options = Enum.map(message.options, &{&1.number, &1.value})

      code =
        with {:ok, wire} <- Wire.parse(message.code, options, message.payload || ""),
             {:ok, uplink} <- Uplink.from_wire(wire) do
          Agent.update(collector, &(&1 ++ [uplink]))
          :changed
        else
          {:error, _error} -> :bad_request
        end

      {:reply,
       %Message{
         type: :ack,
         code: code,
         message_id: message.message_id,
         token: message.token,
         options: [],
         payload: ""
       }}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp observe(ctx, request) do
    Endpoint.observe(ctx.server, ctx.peer, to_message(Request.to_wire(request)), timeout: 2_000)
  end

  defp send_request(ctx, request) do
    wire = Request.to_wire(request)

    with {:ok, reply} <- Endpoint.request(ctx.server, ctx.peer, to_message(wire), timeout: 2_000),
         {:ok, response_wire} <- response_wire(reply) do
      {:ok, Response.from_wire(response_wire)}
    end
  end

  defp to_message(%Wire{} = wire) do
    %Message{
      type: :con,
      code: wire.method,
      message_id: 0,
      token: <<>>,
      options: Enum.map(Wire.to_coap_options(wire), fn {n, v} -> Option.new(n, v) end),
      payload: wire.payload
    }
  end

  defp response_wire(%Message{} = message) do
    Wire.Response.parse(
      WickCoap.Code.encode(message.code),
      Enum.map(message.options, &{&1.number, &1.value}),
      message.payload || ""
    )
  end

  defp value_of(payload) do
    {:ok, pack} = SenmlCbor.decode(payload, [])
    [{_name, _time, record} | _rest] = Pack.resolve(pack)
    record.number_value
  end

  defp names_of(payload) do
    {:ok, pack} = SenmlCbor.decode(payload, [])
    pack |> Pack.resolve() |> Enum.map(fn {name, _time, _record} -> name end)
  end

  defp path!(string) do
    {:ok, path} = Path.parse(string)
    path
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: Endpoint.stop(pid)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end

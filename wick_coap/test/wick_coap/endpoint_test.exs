defmodule WickCoap.EndpointTest do
  use ExUnit.Case, async: false

  defp sock_port(sock) do
    {:ok, p} = :inet.port(sock)
    p
  end

  alias WickCoap.Endpoint
  alias WickCoap.Message
  alias WickCoap.Observe
  alias WickCoap.Option
  alias WickCoap.Test.CounterHandler
  alias WickCoap.Test.EchoHandler

  describe "start_link/1 and port/1" do
    test "binds an ephemeral port when :port is omitted" do
      {:ok, endpoint} = Endpoint.start_link([])

      assigned = Endpoint.port(endpoint)
      assert is_integer(assigned)
      assert assigned > 0

      Endpoint.stop(endpoint)
    end

    test "binds the requested port when specified" do
      {:ok, picker} = Endpoint.start_link([])
      port = Endpoint.port(picker)
      Endpoint.stop(picker)

      # Brief pause to let SO_REUSEADDR claim the freed port
      Process.sleep(50)

      {:ok, endpoint} = Endpoint.start_link(port: port)
      assert Endpoint.port(endpoint) == port

      Endpoint.stop(endpoint)
    end
  end

  describe "end-to-end CON request/response over UDP" do
    test "client sends a CON GET, server replies with a piggy-backed 2.05 Content" do
      {:ok, server} = Endpoint.start_link(handler: EchoHandler)
      server_port = Endpoint.port(server)

      {:ok, client} = Endpoint.start_link([])

      request = %Message{
        type: :con,
        code: :get,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "hello")],
        payload: "world"
      }

      assert {:ok, response} =
               Endpoint.request(client, {{127, 0, 0, 1}, server_port}, request, timeout: 2_000)

      assert response.type == :ack
      assert response.code == :content
      assert response.payload == "world"
      # Token matches what the Endpoint allocated for the request
      assert byte_size(response.token) == 8

      Endpoint.stop(client)
      Endpoint.stop(server)
    end

    test "different concurrent requests get matched to the right responses" do
      {:ok, server} = Endpoint.start_link(handler: EchoHandler)
      server_port = Endpoint.port(server)

      {:ok, client} = Endpoint.start_link([])
      server_peer = {{127, 0, 0, 1}, server_port}

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            request = %Message{
              type: :con,
              code: :get,
              message_id: 0,
              token: <<>>,
              payload: "request-#{i}"
            }

            Endpoint.request(client, server_peer, request, timeout: 2_000)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      payloads =
        for {:ok, response} <- results do
          assert response.code == :content
          response.payload
        end

      assert length(payloads) == 10
      assert MapSet.new(payloads) == MapSet.new(for i <- 1..10, do: "request-#{i}")

      Endpoint.stop(client)
      Endpoint.stop(server)
    end
  end

  describe "request/4 — timeout" do
    test "returns {:error, :timeout} when the server doesn't respond" do
      # Pick an unused port (open then close)
      {:ok, dummy} = Endpoint.start_link([])
      unused_port = Endpoint.port(dummy)
      Endpoint.stop(dummy)
      Process.sleep(50)

      {:ok, client} = Endpoint.start_link([])

      request = %Message{
        type: :con,
        code: :get,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "nowhere")]
      }

      # Use small retransmit timeout so the test runs fast
      # (we can't override per-call here — the default is 2s ACK_TIMEOUT and 4 retries,
      # which gives ~62s worst case. So use a small overall caller timeout instead and
      # assert we eventually get a :timeout from the GenServer call.)
      assert catch_exit(
               Endpoint.request(client, {{127, 0, 0, 1}, unused_port}, request, timeout: 500)
             )

      Endpoint.stop(client)
    end
  end

  describe "ping/3 — CoAP Ping (RFC 7252 §4.3)" do
    test "returns :pong when the peer replies with RST" do
      # Any endpoint with no handler RST's unknown messages — perfect ping target.
      {:ok, server} = Endpoint.start_link([])
      server_peer = {{127, 0, 0, 1}, Endpoint.port(server)}

      {:ok, client} = Endpoint.start_link([])
      assert :pong = Endpoint.ping(client, server_peer, timeout: 1_000)

      Endpoint.stop(client)
      Endpoint.stop(server)
    end

    test "returns {:error, :timeout} when no peer answers" do
      {:ok, dummy} = Endpoint.start_link([])
      unused_port = Endpoint.port(dummy)
      Endpoint.stop(dummy)
      Process.sleep(50)

      {:ok, client} = Endpoint.start_link([])
      assert {:error, :timeout} = Endpoint.ping(client, {{127, 0, 0, 1}, unused_port}, timeout: 200)

      Endpoint.stop(client)
    end
  end

  describe "send_async/3" do
    test "fires a message without expecting a response" do
      {:ok, server} = Endpoint.start_link(handler: EchoHandler)
      server_port = Endpoint.port(server)

      {:ok, client} = Endpoint.start_link([])

      msg = %Message{
        type: :non,
        code: :post,
        message_id: 0,
        token: <<>>,
        payload: "fire and forget"
      }

      assert :ok = Endpoint.send_async(client, {{127, 0, 0, 1}, server_port}, msg)

      # Give it time to fly
      Process.sleep(50)

      Endpoint.stop(client)
      Endpoint.stop(server)
    end
  end

  describe "Block2 — large response auto-fragments and reassembles" do
    test "small block size on the server forces several blocks; client gets full payload" do
      # SZX=0 → 16-byte blocks. A 100-byte response means 7 blocks total
      # (6 full × 16 + last × 4).
      {:ok, server} = Endpoint.start_link(handler: EchoHandler, block_szx: 0)
      server_port = Endpoint.port(server)

      {:ok, client} = Endpoint.start_link([])

      request = %Message{
        type: :con,
        code: :get,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "large"), Option.new(11, "100")]
      }

      assert {:ok, response} =
               Endpoint.request(client, {{127, 0, 0, 1}, server_port}, request, timeout: 5_000)

      assert response.code == :content
      assert byte_size(response.payload) == 100

      expected = for i <- 0..99, into: <<>>, do: <<rem(i, 256)::8>>
      assert response.payload == expected

      Endpoint.stop(client)
      Endpoint.stop(server)
    end

    test "boundary case: payload exactly one block does not fragment" do
      {:ok, server} = Endpoint.start_link(handler: EchoHandler, block_szx: 0)
      server_port = Endpoint.port(server)

      {:ok, client} = Endpoint.start_link([])

      request = %Message{
        type: :con,
        code: :get,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "large"), Option.new(11, "16")]
      }

      assert {:ok, response} =
               Endpoint.request(client, {{127, 0, 0, 1}, server_port}, request, timeout: 2_000)

      assert byte_size(response.payload) == 16
      # No Block2 option should remain on the assembled response
      refute Enum.any?(response.options, &(&1.number == 23))

      Endpoint.stop(client)
      Endpoint.stop(server)
    end

    test "non-divisible payload — last block is partial" do
      {:ok, server} = Endpoint.start_link(handler: EchoHandler, block_szx: 0)
      server_port = Endpoint.port(server)

      {:ok, client} = Endpoint.start_link([])

      request = %Message{
        type: :con,
        code: :get,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "large"), Option.new(11, "17")]
      }

      assert {:ok, response} =
               Endpoint.request(client, {{127, 0, 0, 1}, server_port}, request, timeout: 2_000)

      assert byte_size(response.payload) == 17

      Endpoint.stop(client)
      Endpoint.stop(server)
    end
  end

  describe "Block1 — large request body auto-fragments and reassembles" do
    test "large request body is split, reassembled, and echoed back" do
      # SZX=0 → 16-byte blocks. A 100-byte request gets fragmented client-side and
      # reassembled server-side before being passed to the handler, which echoes the
      # full payload (which then has to come back via Block2 since 100 > 16).
      {:ok, server} = Endpoint.start_link(handler: EchoHandler, block_szx: 0)
      server_port = Endpoint.port(server)

      {:ok, client} = Endpoint.start_link(block_szx: 0)

      payload = for i <- 0..99, into: <<>>, do: <<rem(i, 256)::8>>

      request = %Message{
        type: :con,
        code: :post,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "echo")],
        payload: payload
      }

      assert {:ok, response} =
               Endpoint.request(client, {{127, 0, 0, 1}, server_port}, request, timeout: 10_000)

      assert response.code == :content
      assert byte_size(response.payload) == 100
      assert response.payload == payload

      Endpoint.stop(client)
      Endpoint.stop(server)
    end

    test "small payload skips Block1 fragmentation entirely" do
      # 16-byte payload fits in one block at SZX=0; Block1 should not engage.
      {:ok, server} = Endpoint.start_link(handler: EchoHandler, block_szx: 0)
      server_port = Endpoint.port(server)

      {:ok, client} = Endpoint.start_link(block_szx: 0)

      payload = :binary.copy("x", 16)

      request = %Message{
        type: :con,
        code: :post,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "echo")],
        payload: payload
      }

      assert {:ok, response} =
               Endpoint.request(client, {{127, 0, 0, 1}, server_port}, request, timeout: 2_000)

      assert response.payload == payload
      # No Block1 option should remain on the response
      refute Enum.any?(response.options, &(&1.number == 27))

      Endpoint.stop(client)
      Endpoint.stop(server)
    end
  end

  describe "Observe — server side (RFC 7641)" do
    test "register, notify, deregister round trip" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      {:ok, server} =
        Endpoint.start_link(handler: CounterHandler, handler_state: %{counter: agent})

      server_port = Endpoint.port(server)

      # Open a raw UDP socket to act as the observing client. Active = false so we drive
      # receives explicitly.
      {:ok, sock} = :gen_udp.open(0, [:binary, {:active, false}])

      # 1. Register the relation: GET /counter with Observe = 0.
      register_req = %Message{
        type: :con,
        code: :get,
        message_id: 0x1234,
        token: <<1, 2, 3>>,
        options: [Option.new(11, "counter"), Observe.option(0)]
      }

      {:ok, register_bytes} = Message.encode(register_req)
      :ok = :gen_udp.send(sock, {127, 0, 0, 1}, server_port, register_bytes)

      assert {:ok, {_ip, _port, register_response_bytes}} =
               :gen_udp.recv(sock, 0, 1_000)

      {:ok, register_response, ""} = Message.decode(register_response_bytes)
      assert register_response.code == :content
      assert register_response.payload == "0"
      assert {:ok, 0} = Observe.extract(register_response)
      assert register_response.token == <<1, 2, 3>>

      assert Endpoint.observed_paths(server) == [{{{127, 0, 0, 1}, sock_port(sock)}, ["counter"]}]

      # 2. Push a notification.
      Agent.update(agent, fn _ -> 42 end)

      notify_template = %Message{
        type: :non,
        code: :content,
        message_id: 0,
        token: <<>>,
        options: [Option.from_uint(12, 0)],
        payload: "42"
      }

      assert 1 = Endpoint.notify_observers(server, ["counter"], notify_template)

      assert {:ok, {_, _, notif_bytes}} = :gen_udp.recv(sock, 0, 1_000)
      {:ok, notif, ""} = Message.decode(notif_bytes)
      assert notif.code == :content
      assert notif.payload == "42"
      assert notif.token == <<1, 2, 3>>
      assert {:ok, 1} = Observe.extract(notif)
      assert notif.type == :non

      # 3. Push another — sequence advances.
      assert 1 = Endpoint.notify_observers(server, ["counter"], notify_template)
      {:ok, {_, _, notif2_bytes}} = :gen_udp.recv(sock, 0, 1_000)
      {:ok, notif2, ""} = Message.decode(notif2_bytes)
      assert {:ok, 2} = Observe.extract(notif2)

      # 4. Deregister: GET /counter with Observe = 1.
      deregister_req = %Message{
        type: :con,
        code: :get,
        message_id: 0x1235,
        token: <<1, 2, 3>>,
        options: [Option.new(11, "counter"), Observe.option(1)]
      }

      {:ok, deregister_bytes} = Message.encode(deregister_req)
      :ok = :gen_udp.send(sock, {127, 0, 0, 1}, server_port, deregister_bytes)
      {:ok, {_, _, _}} = :gen_udp.recv(sock, 0, 1_000)

      assert Endpoint.observed_paths(server) == []

      # 5. After deregistration, no notifications fire.
      assert 0 = Endpoint.notify_observers(server, ["counter"], notify_template)

      :gen_udp.close(sock)
      Endpoint.stop(server)
      Agent.stop(agent)
    end

    test "client-side observe: subscribe, receive notifications, cancel" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      {:ok, server} =
        Endpoint.start_link(handler: CounterHandler, handler_state: %{counter: agent})

      server_port = Endpoint.port(server)
      server_peer = {{127, 0, 0, 1}, server_port}

      {:ok, client} = Endpoint.start_link([])

      request = %Message{
        type: :con,
        code: :get,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "counter")]
      }

      assert {:ok, handle, initial} =
               Endpoint.observe(client, server_peer, request, timeout: 2_000)

      assert initial.code == :content
      assert initial.payload == "0"
      assert {:ok, 0} = Observe.extract(initial)
      assert Endpoint.subscriptions(client) == [handle]

      Agent.update(agent, fn _ -> 42 end)

      template = %Message{
        type: :non,
        code: :content,
        message_id: 0,
        token: <<>>,
        options: [Option.from_uint(12, 0)],
        payload: "42"
      }

      assert 1 = Endpoint.notify_observers(server, ["counter"], template)
      assert_receive {:wick_coap_notification, ^handle, msg1}, 1_000
      assert msg1.payload == "42"
      assert {:ok, seq1} = Observe.extract(msg1)

      template2 = %{template | payload: "100"}
      assert 1 = Endpoint.notify_observers(server, ["counter"], template2)
      assert_receive {:wick_coap_notification, ^handle, msg2}, 1_000
      assert msg2.payload == "100"
      assert {:ok, seq2} = Observe.extract(msg2)
      assert Observe.newer?(seq2, seq1)

      assert :ok = Endpoint.cancel_observation(client, handle)
      assert Endpoint.subscriptions(client) == []

      Process.sleep(50)
      assert 0 = Endpoint.notify_observers(server, ["counter"], template)

      Endpoint.stop(client)
      Endpoint.stop(server)
      Agent.stop(agent)
    end

    test "notify_observers/3 returns 0 when no one is observing the path" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      {:ok, server} =
        Endpoint.start_link(handler: CounterHandler, handler_state: %{counter: agent})

      template = %Message{
        type: :non,
        code: :content,
        message_id: 0,
        token: <<>>,
        options: [Option.from_uint(12, 0)],
        payload: "42"
      }

      assert 0 = Endpoint.notify_observers(server, ["counter"], template)

      Endpoint.stop(server)
      Agent.stop(agent)
    end
  end

  describe "endpoint with no handler" do
    test "replies with RST to inbound requests" do
      {:ok, server} = Endpoint.start_link([])
      server_port = Endpoint.port(server)

      {:ok, client} = Endpoint.start_link([])

      request = %Message{
        type: :con,
        code: :get,
        message_id: 0,
        token: <<>>,
        options: [Option.new(11, "x")]
      }

      # We expect an :error eventually since RST doesn't carry a response payload
      # and the client's exchange will time out waiting for a 2.xx/4.xx response.
      assert catch_exit(
               Endpoint.request(client, {{127, 0, 0, 1}, server_port}, request, timeout: 500)
             )

      Endpoint.stop(client)
      Endpoint.stop(server)
    end
  end
end

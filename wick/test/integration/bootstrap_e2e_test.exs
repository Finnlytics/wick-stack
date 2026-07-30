defmodule Wick.Integration.BootstrapE2ETest do
  @moduledoc """
  End-to-end test of the Bootstrap interface (LwM2M 1.2 §6.1) over real CoAP/UDP.

  Bootstrap is the only LwM2M interface where traffic runs in both directions within one
  logical exchange, and the only one with a required ordering. Both are exercised here: a
  client asks to be provisioned, a `Wick.Bootstrap.Session` drives the plan step by step, and
  Bootstrap-Finish lands only after every step is acknowledged.

  The device runs `Wick.Test.CoapBootstrapClientHandler`, which routes inbound traffic through
  `Wick.Bootstrap.from_wire/1` — the "a bootstrap session is open" side of the ambiguity
  between a Bootstrap-Write and a Device Management Write.
  """

  use ExUnit.Case, async: false

  alias Wick.Bootstrap
  alias Wick.Bootstrap.Session
  alias Wick.Codec.SenmlCbor
  alias Wick.CoreLink
  alias Wick.Error
  alias Wick.Object.Tree
  alias Wick.Path
  alias Wick.Response
  alias Wick.Senml.Pack
  alias Wick.Senml.Record
  alias Wick.Test.CoapBootstrapClientHandler, as: ClientHandler
  alias Wick.Wire
  alias WickCoap.Endpoint
  alias WickCoap.Message
  alias WickCoap.Option

  setup do
    # A factory-fresh device: it knows a Bootstrap Server (Security Instance 0) and nothing
    # else. No Server Object, so it cannot register until it has been provisioned.
    {:ok, client} =
      ClientHandler.start_client(
        Tree.from_map(%{
          0 => %{0 => %{0 => {:string, "coap://bootstrap.example.org"}, 1 => {:boolean, true}}}
        })
      )

    {:ok, client_endpoint} =
      Endpoint.start_link(handler: ClientHandler, handler_state: %{client: client})

    {:ok, bootstrap_server} = Endpoint.start_link([])

    on_exit(fn ->
      stop_quietly(bootstrap_server)
      stop_quietly(client_endpoint)
    end)

    %{
      client: client,
      client_endpoint: client_endpoint,
      server: bootstrap_server,
      peer: {{127, 0, 0, 1}, Endpoint.port(client_endpoint)}
    }
  end

  describe "the full bootstrap sequence" do
    test "wipe, provision Security and Server, then Finish", ctx do
      plan = [
        # Clear whatever stale configuration the device is carrying.
        %Bootstrap.Delete{},
        # Security Instance 1: the LwM2M Server the device should now talk to.
        %Bootstrap.Write{
          path: path!("/0/1"),
          content_format: 112,
          payload: pack(%{0 => {:string, "coap://lwm2m.example.org"}, 10 => {:integer, 101}})
        },
        # Server Instance 0: the matching Server Account.
        %Bootstrap.Write{
          path: path!("/1/0"),
          content_format: 112,
          payload: pack(%{0 => {:integer, 101}, 1 => {:integer, 86_400}})
        }
      ]

      session = Session.new(plan)
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "device-1"})

      # ── Drive the plan. Each step goes over the wire before the next is popped. ──
      session = run_plan(ctx, session)

      assert Session.pop(session) == :done
      assert length(session.applied) == 3

      # ── Finish. The client validates and accepts. ───────────────────────────
      assert {:ok, finish, session} = Session.finish(session)
      assert {:ok, response} = send_operation(ctx, finish)
      assert response.status == :changed
      assert session.state == :finished

      assert ClientHandler.finished?(ctx.client)

      # ── The device is now provisioned: it has a Server Account to register with. ──
      tree = ClientHandler.tree(ctx.client)
      assert Tree.instance_ids(tree, 0) == [1]
      assert Tree.instance_ids(tree, 1) == [0]
      assert Tree.fetch(tree, path!("/1/0/1")) == {:ok, {:integer, 86_400}}

      assert Tree.fetch(tree, path!("/0/1/0")) ==
               {:ok, {:string, "coap://lwm2m.example.org"}}

      # The root Delete really did wipe the factory Security Instance.
      assert Tree.fetch(tree, path!("/0/0/0")) == :error
    end

    test "Finish is refused while the device lacks a Server Account", ctx do
      # A plan that wipes but provisions only Security — the half-finished case.
      session = Session.new([%Bootstrap.Delete{}])
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "device-1"})
      session = run_plan(ctx, session)

      assert {:ok, finish, _session} = Session.finish(session)
      assert {:ok, response} = send_operation(ctx, finish)

      assert response.status == :not_acceptable
      refute ClientHandler.finished?(ctx.client)
    end

    test "the session refuses to emit Finish before the plan completes", ctx do
      plan = [
        %Bootstrap.Delete{},
        %Bootstrap.Write{
          path: path!("/1/0"),
          content_format: 112,
          payload: pack(%{0 => {:integer, 101}})
        }
      ]

      session = Session.new(plan)
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "device-1"})

      # Do only the first step.
      assert {:ok, operation, session} = Session.pop(session)
      assert {:ok, _response} = send_operation(ctx, operation)
      assert {:ok, session} = Session.ack(session)

      assert {:error, err} = Session.finish(session)
      assert err.code == :plan_incomplete
      refute ClientHandler.finished?(ctx.client)
    end

    test "a step that the device rejects fails the session", ctx do
      # A Write whose body is not decodable SenML.
      session =
        Session.new([
          %Bootstrap.Write{path: path!("/1/0"), content_format: 112, payload: <<0xFF, 0xFF>>}
        ])

      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "device-1"})

      assert {:ok, operation, session} = Session.pop(session)
      assert {:ok, response} = send_operation(ctx, operation)
      assert Response.error?(response)

      session = Session.fail(session, Error.new(:rejected, response.payload))

      assert session.state == :failed
      assert Session.done?(session)
      assert {:error, %{code: :invalid_session_state}} = Session.finish(session)
    end
  end

  describe "Bootstrap-Discover" do
    test "reports what the device currently holds", ctx do
      assert {:ok, response} = send_operation(ctx, %Bootstrap.Discover{})

      assert response.content_format == 40
      assert {:ok, links} = CoreLink.decode(response.payload)
      assert Enum.map(links, & &1.target) == ["/0/0"]
    end

    test "reports an Object's Resources when targeted", ctx do
      assert {:ok, response} = send_operation(ctx, %Bootstrap.Discover{path: path!("/0/0")})
      assert {:ok, links} = CoreLink.decode(response.payload)

      assert Enum.map(links, & &1.target) == ["/0/0", "/0/0/0", "/0/0/1"]
    end
  end

  describe "Bootstrap-Read" do
    test "reads back the Server Object after provisioning", ctx do
      write = %Bootstrap.Write{
        path: path!("/1/0"),
        content_format: 112,
        payload: pack(%{0 => {:integer, 101}, 1 => {:integer, 300}})
      }

      assert {:ok, %{status: :changed}} = send_operation(ctx, write)
      assert {:ok, response} = send_operation(ctx, %Bootstrap.Read{path: path!("/1/0")})

      assert response.status == :content
      assert {:ok, decoded} = SenmlCbor.decode(response.payload, [])

      assert decoded |> Pack.resolve() |> Enum.map(fn {name, _t, _r} -> name end) ==
               ["/1/0/0", "/1/0/1"]
    end

    test "refuses to read the Security Object back", ctx do
      assert {:ok, response} = send_operation(ctx, %Bootstrap.Read{path: path!("/0/0")})

      assert response.status == :method_not_allowed
      assert response.payload =~ "Security Object"
    end

    test "an unprovisioned path is 4.04", ctx do
      assert {:ok, %{status: :not_found}} =
               send_operation(ctx, %Bootstrap.Read{path: path!("/1/0")})
    end
  end

  describe "Bootstrap-Delete" do
    test "the targeted form removes one Instance and leaves others", ctx do
      write = %Bootstrap.Write{
        path: path!("/1/0"),
        content_format: 112,
        payload: pack(%{0 => {:integer, 101}})
      }

      assert {:ok, _written} = send_operation(ctx, write)
      assert {:ok, response} = send_operation(ctx, %Bootstrap.Delete{path: path!("/1/0")})

      assert response.status == :deleted

      tree = ClientHandler.tree(ctx.client)
      assert Tree.instance_ids(tree, 1) == []
      assert Tree.instance_ids(tree, 0) == [0], "the Security Object must survive"
    end
  end

  describe "the client's Bootstrap-Request" do
    test "reaches a Bootstrap Server and is recognised as a Request, not a Finish", ctx do
      {:ok, received} = Agent.start_link(fn -> [] end)

      {:ok, server_endpoint} =
        Endpoint.start_link(
          handler: __MODULE__.BootstrapServerHandler,
          handler_state: %{received: received}
        )

      on_exit(fn -> stop_quietly(server_endpoint) end)

      request = %Bootstrap.Request{endpoint_name: "device-1", preferred_content_format: 112}

      assert {:ok, reply} =
               Endpoint.request(
                 ctx.client_endpoint,
                 {{127, 0, 0, 1}, Endpoint.port(server_endpoint)},
                 to_message(Bootstrap.to_wire(request)),
                 timeout: 2_000
               )

      assert reply.code == :changed
      assert Agent.get(received, & &1) == [request]
    end

    test "a bare POST /bs to the same server is read as a Finish", ctx do
      {:ok, received} = Agent.start_link(fn -> [] end)

      {:ok, server_endpoint} =
        Endpoint.start_link(
          handler: __MODULE__.BootstrapServerHandler,
          handler_state: %{received: received}
        )

      on_exit(fn -> stop_quietly(server_endpoint) end)

      assert {:ok, _reply} =
               Endpoint.request(
                 ctx.client_endpoint,
                 {{127, 0, 0, 1}, Endpoint.port(server_endpoint)},
                 to_message(Bootstrap.to_wire(%Bootstrap.Finish{})),
                 timeout: 2_000
               )

      assert Agent.get(received, & &1) == [%Bootstrap.Finish{}]
    end
  end

  defmodule BootstrapServerHandler do
    @moduledoc """
    The server side: accepts a client's Bootstrap-Request and records what it parsed, so a
    test can assert that `POST /bs?ep=…` and a bare `POST /bs` are told apart.
    """

    @behaviour WickCoap.Handler

    alias Wick.Bootstrap
    alias Wick.Wire
    alias WickCoap.Message

    @impl WickCoap.Handler
    def handle_request(%Message{} = message, _peer, %{received: received}) do
      options = Enum.map(message.options, &{&1.number, &1.value})

      code =
        with {:ok, wire} <- Wire.parse(message.code, options, message.payload || ""),
             {:ok, operation} <- Bootstrap.from_wire(wire) do
          Agent.update(received, &(&1 ++ [operation]))
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

  # Walk the session's plan, sending each operation over real CoAP and acknowledging only
  # once the client has answered. This is the ordering the Session exists to enforce.
  defp run_plan(ctx, session) do
    case Session.pop(session) do
      :done ->
        session

      {:ok, operation, session} ->
        assert {:ok, response} = send_operation(ctx, operation)

        assert Response.success?(response),
               "step #{inspect(operation)} failed: #{inspect(response)}"

        assert {:ok, session} = Session.ack(session)
        run_plan(ctx, session)
    end
  end

  defp send_operation(ctx, operation) do
    message = to_message(Bootstrap.to_wire(operation))

    with {:ok, reply} <- Endpoint.request(ctx.server, ctx.peer, message, timeout: 2_000) do
      options = Enum.map(reply.options, &{&1.number, &1.value})
      code = WickCoap.Code.encode(reply.code)

      {:ok, wire} = Wire.Response.parse(code, options, reply.payload || "")
      {:ok, Response.from_wire(wire)}
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

  # Build a SenML CBOR body of `resource_id => tagged_value`, named relative to the Write's
  # target path, which is how a Bootstrap-Write on an Object Instance is encoded.
  defp pack(resources) do
    records =
      for {resource_id, value} <- Enum.sort(resources) do
        record(Integer.to_string(resource_id), value)
      end

    {:ok, encoded} = SenmlCbor.encode(Pack.new(records), [])
    IO.iodata_to_binary(encoded)
  end

  defp record(name, {:string, value}), do: %Record{name: name, string_value: value}
  defp record(name, {:integer, value}), do: %Record{name: name, number_value: value}
  defp record(name, {:boolean, value}), do: %Record{name: name, boolean_value: value}

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

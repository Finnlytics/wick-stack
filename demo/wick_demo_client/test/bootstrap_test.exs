defmodule WickDemoClient.BootstrapTest do
  @moduledoc """
  The demo client being bootstrapped over real CoAP/UDP.

  The demo *server* is not a Bootstrap Server — that is a separate deployment with different
  credentials — so this test plays the Bootstrap Server itself, driving a
  `Wick.Bootstrap.Session` against the real client.

  What it pins down is the part of the Bootstrap interface that is easy to get wrong: a
  Bootstrap-Write and a Device Management Write are the same bytes on the wire, and the client
  must apply different permissions to each depending on whether a session is open. Both halves
  are asserted — the Security Object is writable during bootstrap and refused outside it.
  """

  use ExUnit.Case, async: false

  alias Wick.Bootstrap
  alias Wick.Bootstrap.Session
  alias Wick.Codec.SenmlCbor
  alias Wick.Object.Tree
  alias Wick.Path
  alias Wick.Response
  alias Wick.Senml.Pack
  alias Wick.Senml.Record
  alias WickCoap.Endpoint
  alias WickDemoClient.Coap
  alias WickDemoClient.Device

  setup do
    :ok = Device.reset()

    # The Bootstrap Server's own endpoint. It only needs to send: everything it receives is a
    # response to something it sent.
    {:ok, bootstrap_server} = Endpoint.start_link([])

    on_exit(fn ->
      Device.reset()
      if Process.alive?(bootstrap_server), do: Endpoint.stop(bootstrap_server)
    end)

    %{
      server: bootstrap_server,
      peer: {{127, 0, 0, 1}, WickDemoClient.port()}
    }
  end

  describe "the full bootstrap sequence" do
    test "wipe, provision Security and Server, then Finish", ctx do
      plan = [
        %Bootstrap.Delete{},
        %Bootstrap.Write{
          path: path!("/0/0"),
          content_format: 112,
          payload: pack(%{0 => {:string, "coap://lwm2m.example.org"}, 10 => {:integer, 101}})
        },
        %Bootstrap.Write{
          path: path!("/1/0"),
          content_format: 112,
          payload: pack(%{0 => {:integer, 101}, 1 => {:integer, 300}})
        }
      ]

      session = Session.new(plan)

      # The client opens the session by asking to be bootstrapped. Here the test stands in for
      # the transport that would carry that request to the Bootstrap Server.
      :ok = Device.begin_bootstrap()
      {:ok, session} = Session.request(session, %Bootstrap.Request{endpoint_name: "demo"})

      assert Device.bootstrapping?()

      session = run_plan(ctx, session)
      assert Session.pop(session) == :done

      assert {:ok, finish, session} = Session.finish(session)
      assert {:ok, %Response{status: :changed}} = send_operation(ctx, finish)
      assert session.state == :finished

      # The session is closed and the device is provisioned.
      refute Device.bootstrapping?()

      tree = Device.tree()
      assert Tree.fetch(tree, path!("/0/0/0")) == {:ok, {:string, "coap://lwm2m.example.org"}}
      assert Tree.fetch(tree, path!("/1/0/1")) == {:ok, {:integer, 300}}

      # The root Delete wiped the factory Objects, so what the client advertises has changed.
      targets = tree |> Tree.links() |> Enum.map(& &1.target)
      assert targets == ["/0/0", "/1/0"]
    end

    test "Finish is refused while the device has no Server Object", ctx do
      :ok = Device.begin_bootstrap()

      # Wipe everything, provision nothing: the half-finished case.
      assert {:ok, %Response{status: :deleted}} = send_operation(ctx, %Bootstrap.Delete{})
      assert {:ok, response} = send_operation(ctx, %Bootstrap.Finish{})

      assert response.status == :not_acceptable
      assert Device.bootstrapping?(), "a refused Finish must leave the session open"
    end
  end

  describe "Bootstrap-Write versus Device Management Write" do
    test "the Security Object is writable during a bootstrap session", ctx do
      :ok = Device.begin_bootstrap()

      write = %Bootstrap.Write{
        path: path!("/0/1"),
        content_format: 112,
        payload: pack(%{0 => {:string, "coap://provisioned"}})
      }

      assert {:ok, %Response{status: :changed}} = send_operation(ctx, write)

      assert Tree.fetch(Device.tree(), path!("/0/1/0")) ==
               {:ok, {:string, "coap://provisioned"}}
    end

    test "the same bytes are refused once the session closes", ctx do
      # Provision, then finish so the session closes.
      :ok = Device.begin_bootstrap()

      security = %Bootstrap.Write{
        path: path!("/0/0"),
        content_format: 112,
        payload: pack(%{0 => {:string, "coap://lwm2m.example.org"}})
      }

      assert {:ok, %Response{status: :changed}} = send_operation(ctx, security)
      assert {:ok, %Response{status: :changed}} = send_operation(ctx, %Bootstrap.Finish{})
      refute Device.bootstrapping?()

      # Byte-for-byte the same request, now outside a session. It is decoded as a Device
      # Management Write, and a DM Write may not touch the Security Object.
      assert {:ok, response} = send_operation(ctx, security)
      assert response.status == :unauthorized
    end
  end

  describe "Bootstrap-Discover and Bootstrap-Read" do
    test "Discover reports what the client currently holds", ctx do
      :ok = Device.begin_bootstrap()

      assert {:ok, response} = send_operation(ctx, %Bootstrap.Discover{})

      assert response.content_format == 40
      assert {:ok, links} = Wick.CoreLink.decode(response.payload)
      assert Enum.map(links, & &1.target) == ["/1/0", "/3/0", "/3303/0"]
    end

    test "Read returns the Server Object but refuses the Security Object", ctx do
      :ok = Device.begin_bootstrap()

      assert {:ok, %Response{status: :content}} =
               send_operation(ctx, %Bootstrap.Read{path: path!("/1/0")})

      assert {:ok, refused} = send_operation(ctx, %Bootstrap.Read{path: path!("/0/0")})
      assert refused.status == :method_not_allowed
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp run_plan(ctx, session) do
    case Session.pop(session) do
      :done ->
        session

      {:ok, operation, session} ->
        assert {:ok, response} = send_operation(ctx, operation)
        assert Response.success?(response), "step failed: #{inspect(response)}"
        assert {:ok, session} = Session.ack(session)
        run_plan(ctx, session)
    end
  end

  defp send_operation(ctx, operation) do
    Coap.request(ctx.server, ctx.peer, Bootstrap.to_wire(operation), timeout: 2_000)
  end

  # A SenML body of `resource_id => tagged_value`, named relative to the Write's target path.
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
end

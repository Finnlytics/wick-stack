defmodule Wick.Integration.TlvE2ETest do
  @moduledoc """
  End-to-end test of the TLV content format (11542) over real CoAP/UDP.

  A `WickCoap.Endpoint` runs `Wick.Test.CoapDeviceHandler` and plays the device; the test
  plays the server. Both sides are given the same Object model, which is what TLV requires:
  the payload carries no names and no types, so a device and a server that disagree about
  either produce garbage rather than an error.

  This is the test that would catch the failure mode TLV is prone to — a Read that comes back
  as the right number of bytes with the wrong meaning.
  """

  use ExUnit.Case, async: false

  alias Wick.Codec.Tlv
  alias Wick.Object.Definition
  alias Wick.Object.Registry
  alias Wick.Object.Resource
  alias Wick.Object.Tree
  alias Wick.Path
  alias Wick.Request
  alias Wick.Response
  alias Wick.Senml.Pack
  alias Wick.Senml.Record
  alias Wick.Test.CoapDeviceHandler
  alias Wick.Wire
  alias WickCoap.Endpoint
  alias WickCoap.Message
  alias WickCoap.Option

  @tlv 11_542

  setup do
    tree =
      Tree.from_map(%{
        3 => %{
          0 => %{
            0 => {:string, "ACME Corp"},
            9 => {:integer, 87},
            13 => {:time, 1_700_000_000}
          }
        }
      })

    tree =
      tree
      |> Tree.put(path!("/3/0/6/0"), {:integer, 1})
      |> Tree.put(path!("/3/0/6/1"), {:integer, 5})

    {:ok, device} = CoapDeviceHandler.start_device(tree)

    {:ok, device_endpoint} =
      Endpoint.start_link(
        handler: CoapDeviceHandler,
        handler_state: %{device: device, model: model()}
      )

    {:ok, server} = Endpoint.start_link([])

    on_exit(fn ->
      stop_quietly(server)
      stop_quietly(device_endpoint)
    end)

    %{
      device: device,
      server: server,
      model: model(),
      peer: {{127, 0, 0, 1}, Endpoint.port(device_endpoint)}
    }
  end

  describe "Read over TLV" do
    test "an Object Instance comes back typed, not merely byte-correct", ctx do
      path = path!("/3/0")

      assert {:ok, response} =
               send_request(ctx, %Request.Read{path: path, accept_content_format: @tlv})

      assert response.status == :content
      assert response.content_format == @tlv

      assert {:ok, pack} = Tlv.decode(response.payload, path: path, model: ctx.model)
      assert {:ok, rebuilt} = Tree.apply_pack(Tree.new(), pack, model: ctx.model)

      # The point of the model: 1_700_000_000 arrives as a Time, not as an Integer that
      # happens to have the same bytes.
      assert Tree.fetch(rebuilt, path!("/3/0/13")) == {:ok, {:time, 1_700_000_000}}
      assert Tree.fetch(rebuilt, path!("/3/0/9")) == {:ok, {:integer, 87}}
      assert Tree.fetch(rebuilt, path!("/3/0/0")) == {:ok, {:string, "ACME Corp"}}
    end

    test "a single Resource comes back as one entry", ctx do
      path = path!("/3/0/9")

      assert {:ok, response} =
               send_request(ctx, %Request.Read{path: path, accept_content_format: @tlv})

      assert response.content_format == @tlv
      assert response.payload == Base.decode16!("C10957")
    end

    test "a multiple Resource keeps its Instances", ctx do
      path = path!("/3/0")

      assert {:ok, response} =
               send_request(ctx, %Request.Read{path: path, accept_content_format: @tlv})

      assert {:ok, pack} = Tlv.decode(response.payload, path: path, model: ctx.model)
      assert {:ok, rebuilt} = Tree.apply_pack(Tree.new(), pack, model: ctx.model)

      assert Tree.fetch(rebuilt, path!("/3/0/6/0")) == {:ok, {:integer, 1}}
      assert Tree.fetch(rebuilt, path!("/3/0/6/1")) == {:ok, {:integer, 5}}
    end

    test "the device still answers SenML when that is what was asked for", ctx do
      assert {:ok, response} =
               send_request(ctx, %Request.Read{path: path!("/3/0/9"), accept_content_format: 112})

      assert response.content_format == 112
    end
  end

  describe "Write over TLV" do
    test "a server can write an Object Instance", ctx do
      path = path!("/3/0")

      pack =
        Pack.new([
          %Record{name: "/3/0/0", string_value: "Rebranded"},
          %Record{name: "/3/0/9", number_value: 42}
        ])

      {:ok, payload} = Tlv.encode(pack, path: path, model: ctx.model)

      assert {:ok, response} =
               send_request(ctx, %Request.Write{
                 path: path,
                 content_format: @tlv,
                 payload: IO.iodata_to_binary(payload)
               })

      assert response.status == :changed

      tree = CoapDeviceHandler.tree(ctx.device)
      assert Tree.fetch(tree, path!("/3/0/0")) == {:ok, {:string, "Rebranded"}}
      assert Tree.fetch(tree, path!("/3/0/9")) == {:ok, {:integer, 42}}
    end

    test "a written Time lands as a Time, not an Integer", ctx do
      path = path!("/3/0")

      pack =
        Pack.new([%Record{name: "/3/0/13", number_value: 1_800_000_000}])

      {:ok, payload} = Tlv.encode(pack, path: path, model: ctx.model)

      assert {:ok, %Response{status: :changed}} =
               send_request(ctx, %Request.Write{
                 path: path,
                 content_format: @tlv,
                 payload: IO.iodata_to_binary(payload)
               })

      tree = CoapDeviceHandler.tree(ctx.device)
      assert Tree.fetch(tree, path!("/3/0/13")) == {:ok, {:time, 1_800_000_000}}
    end
  end

  describe "a full round trip" do
    test "Read then Write back leaves the device unchanged", ctx do
      path = path!("/3/0")

      assert {:ok, read} =
               send_request(ctx, %Request.Read{path: path, accept_content_format: @tlv})

      before = CoapDeviceHandler.tree(ctx.device)

      assert {:ok, %Response{status: :changed}} =
               send_request(ctx, %Request.Write{
                 path: path,
                 content_format: @tlv,
                 payload: read.payload
               })

      assert Tree.subtree(CoapDeviceHandler.tree(ctx.device), path) == Tree.subtree(before, path)
    end
  end

  defp model do
    resource = fn id, type, multiplicity ->
      %Resource{
        resource_id: id,
        name: "Resource #{id}",
        type: type,
        operations: [:read, :write],
        multiple_instances: multiplicity,
        mandatory: :optional
      }
    end

    Registry.from_definitions([
      %Definition{
        object_id: 3,
        name: "Device",
        multiple_instances: :single,
        mandatory: :mandatory,
        resources: [
          resource.(0, :string, :single),
          resource.(6, :integer, :multiple),
          resource.(9, :integer, :single),
          resource.(13, :time, :single)
        ]
      }
    ])
  end

  defp send_request(ctx, request) do
    wire = Request.to_wire(request)

    message = %Message{
      type: :con,
      code: wire.method,
      message_id: 0,
      token: <<>>,
      options: Enum.map(Wire.to_coap_options(wire), fn {n, v} -> Option.new(n, v) end),
      payload: wire.payload
    }

    with {:ok, reply} <- Endpoint.request(ctx.server, ctx.peer, message, timeout: 2_000) do
      {:ok, decode_response(reply)}
    end
  end

  defp decode_response(%Message{} = message) do
    options = Enum.map(message.options, &{&1.number, &1.value})
    {:ok, wire} = Wire.Response.parse(WickCoap.Code.encode(message.code), options, message.payload)
    Response.from_wire(wire)
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

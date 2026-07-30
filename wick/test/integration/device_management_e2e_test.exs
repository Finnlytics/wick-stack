defmodule Wick.Integration.DeviceManagementE2ETest do
  @moduledoc """
  End-to-end test of the Device Management interface (LwM2M 1.2 §6.4) over real CoAP/UDP.

  A `WickCoap.Endpoint` runs `Wick.Test.CoapDeviceHandler` and plays the device; the test
  plays the server. Every operation goes out through `Wick.Request.to_wire/1`, over the wire,
  back through `Wick.Request.from_wire/1` on the device, and the response returns through
  `Wick.Response.to_wire/1` / `from_wire/1`.

  What this catches that the unit tests cannot: an option that encodes correctly but that the
  other side does not put back together the same way, and any operation whose method/path
  combination a real CoAP endpoint routes somewhere unexpected.
  """

  use ExUnit.Case, async: false

  alias Wick.Attributes
  alias Wick.Codec.SenmlCbor
  alias Wick.CoreLink
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

  setup do
    tree =
      Tree.from_map(%{
        1 => %{0 => %{0 => {:integer, 101}, 1 => {:integer, 86_400}}},
        3 => %{
          0 => %{
            0 => {:string, "ACME Corp"},
            1 => {:string, "Model-1"},
            9 => {:integer, 87},
            14 => {:string, "+00:00"}
          }
        },
        3303 => %{0 => %{5700 => {:float, 22.5}, 5701 => {:string, "Cel"}}}
      })

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

  describe "Read" do
    test "a single Resource comes back as a SenML pack", ctx do
      assert {:ok, response} = send_request(ctx, %Request.Read{path: path!("/3303/0/5700")})

      assert response.status == :content
      assert response.content_format == 112
      assert {:ok, pack} = SenmlCbor.decode(response.payload, [])
      assert [{"/3303/0/5700", _time, record}] = Pack.resolve(pack)
      assert record.number_value == 22.5
    end

    test "text/plain is honoured when the server asks for it", ctx do
      request = %Request.Read{path: path!("/3/0/0"), accept_content_format: 0}

      assert {:ok, response} = send_request(ctx, request)
      assert response.content_format == 0
      assert response.payload == "ACME Corp"
    end

    test "an Object Instance returns every Resource under it", ctx do
      assert {:ok, response} = send_request(ctx, %Request.Read{path: path!("/3303/0")})
      assert {:ok, pack} = SenmlCbor.decode(response.payload, [])

      assert Pack.resolve(pack) |> Enum.map(fn {name, _t, _r} -> name end) ==
               ["/3303/0/5700", "/3303/0/5701"]
    end

    test "an unknown path is 4.04 Not Found", ctx do
      assert {:ok, response} = send_request(ctx, %Request.Read{path: path!("/9999/0/1")})

      assert response.status == :not_found
      assert Response.error?(response)
    end
  end

  describe "Write" do
    test "replace on a single Resource takes effect", ctx do
      pack = Pack.new([%Record{name: "/3/0/14", string_value: "+02:00"}])
      {:ok, payload} = SenmlCbor.encode(pack, [])

      request = %Request.Write{
        path: path!("/3/0/14"),
        content_format: 112,
        payload: IO.iodata_to_binary(payload)
      }

      assert {:ok, response} = send_request(ctx, request)
      assert response.status == :changed

      assert {:ok, {:string, "+02:00"}} =
               Tree.fetch(CoapDeviceHandler.tree(ctx.device), path!("/3/0/14"))
    end

    test "partial update on an Object Instance merges rather than replacing", ctx do
      pack = Pack.new([%Record{name: "1", number_value: 120}])
      {:ok, payload} = SenmlCbor.encode(pack, [])

      request = %Request.Write{
        path: path!("/1/0"),
        content_format: 112,
        payload: IO.iodata_to_binary(payload),
        mode: :partial_update
      }

      assert {:ok, %{status: :changed}} = send_request(ctx, request)

      tree = CoapDeviceHandler.tree(ctx.device)
      assert {:ok, {:integer, 120}} = Tree.fetch(tree, path!("/1/0/1"))
      # The Resource that was not mentioned survives.
      assert {:ok, {:integer, 101}} = Tree.fetch(tree, path!("/1/0/0"))
    end
  end

  describe "Execute" do
    test "invokes with arguments", ctx do
      request = %Request.Execute{path: path!("/3/0/4"), arguments: "1='reboot'"}

      assert {:ok, %{status: :changed}} = send_request(ctx, request)

      assert {:ok, {:string, "1='reboot'"}} =
               Tree.fetch(CoapDeviceHandler.tree(ctx.device), path!("/3/0/4"))
    end

    test "invokes without arguments", ctx do
      assert {:ok, %{status: :changed}} =
               send_request(ctx, %Request.Execute{path: path!("/3/0/4")})

      assert {:ok, {:string, ""}} =
               Tree.fetch(CoapDeviceHandler.tree(ctx.device), path!("/3/0/4"))
    end

    test "on a missing Object Instance is 4.04", ctx do
      assert {:ok, %{status: :not_found}} =
               send_request(ctx, %Request.Execute{path: path!("/9999/0/4")})
    end
  end

  describe "Discover" do
    test "returns CoRE Links for the target and its Resources", ctx do
      assert {:ok, response} = send_request(ctx, %Request.Discover{path: path!("/3303/0")})

      assert response.content_format == 40
      assert {:ok, links} = CoreLink.decode(response.payload)

      assert Enum.map(links, & &1.target) == ["/3303/0", "/3303/0/5700", "/3303/0/5701"]
    end

    test "reports the attributes currently in force", ctx do
      write_attributes = %Request.WriteAttributes{
        path: path!("/3303/0/5700"),
        attributes: %Attributes{pmin: 10, pmax: 60}
      }

      assert {:ok, %{status: :changed}} = send_request(ctx, write_attributes)
      assert {:ok, response} = send_request(ctx, %Request.Discover{path: path!("/3303/0")})
      assert {:ok, links} = CoreLink.decode(response.payload)

      link = Enum.find(links, &(&1.target == "/3303/0/5700"))
      assert link.params["pmin"] == "10"
      assert link.params["pmax"] == "60"
    end
  end

  describe "Write-Attributes" do
    test "the device stores what the server wrote", ctx do
      request = %Request.WriteAttributes{
        path: path!("/3303/0/5700"),
        attributes: %Attributes{pmin: 5, pmax: 30, gt: 25.5, st: 1}
      }

      assert {:ok, %{status: :changed}} = send_request(ctx, request)

      assert CoapDeviceHandler.attributes(ctx.device, path!("/3303/0/5700")) ==
               %Attributes{pmin: 5, pmax: 30, gt: 25.5, st: 1}
    end

    test "a clear removes a previously written attribute", ctx do
      path = path!("/3303/0/5700")

      assert {:ok, _set} =
               send_request(ctx, %Request.WriteAttributes{
                 path: path,
                 attributes: %Attributes{pmin: 5, pmax: 30}
               })

      assert {:ok, _cleared} =
               send_request(ctx, %Request.WriteAttributes{
                 path: path,
                 attributes: %Attributes{pmax: :clear}
               })

      assert CoapDeviceHandler.attributes(ctx.device, path) == %Attributes{pmin: 5}
    end
  end

  describe "Create and Delete" do
    test "Create returns 2.01 with the new Instance in Location-Path", ctx do
      pack = Pack.new([%Record{name: "0", number_value: 102}])
      {:ok, payload} = SenmlCbor.encode(pack, [])

      request = %Request.Create{
        path: path!("/1"),
        content_format: 112,
        payload: IO.iodata_to_binary(payload)
      }

      assert {:ok, response} = send_request(ctx, request)
      assert response.status == :created
      # /1/0 already exists in the fixture, so the device allocates /1/1.
      assert Path.format(response.location_path) == "/1/1"

      assert {:ok, {:integer, 102}} =
               Tree.fetch(CoapDeviceHandler.tree(ctx.device), path!("/1/1/0"))
    end

    test "Delete removes the Instance and its Resources", ctx do
      assert {:ok, response} = send_request(ctx, %Request.Delete{path: path!("/3303/0")})
      assert response.status == :deleted

      tree = CoapDeviceHandler.tree(ctx.device)
      refute Tree.instance?(tree, 3303, 0)
      assert Tree.fetch(tree, path!("/3303/0/5700")) == :error
    end

    test "Delete of a missing Instance is 4.04", ctx do
      assert {:ok, %{status: :not_found}} =
               send_request(ctx, %Request.Delete{path: path!("/3303/7")})
    end
  end

  describe "Composite operations" do
    test "Read-Composite gathers paths from different Objects in one exchange", ctx do
      request = %Request.ReadComposite{
        paths: [path!("/3/0/9"), path!("/3303/0/5700")],
        accept_content_format: 112
      }

      assert {:ok, response} = send_request(ctx, request)
      assert {:ok, pack} = SenmlCbor.decode(response.payload, [])

      assert Pack.resolve(pack) |> Enum.map(fn {name, _t, _r} -> name end) ==
               ["/3/0/9", "/3303/0/5700"]
    end

    test "Write-Composite writes across Objects in one exchange", ctx do
      pack =
        Pack.new([
          %Record{name: "/3/0/14", string_value: "+05:30"},
          %Record{name: "/1/0/1", number_value: 300}
        ])

      {:ok, payload} = SenmlCbor.encode(pack, [])

      request = %Request.WriteComposite{
        content_format: 112,
        payload: IO.iodata_to_binary(payload)
      }

      assert {:ok, %{status: :changed}} = send_request(ctx, request)

      tree = CoapDeviceHandler.tree(ctx.device)
      assert {:ok, {:string, "+05:30"}} = Tree.fetch(tree, path!("/3/0/14"))
      assert {:ok, {:integer, 300}} = Tree.fetch(tree, path!("/1/0/1"))
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

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
    code = WickCoap.Code.encode(message.code)

    {:ok, wire} = Wire.Response.parse(code, options, message.payload || "")
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

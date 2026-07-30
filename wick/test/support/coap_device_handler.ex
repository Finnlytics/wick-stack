defmodule Wick.Test.CoapDeviceHandler do
  @moduledoc """
  Test adapter that makes a `WickCoap.Endpoint` behave as an LwM2M **client** (a device):
  it answers the Device Management and Information Reporting operations a server sends,
  against a `Wick.Object.Tree`.

  The counterpart to `Wick.Test.CoapRegistrationHandler`, which plays the server side. Where
  that one exercises `/rd`, this one exercises `/{object}/{instance}/{resource}` — the whole
  DM surface — and is the piece that proves `Wick.Request.from_wire/1` can drive a real
  device.

  The flow for every inbound request is the same four steps, and is deliberately
  transport-thin, because that is the claim being tested:

      CoAP Message
        |> Wick.Wire.parse/3            # options -> transport-agnostic spec
        |> Wick.Request.from_wire/1     # spec -> a Wick.Request.* struct
        |> dispatch against the tree    # the only application logic here
        |> Wick.Response.to_wire/1      # back out to CoAP

  Observe needs no special handling: `WickCoap.Endpoint` spots the Observe option, registers
  the relation, and grafts the sequence number onto whatever response this handler returns.
  A device pushes value changes with `notify/3` below.

  State is an Agent holding a `Wick.Object.Tree`, passed via `handler_state`.
  """

  @behaviour WickCoap.Handler

  alias Wick.Attributes
  alias Wick.Codec.PlainText
  alias Wick.Codec.SenmlCbor
  alias Wick.CoreLink
  alias Wick.Object.Tree
  alias Wick.Path
  alias Wick.Request
  alias Wick.Response
  alias Wick.Status
  alias Wick.Wire
  alias WickCoap.Endpoint
  alias WickCoap.Message
  alias WickCoap.Option

  @senml_cbor 112
  @plain_text 0

  # ── Setup helpers ──────────────────────────────────────────────────────────

  @doc "Start an Agent holding `tree` (default empty)."
  @spec start_device(Tree.t()) :: {:ok, pid()}
  def start_device(tree \\ Tree.new()) do
    Agent.start_link(fn -> tree end)
  end

  @doc "Read the device's current tree."
  @spec tree(pid()) :: Tree.t()
  def tree(device), do: Agent.get(device, & &1)

  @doc "Mutate the device's tree out-of-band, as a sensor reading would."
  @spec update_tree(pid(), (Tree.t() -> Tree.t())) :: :ok
  def update_tree(device, fun), do: Agent.update(device, fun)

  @doc """
  Push a Notification for `path` to every observer registered on this endpoint, carrying the
  tree's current value. Returns the number of notifications dispatched.

  This is the device-side half of Information Reporting: `WickCoap.Endpoint` owns the
  relations and the sequence numbers, Wick supplies the payload.
  """
  @spec notify(pid(), pid(), Path.t()) :: non_neg_integer()
  def notify(endpoint, device, %Path{} = path) do
    tree = tree(device)
    {content_format, payload} = encode_read(tree, path, @senml_cbor)

    template = %Message{
      type: :non,
      code: :content,
      message_id: 0,
      token: <<>>,
      options: [Option.from_uint(12, content_format)],
      payload: payload
    }

    Endpoint.notify_observers(endpoint, Path.to_segments(path), template)
  end

  # ── Handler ────────────────────────────────────────────────────────────────

  @impl WickCoap.Handler
  def handle_request(%Message{} = message, _peer, %{device: device}) do
    response =
      with {:ok, wire} <- parse(message),
           {:ok, request} <- Request.from_wire(wire) do
        Agent.get_and_update(device, fn tree -> dispatch(request, tree) end)
      else
        {:error, error} -> Response.error(:bad_request, error.message)
      end

    {:reply, to_coap(response, message)}
  end

  defp parse(%Message{} = message) do
    options = Enum.map(message.options, &{&1.number, &1.value})
    Wire.parse(message.code, options, message.payload || "")
  end

  # ── Dispatch — the only LwM2M application logic in this module ─────────────

  defp dispatch(%Request.Read{} = request, tree) do
    if Tree.exists?(tree, request.path) do
      {content_format, payload} =
        encode_read(tree, request.path, request.accept_content_format || @senml_cbor)

      {Response.content(content_format, payload), tree}
    else
      {Response.error(:not_found), tree}
    end
  end

  # Observe answers exactly as a Read does; the Endpoint adds the Observe option.
  defp dispatch(%Request.Observe{} = request, tree) do
    dispatch(
      %Request.Read{path: request.path, accept_content_format: request.accept_content_format},
      tree
    )
  end

  defp dispatch(%Request.CancelObserve{} = request, tree) do
    dispatch(%Request.Read{path: request.path}, tree)
  end

  defp dispatch(%Request.Write{} = request, tree) do
    case decode_write(request.content_format, request.payload, request.path) do
      {:ok, value_or_pack} -> {Response.changed(), apply_write(tree, request.path, value_or_pack)}
      {:error, error} -> {Response.error(:bad_request, error.message), tree}
    end
  end

  defp dispatch(%Request.WriteComposite{} = request, tree) do
    with {:ok, pack} <- SenmlCbor.decode(request.payload, []),
         {:ok, tree} <- Tree.apply_pack(tree, pack) do
      {Response.changed(), tree}
    else
      {:error, error} -> {Response.error(:bad_request, error.message), tree}
    end
  end

  # Execute has no value semantics here — record the invocation so a test can assert on it.
  defp dispatch(%Request.Execute{} = request, tree) do
    if Tree.exists?(tree, %{request.path | resource_id: nil}) do
      {Response.changed(), Tree.put(tree, request.path, {:string, request.arguments || ""})}
    else
      {Response.error(:not_found), tree}
    end
  end

  defp dispatch(%Request.Discover{} = request, tree) do
    if Tree.exists?(tree, request.path) do
      payload = CoreLink.encode(Tree.discover(tree, request.path))
      {Response.content(CoreLink.content_format(), payload), tree}
    else
      {Response.error(:not_found), tree}
    end
  end

  defp dispatch(%Request.Create{} = request, tree) do
    instance_id = Tree.next_instance_id(tree, request.path.object_id)
    location = %Path{object_id: request.path.object_id, object_instance_id: instance_id}

    with {:ok, pack} <- SenmlCbor.decode(request.payload, []),
         {:ok, tree} <- Tree.apply_pack(tree, pack, location) do
      {Response.created(location), Tree.create_instance(tree, location.object_id, instance_id)}
    else
      {:error, error} -> {Response.error(:bad_request, error.message), tree}
    end
  end

  defp dispatch(%Request.Delete{} = request, tree) do
    if Tree.exists?(tree, request.path) do
      {Response.deleted(),
       Tree.delete_instance(tree, request.path.object_id, request.path.object_instance_id)}
    else
      {Response.error(:not_found), tree}
    end
  end

  defp dispatch(%Request.WriteAttributes{} = request, tree) do
    if Tree.exists?(tree, request.path) do
      {Response.changed(), Tree.put_attributes(tree, request.path, request.attributes)}
    else
      {Response.error(:not_found), tree}
    end
  end

  defp dispatch(%Request.ReadComposite{} = request, tree) do
    {:ok, encoded} = SenmlCbor.encode(Tree.to_pack(tree, request.paths), [])
    {Response.content(@senml_cbor, IO.iodata_to_binary(encoded)), tree}
  end

  defp dispatch(%Request.ObserveComposite{} = request, tree) do
    dispatch(%Request.ReadComposite{paths: request.paths}, tree)
  end

  # ── Encoding ───────────────────────────────────────────────────────────────

  # A single Resource may go out as text/plain if that is what the server asked for;
  # anything wider is always a SenML Pack.
  defp encode_read(tree, %Path{resource_id: rid} = path, @plain_text) when rid != nil do
    case Tree.fetch(tree, path) do
      {:ok, value} ->
        {:ok, encoded} = PlainText.encode(value, [])
        {@plain_text, IO.iodata_to_binary(encoded)}

      :error ->
        encode_read(tree, path, @senml_cbor)
    end
  end

  defp encode_read(tree, %Path{} = path, _content_format) do
    {:ok, encoded} = SenmlCbor.encode(Tree.to_pack(tree, [path]), [])
    {@senml_cbor, IO.iodata_to_binary(encoded)}
  end

  defp decode_write(@plain_text, payload, _path), do: {:ok, {:plain, payload}}

  defp decode_write(_senml, payload, _path) do
    with {:ok, pack} <- SenmlCbor.decode(payload, []), do: {:ok, {:pack, pack}}
  end

  defp apply_write(tree, path, {:plain, payload}) do
    # text/plain carries no type information; store it as a string and let the test assert
    # on the raw bytes. A real device consults its Object definition to coerce.
    Tree.put(tree, path, {:string, payload})
  end

  defp apply_write(tree, path, {:pack, pack}) do
    {:ok, tree} = Tree.apply_pack(tree, pack, path)
    tree
  end

  # ── CoAP out ───────────────────────────────────────────────────────────────

  defp to_coap(%Response{} = response, %Message{} = request) do
    wire = Response.to_wire(response)
    {class, detail} = Status.to_coap(wire.status)

    %Message{
      type: :ack,
      code: {class, detail},
      message_id: request.message_id,
      token: request.token,
      options: Enum.map(Wire.Response.to_coap_options(wire), fn {n, v} -> Option.new(n, v) end),
      payload: wire.payload
    }
  end

  @doc """
  Convenience for tests: the attributes the device currently holds at `path`.
  """
  @spec attributes(pid(), Path.t()) :: Attributes.t()
  def attributes(device, %Path{} = path), do: Tree.attributes(tree(device), path)
end

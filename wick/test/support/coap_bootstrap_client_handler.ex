defmodule Wick.Test.CoapBootstrapClientHandler do
  @moduledoc """
  Test adapter for the **client** side of the Bootstrap interface: a `WickCoap.Handler` that
  accepts the operations a Bootstrap Server pushes and applies them to a `Wick.Object.Tree`.

  Routes through `Wick.Bootstrap.from_wire/1` rather than `Wick.Request.from_wire/1`. That
  choice is the whole point: on the wire a Bootstrap-Write is indistinguishable from a
  Device Management Write, and only the client's knowledge that a bootstrap session is open
  tells it which permissions apply. This handler is what "a bootstrap session is open" looks
  like in practice.

  Bootstrap-Finish triggers validation: the client answers `2.04 Changed` only if it now
  holds at least one Security Instance and one Server Instance, and `4.06 Not Acceptable`
  otherwise. That check is the reason Bootstrap-Finish exists — a client that accepted a
  half-finished plan would deregister itself from the network.

  State is an Agent holding `%{tree: Wick.Object.Tree.t(), finished?: boolean()}`.
  """

  @behaviour WickCoap.Handler

  alias Wick.Bootstrap
  alias Wick.Codec.SenmlCbor
  alias Wick.CoreLink
  alias Wick.Object.Tree
  alias Wick.Path
  alias Wick.Response
  alias Wick.Status
  alias Wick.Wire
  alias WickCoap.Message
  alias WickCoap.Option

  @security_object 0
  @server_object 1

  @doc "Start an Agent holding a client that has not yet been bootstrapped."
  @spec start_client(Tree.t()) :: {:ok, pid()}
  def start_client(tree \\ Tree.new()) do
    Agent.start_link(fn -> %{tree: tree, finished?: false} end)
  end

  @doc "The client's current Object tree."
  @spec tree(pid()) :: Tree.t()
  def tree(client), do: Agent.get(client, & &1.tree)

  @doc "True once the client has accepted a Bootstrap-Finish."
  @spec finished?(pid()) :: boolean()
  def finished?(client), do: Agent.get(client, & &1.finished?)

  @impl WickCoap.Handler
  def handle_request(%Message{} = message, _peer, %{client: client}) do
    response =
      with {:ok, wire} <- parse(message),
           {:ok, operation} <- Bootstrap.from_wire(wire) do
        Agent.get_and_update(client, fn state -> apply_operation(operation, state) end)
      else
        {:error, error} -> Response.error(:bad_request, error.message)
      end

    {:reply, to_coap(response, message)}
  end

  defp parse(%Message{} = message) do
    options = Enum.map(message.options, &{&1.number, &1.value})
    Wire.parse(message.code, options, message.payload || "")
  end

  # ── Operations ─────────────────────────────────────────────────────────────

  # A Bootstrap-Write may create Instances and may target the Security Object — neither of
  # which a Device Management Write is allowed to do.
  defp apply_operation(%Bootstrap.Write{} = write, state) do
    base = if write.path.resource_id, do: nil, else: write.path

    with {:ok, pack} <- SenmlCbor.decode(write.payload, []),
         {:ok, tree} <- Tree.apply_pack(state.tree, pack, base) do
      {Response.changed(), %{state | tree: tree}}
    else
      {:error, error} -> {Response.error(:bad_request, error.message), state}
    end
  end

  # The root form wipes everything; the targeted form removes one Instance.
  defp apply_operation(%Bootstrap.Delete{path: nil}, state) do
    {Response.deleted(), %{state | tree: Tree.new()}}
  end

  defp apply_operation(%Bootstrap.Delete{path: path}, state) do
    {Response.deleted(),
     %{state | tree: Tree.delete_instance(state.tree, path.object_id, path.object_instance_id)}}
  end

  defp apply_operation(%Bootstrap.Discover{} = discover, state) do
    links =
      case discover.path do
        nil -> Tree.links(state.tree)
        path -> Tree.discover(state.tree, path)
      end

    {Response.content(CoreLink.content_format(), CoreLink.encode(links)), state}
  end

  # Reading the Security Object back would disclose credentials, so it is forbidden.
  defp apply_operation(%Bootstrap.Read{path: %Path{object_id: @security_object}}, state) do
    {Response.error(:method_not_allowed, "the Security Object cannot be read back"), state}
  end

  defp apply_operation(%Bootstrap.Read{} = read, state) do
    if Tree.exists?(state.tree, read.path) do
      {:ok, encoded} = SenmlCbor.encode(Tree.to_pack(state.tree, [read.path]), [])
      {Response.content(112, IO.iodata_to_binary(encoded)), state}
    else
      {Response.error(:not_found), state}
    end
  end

  defp apply_operation(%Bootstrap.Finish{}, state) do
    if provisioned?(state.tree) do
      {Response.changed(), %{state | finished?: true}}
    else
      {Response.error(:not_acceptable, "no usable Security and Server Object pair"), state}
    end
  end

  # A Bootstrap-Request arriving at a client is nonsense — it is the client that sends one.
  defp apply_operation(%Bootstrap.Request{}, state) do
    {Response.error(:method_not_allowed, "a client does not receive Bootstrap-Request"), state}
  end

  defp provisioned?(tree) do
    Tree.instance_ids(tree, @security_object) != [] and
      Tree.instance_ids(tree, @server_object) != []
  end

  defp to_coap(%Response{} = response, %Message{} = request) do
    wire = Response.to_wire(response)

    %Message{
      type: :ack,
      code: Status.to_coap(wire.status),
      message_id: request.message_id,
      token: request.token,
      options: Enum.map(Wire.Response.to_coap_options(wire), fn {n, v} -> Option.new(n, v) end),
      payload: wire.payload
    }
  end
end

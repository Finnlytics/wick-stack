defmodule WickDemoClient.Device do
  @moduledoc """
  Owns the client's `Wick.Object.Tree` and answers the operations a server sends against it.

  This is where the demo stops being a registration toy and becomes a device: everything a
  server can do to an LwM2M client — Read, Write, Execute, Discover, Create, Delete,
  Write-Attributes, Observe — resolves here, plus the Bootstrap operations while a bootstrap
  session is open.

  ## What is library and what is policy

  `dispatch/2` is the interesting boundary. Wick has already done the protocol work by the
  time a request reaches it: `Wick.Request.from_wire/1` decided *which operation this is*,
  including the awkward cases (a `POST` on a Resource path is an Execute, on an Object
  Instance a partial-update Write). What is left here is genuinely the device's business:

  * whether a path exists (`4.04`) and whether the operation is allowed on it (`4.05`)
  * which Content-Format to answer in
  * what Execute actually *does* — rebooting is not something a protocol library can decide

  ## Bootstrap routing

  A Bootstrap-Write and a Device Management Write are identical on the wire. The only thing
  that distinguishes them is whether a bootstrap session is open, so that flag lives here and
  `dispatch/2` routes on it. See `Wick.Bootstrap`.

  ## Notification gating

  When a value changes, `notify_decision/3` applies the `Wick.Attributes` the server wrote
  (pmin / pmax / gt / lt / st) to decide whether a Notification is due. The per-path state
  that decision needs — last notified value and timestamp — is held here, because
  `Wick.Attributes.should_notify?/3` is deliberately pure and owns no clock.
  """

  use GenServer

  require Logger

  alias Wick.Attributes
  alias Wick.Bootstrap
  alias Wick.Codec.PlainText
  alias Wick.Codec.SenmlCbor
  alias Wick.CoreLink
  alias Wick.Object.Tree
  alias Wick.Path
  alias Wick.Request
  alias Wick.Response
  alias WickDemoClient.Objects

  @name __MODULE__

  @senml_cbor 112
  @plain_text 0
  @security_object 0
  @server_object 1

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "The current Object tree."
  @spec tree(GenServer.server()) :: Tree.t()
  def tree(server \\ @name), do: GenServer.call(server, :tree)

  @doc "The CoRE Links to advertise on Register / Update, derived from the tree."
  @spec links(GenServer.server()) :: [CoreLink.Link.t()]
  def links(server \\ @name), do: GenServer.call(server, :links)

  @doc """
  Handle one inbound operation and return the `Wick.Response` to send back.

  Takes a `Wick.Wire`, because *which* decoder to use is a function of session state that
  only this process knows.
  """
  @spec handle_wire(GenServer.server(), Wick.Wire.t()) :: Response.t()
  def handle_wire(server \\ @name, wire), do: GenServer.call(server, {:handle_wire, wire})

  @doc """
  Record a new sensor reading. Returns `{:notify, content_format, payload}` when the
  notification attributes say a Notification is due, or `:quiet` when they do not.
  """
  @spec record_temperature(GenServer.server(), float()) ::
          {:notify, non_neg_integer(), binary()} | :quiet
  def record_temperature(server \\ @name, reading) do
    GenServer.call(server, {:record_temperature, reading})
  end

  @doc "Encode a subtree as a SenML CBOR payload — for a Notify or a Send body."
  @spec encode_paths(GenServer.server(), [Path.t()]) :: {non_neg_integer(), binary()}
  def encode_paths(server \\ @name, paths), do: GenServer.call(server, {:encode_paths, paths})

  @doc "Open a bootstrap session, so inbound traffic routes through `Wick.Bootstrap`."
  @spec begin_bootstrap(GenServer.server()) :: :ok
  def begin_bootstrap(server \\ @name), do: GenServer.call(server, :begin_bootstrap)

  @doc "True while a bootstrap session is open."
  @spec bootstrapping?(GenServer.server()) :: boolean()
  def bootstrapping?(server \\ @name), do: GenServer.call(server, :bootstrapping?)

  @doc "Number of times the Reboot Resource has been executed. Demo instrumentation."
  @spec reboot_count(GenServer.server()) :: non_neg_integer()
  def reboot_count(server \\ @name), do: GenServer.call(server, :reboot_count)

  @doc """
  Restore the device to its factory state: the initial tree, no notification attributes, no
  notification history, no bootstrap session.

  Demo and test convenience. Note that resetting the tree does **not** cancel Observe
  relations — those live in `WickCoap.Endpoint` and on the server — which mirrors reality: a
  device that factory-resets leaves the server holding relations it must clean up itself.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ @name), do: GenServer.call(server, :reset)

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    lifetime = Keyword.get_lazy(opts, :lifetime, fn -> config(:lifetime, 60) end)

    {:ok,
     %{
       tree: Keyword.get_lazy(opts, :tree, fn -> Objects.initial_tree(lifetime) end),
       bootstrapping?: false,
       reboot_count: 0,
       # path key => %{last_value: term(), last_notified_at: integer()}
       notified: %{}
     }}
  end

  @impl GenServer
  def handle_call(:tree, _from, state), do: {:reply, state.tree, state}
  def handle_call(:links, _from, state), do: {:reply, Tree.links(state.tree), state}
  def handle_call(:bootstrapping?, _from, state), do: {:reply, state.bootstrapping?, state}
  def handle_call(:reboot_count, _from, state), do: {:reply, state.reboot_count, state}

  def handle_call(:begin_bootstrap, _from, state) do
    {:reply, :ok, %{state | bootstrapping?: true}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok,
     %{
       state
       | tree: Objects.initial_tree(config(:lifetime, 60)),
         bootstrapping?: false,
         reboot_count: 0,
         notified: %{}
     }}
  end

  def handle_call({:handle_wire, wire}, _from, state) do
    {response, state} = decode_and_dispatch(wire, state)
    {:reply, response, state}
  end

  def handle_call({:encode_paths, paths}, _from, state) do
    {:reply, {@senml_cbor, senml(state.tree, paths)}, state}
  end

  def handle_call({:record_temperature, reading}, _from, state) do
    path = Objects.temperature_path()
    tree = Objects.record_temperature(state.tree, reading)
    state = %{state | tree: tree}

    case notify_due?(state, path, reading) do
      true ->
        {:reply, {:notify, @senml_cbor, senml(tree, [path])}, mark_notified(state, path, reading)}

      false ->
        {:reply, :quiet, state}
    end
  end

  # ── Decoding: which interface is this? ─────────────────────────────────────

  defp decode_and_dispatch(wire, %{bootstrapping?: true} = state) do
    case Bootstrap.from_wire(wire) do
      {:ok, operation} -> bootstrap(operation, state)
      {:error, error} -> {Response.error(:bad_request, error.message), state}
    end
  end

  defp decode_and_dispatch(wire, state) do
    case Request.from_wire(wire) do
      {:ok, request} -> dispatch(request, state)
      {:error, error} -> {Response.error(:bad_request, error.message), state}
    end
  end

  # ── Device Management ──────────────────────────────────────────────────────

  defp dispatch(%Request.Read{} = request, state) do
    if Tree.exists?(state.tree, request.path) do
      {content_format, payload} = read(state.tree, request.path, request.accept_content_format)
      {Response.content(content_format, payload), state}
    else
      {Response.error(:not_found), state}
    end
  end

  # An Observe is answered exactly as a Read; WickCoap.Endpoint attaches the Observe option
  # and owns the relation. The device's only extra job is to seed the notification state, so
  # that pmin is measured from the initial value rather than from epoch.
  defp dispatch(%Request.Observe{} = request, state) do
    {response, state} =
      dispatch(
        %Request.Read{path: request.path, accept_content_format: request.accept_content_format},
        state
      )

    Logger.info("OBSERVE #{Path.format(request.path)} → #{response.status}")

    case Tree.fetch(state.tree, request.path) do
      {:ok, {_type, value}} -> {response, mark_notified(state, request.path, value)}
      :error -> {response, state}
    end
  end

  defp dispatch(%Request.CancelObserve{} = request, state) do
    Logger.info("CANCEL-OBSERVE #{Path.format(request.path)}")
    dispatch(%Request.Read{path: request.path}, state)
  end

  defp dispatch(%Request.Write{} = request, state) do
    cond do
      request.path.object_id == @security_object ->
        # Only a Bootstrap-Write may touch the Security Object (§6.1.3).
        {Response.error(:unauthorized, "the Security Object is writable only via Bootstrap"),
         state}

      not Tree.exists?(state.tree, request.path) and request.mode == :partial_update ->
        {Response.error(:not_found), state}

      true ->
        write(request, state)
    end
  end

  defp dispatch(%Request.WriteComposite{} = request, state) do
    with {:ok, pack} <- decode_senml(request.content_format, request.payload),
         {:ok, tree} <- Tree.apply_pack(state.tree, pack) do
      Logger.info("WRITE-COMPOSITE #{length(pack.records)} record(s)")
      {Response.changed(), %{state | tree: tree}}
    else
      {:error, error} -> {Response.error(:bad_request, error.message), state}
    end
  end

  defp dispatch(%Request.Execute{} = request, state) do
    execute(request, state)
  end

  defp dispatch(%Request.Discover{} = request, state) do
    if Tree.exists?(state.tree, request.path) do
      payload = CoreLink.encode(Tree.discover(state.tree, request.path))
      {Response.content(CoreLink.content_format(), payload), state}
    else
      {Response.error(:not_found), state}
    end
  end

  defp dispatch(%Request.Create{} = request, state) do
    instance_id = Tree.next_instance_id(state.tree, request.path.object_id)
    location = %Path{object_id: request.path.object_id, object_instance_id: instance_id}

    with {:ok, pack} <- decode_senml(request.content_format, request.payload),
         {:ok, tree} <- Tree.apply_pack(state.tree, pack, location) do
      tree = Tree.create_instance(tree, location.object_id, instance_id)
      Logger.info("CREATE #{Path.format(location)}")
      {Response.created(location), %{state | tree: tree}}
    else
      {:error, error} -> {Response.error(:bad_request, error.message), state}
    end
  end

  defp dispatch(%Request.Delete{} = request, state) do
    cond do
      is_nil(request.path.object_instance_id) ->
        {Response.error(:method_not_allowed, "Delete targets an Object Instance"), state}

      not Tree.exists?(state.tree, request.path) ->
        {Response.error(:not_found), state}

      true ->
        Logger.info("DELETE #{Path.format(request.path)}")

        tree =
          Tree.delete_instance(
            state.tree,
            request.path.object_id,
            request.path.object_instance_id
          )

        {Response.deleted(), %{state | tree: tree}}
    end
  end

  defp dispatch(%Request.WriteAttributes{} = request, state) do
    if Tree.exists?(state.tree, request.path) do
      Logger.info(
        "WRITE-ATTRIBUTES #{Path.format(request.path)} #{inspect(Attributes.to_query(request.attributes))}"
      )

      {Response.changed(),
       %{state | tree: Tree.put_attributes(state.tree, request.path, request.attributes)}}
    else
      {Response.error(:not_found), state}
    end
  end

  defp dispatch(%Request.ReadComposite{} = request, state) do
    {Response.content(@senml_cbor, senml(state.tree, request.paths)), state}
  end

  defp dispatch(%Request.ObserveComposite{} = request, state) do
    Logger.info("OBSERVE-COMPOSITE #{Enum.map_join(request.paths, ", ", &Path.format/1)}")
    {Response.content(@senml_cbor, senml(state.tree, request.paths)), state}
  end

  # ── Bootstrap ──────────────────────────────────────────────────────────────

  # A Bootstrap-Write may create Instances and may target the Security Object.
  defp bootstrap(%Bootstrap.Write{} = write, state) do
    base = if write.path.resource_id, do: nil, else: write.path

    with {:ok, pack} <- decode_senml(write.content_format, write.payload),
         {:ok, tree} <- Tree.apply_pack(state.tree, pack, base) do
      Logger.info("BS-WRITE #{Path.format(write.path)}")
      {Response.changed(), %{state | tree: tree}}
    else
      {:error, error} -> {Response.error(:bad_request, error.message), state}
    end
  end

  defp bootstrap(%Bootstrap.Delete{path: nil}, state) do
    Logger.info("BS-DELETE / (all Instances)")
    {Response.deleted(), %{state | tree: Tree.new()}}
  end

  defp bootstrap(%Bootstrap.Delete{path: path}, state) do
    Logger.info("BS-DELETE #{Path.format(path)}")
    tree = Tree.delete_instance(state.tree, path.object_id, path.object_instance_id)
    {Response.deleted(), %{state | tree: tree}}
  end

  defp bootstrap(%Bootstrap.Discover{path: path}, state) do
    links =
      case path do
        nil -> Tree.links(state.tree)
        path -> Tree.discover(state.tree, path)
      end

    {Response.content(CoreLink.content_format(), CoreLink.encode(links)), state}
  end

  # Reading the Security Object back would disclose credentials (§6.1.7).
  defp bootstrap(%Bootstrap.Read{path: %Path{object_id: @security_object}}, state) do
    {Response.error(:method_not_allowed, "the Security Object cannot be read back"), state}
  end

  defp bootstrap(%Bootstrap.Read{} = read, state) do
    if Tree.exists?(state.tree, read.path) do
      {Response.content(@senml_cbor, senml(state.tree, [read.path])), state}
    else
      {Response.error(:not_found), state}
    end
  end

  # Bootstrap-Finish is the client's chance to refuse a half-finished provisioning run. A
  # client that accepted one would come out of bootstrap unable to register.
  defp bootstrap(%Bootstrap.Finish{}, state) do
    if provisioned?(state.tree) do
      Logger.info("BS-FINISH accepted — bootstrap session closed")
      {Response.changed(), %{state | bootstrapping?: false}}
    else
      Logger.warning("BS-FINISH rejected — no usable Security/Server pair")
      {Response.error(:not_acceptable, "no usable Security and Server Object pair"), state}
    end
  end

  defp bootstrap(%Bootstrap.Request{}, state) do
    {Response.error(:method_not_allowed, "a client does not receive Bootstrap-Request"), state}
  end

  # ── Operation helpers ──────────────────────────────────────────────────────

  defp write(%Request.Write{} = request, state) do
    case request.content_format do
      @plain_text ->
        # text/plain carries no type tag. Keep whatever type the Resource already holds, so a
        # Write of "30.5" to a Float Resource stays a Float rather than becoming a String.
        {Response.changed(),
         %{state | tree: write_plain(state.tree, request.path, request.payload)}}

      _senml ->
        # Names in a Write body are relative to the request URI: a Write on /1/0 names the
        # Resource ("1"), a Write on /1/0/1 carries an empty name. Passing the request path as
        # the base handles both, and an absolute name still wins.
        with {:ok, pack} <- decode_senml(request.content_format, request.payload),
             {:ok, tree} <- Tree.apply_pack(state.tree, pack, request.path) do
          Logger.info("WRITE #{Path.format(request.path)} (#{request.mode})")
          {Response.changed(), %{state | tree: tree}}
        else
          {:error, error} -> {Response.error(:bad_request, error.message), state}
        end
    end
  end

  defp write_plain(tree, path, payload) do
    coerced =
      case Tree.fetch(tree, path) do
        {:ok, {:float, _current}} -> parse_number(payload, :float)
        {:ok, {:integer, _current}} -> parse_number(payload, :integer)
        {:ok, {:boolean, _current}} -> {:boolean, payload in ["1", "true"]}
        _unset_or_string -> {:string, payload}
      end

    Tree.put(tree, path, coerced)
  end

  defp parse_number(payload, :float) do
    case Float.parse(payload) do
      {value, ""} -> {:float, value}
      _not_a_float -> {:string, payload}
    end
  end

  defp parse_number(payload, :integer) do
    case Integer.parse(payload) do
      {value, ""} -> {:integer, value}
      _not_an_integer -> {:string, payload}
    end
  end

  # Reboot is the one Execute the demo actually implements; anything else is accepted and
  # counted so a server can see the invocation landed.
  defp execute(%Request.Execute{} = request, state) do
    reboot = Objects.reboot_path()

    cond do
      request.path == reboot ->
        Logger.info("EXECUTE #{Path.format(request.path)} — simulated reboot")
        {Response.changed(), %{state | reboot_count: state.reboot_count + 1}}

      not Tree.exists?(state.tree, %{request.path | resource_id: nil}) ->
        {Response.error(:not_found), state}

      true ->
        Logger.info("EXECUTE #{Path.format(request.path)} args=#{inspect(request.arguments)}")
        {Response.error(:not_implemented, "no handler for this Executable Resource"), state}
    end
  end

  # A single Resource may be answered as text/plain when the server asks for it; anything
  # wider is always SenML, since only SenML can carry more than one value.
  defp read(tree, %Path{resource_id: rid} = path, @plain_text) when rid != nil do
    case Tree.fetch(tree, path) do
      {:ok, value} ->
        case PlainText.encode(value, []) do
          {:ok, encoded} -> {@plain_text, IO.iodata_to_binary(encoded)}
          {:error, _unencodable} -> {@senml_cbor, senml(tree, [path])}
        end

      :error ->
        {@senml_cbor, senml(tree, [path])}
    end
  end

  defp read(tree, %Path{} = path, _content_format), do: {@senml_cbor, senml(tree, [path])}

  defp senml(tree, paths) do
    {:ok, encoded} = SenmlCbor.encode(Tree.to_pack(tree, paths), [])
    IO.iodata_to_binary(encoded)
  end

  defp decode_senml(content_format, payload) do
    case Wick.Codec.senml_codec(content_format) do
      {:ok, codec} ->
        codec.decode(payload, [])

      :error ->
        {:error,
         Wick.Error.new(
           :unsupported_content_format,
           "the demo client decodes SenML CBOR (112) and SenML JSON (110), got: " <>
             inspect(content_format)
         )}
    end
  end

  defp provisioned?(tree) do
    Tree.instance_ids(tree, @security_object) != [] and
      Tree.instance_ids(tree, @server_object) != []
  end

  # ── Notification gating ────────────────────────────────────────────────────

  defp notify_due?(state, path, reading) do
    Attributes.should_notify?(
      Tree.attributes(state.tree, path),
      observation_state(state, path),
      reading
    )
  end

  defp observation_state(state, path) do
    case Map.fetch(state.notified, key(path)) do
      :error ->
        %{last_value: nil, since_last_ms: nil}

      {:ok, %{last_value: value, last_notified_at: at}} ->
        %{last_value: value, since_last_ms: monotonic_ms() - at}
    end
  end

  defp mark_notified(state, path, value) do
    entry = %{last_value: value, last_notified_at: monotonic_ms()}
    %{state | notified: Map.put(state.notified, key(path), entry)}
  end

  defp key(%Path{} = path), do: Path.format(path)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp config(key, default), do: Application.get_env(:wick_demo_client, key, default)
end

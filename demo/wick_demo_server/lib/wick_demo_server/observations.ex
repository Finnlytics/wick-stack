defmodule WickDemoServer.Observations do
  @moduledoc """
  GenServer wrapping `Wick.Observation.Store` — the server's record of what it asked each
  device to observe.

  ## Why this has to exist

  A Notification carries a payload, a Content-Format, and a sequence number. It does **not**
  carry a path. Nothing in the datagram says which Resource changed. The only thing that
  makes an inbound Notify interpretable is the server's own memory of the Observe that caused
  it, keyed by the CoAP token — and that memory is this process.

  Lose it and notifications become undecodable bytes. That is why relations are stored the
  moment `WickCoap.Endpoint.observe/4` returns, not lazily on first notification.

  ## Notification delivery

  Notifications arrive as `{:wick_coap_notification, handle, message}` messages sent to
  whichever process registered the observation. This process registers itself, so
  notifications land in `handle_info/2` here, get correlated against the store, decoded, and
  logged. `WickCoap.Endpoint` has already applied the RFC 7641 §3.4 reordering filter by then;
  `Wick.Observation.accept_seq/3` is applied as well so the stored `last_value` and
  `notified_at` stay right even if a notification reaches us by another route.

  ## Lifetime

  LwM2M ties observations to the registration (§6.2): when a device deregisters or its
  lifetime expires, its relations die with it. `forget_registration/1` is what
  `WickDemoServer.Store` calls on eviction.
  """

  use GenServer

  require Logger

  alias Wick.Attributes
  alias Wick.Codec
  alias Wick.Observation
  alias Wick.Observation.Store
  alias Wick.Path
  alias Wick.Senml.Pack
  alias Wick.Senml.Record
  alias Wick.Uplink
  alias WickCoap.Message
  alias WickDemoServer.Coap
  alias WickDemoServer.Events

  @name __MODULE__

  @typedoc """
  A decoded notification: which path changed, and to what.

  The path is `nil` when the body cannot name it — a single-Resource Notify in `text/plain` or
  an opaque format carries only a value. `label/2` fills it in from the Observe relation, which
  is the only place that information exists.
  """
  @type reading :: {String.t() | nil, term()}

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Register an Observe relation. `handle` is whatever `WickCoap.Endpoint.observe/4` returned.
  """
  @spec put(GenServer.server(), term(), Observation.t()) :: :ok
  def put(server \\ @name, handle, %Observation{} = observation) do
    GenServer.call(server, {:put, handle, observation})
  end

  @doc "The pid notifications should be delivered to — this process."
  @spec notify_pid(GenServer.server()) :: pid()
  def notify_pid(server \\ @name), do: GenServer.call(server, :notify_pid)

  @doc "Every relation currently held."
  @spec list(GenServer.server()) :: [Observation.t()]
  def list(server \\ @name), do: GenServer.call(server, :list)

  @doc "Fetch one relation by handle."
  @spec fetch(GenServer.server(), term()) :: {:ok, Observation.t()} | :error
  def fetch(server \\ @name, handle), do: GenServer.call(server, {:fetch, handle})

  @doc "Drop a relation, after a successful Cancel-Observe."
  @spec forget(GenServer.server(), term()) :: :ok
  def forget(server \\ @name, handle), do: GenServer.call(server, {:forget, handle})

  @doc "Drop every relation belonging to a registration that has gone away."
  @spec forget_registration(GenServer.server(), String.t()) :: :ok
  def forget_registration(server \\ @name, registration_id) do
    GenServer.call(server, {:forget_registration, registration_id})
  end

  @doc """
  The handles observing `path`, optionally scoped to one registration.
  """
  @spec handles_for_path(GenServer.server(), Path.t(), keyword()) :: [term()]
  def handles_for_path(server \\ @name, %Path{} = path, opts \\ []) do
    GenServer.call(server, {:handles_for_path, path, opts})
  end

  @doc """
  The handles a registration is observing under, in the order they were established.

  The web layer needs these to map a browser-supplied handle key back to the opaque transport
  handle it stands for — a `{peer, token}` tuple is not something a browser can hold.
  """
  @spec handles_for_registration(GenServer.server(), String.t()) :: [term()]
  def handles_for_registration(server \\ @name, registration_id) do
    GenServer.call(server, {:handles_for_registration, registration_id})
  end

  @doc """
  The readings received so far, newest first — one entry per notification.

  Demo instrumentation: a production server would write these to a time-series store instead
  of keeping them in memory.
  """
  @spec readings(GenServer.server()) :: [map()]
  def readings(server \\ @name), do: GenServer.call(server, :readings)

  @doc """
  Discard the reading log, keeping the Observe relations intact.

  Demo and test convenience — the log grows without bound otherwise, since nothing here
  persists or expires it.
  """
  @spec clear_readings(GenServer.server()) :: :ok
  def clear_readings(server \\ @name), do: GenServer.call(server, :clear_readings)

  @doc """
  Record an inbound `Wick.Uplink.Send`. Send needs no prior relation, so it is recorded
  straight into the reading log with its source noted as `:send`.
  """
  @spec record_send(GenServer.server(), Uplink.Send.t(), term()) :: :ok
  def record_send(server \\ @name, %Uplink.Send{} = send, peer) do
    GenServer.call(server, {:record_send, send, peer})
  end

  @doc """
  Decode a notification or Send payload into `{path, value}` pairs.

  Exposed because it is the useful half of this module for anyone building on top: given a
  SenML body, what actually changed?
  """
  @spec decode_readings(non_neg_integer(), binary()) :: {:ok, [reading()]} | {:error, term()}
  def decode_readings(content_format, payload) do
    case Codec.senml_codec(content_format) do
      {:ok, codec} ->
        with {:ok, pack} <- codec.decode(payload, []) do
          {:ok, Enum.map(Pack.resolve(pack), fn {name, _t, r} -> {name, Record.value(r)} end)}
        end

      :error ->
        # A single-Resource Notify may legitimately be text/plain or opaque, in which case
        # there is one value and the path comes from the relation rather than the body.
        {:ok, [{nil, payload}]}
    end
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    {:ok, %{store: Store.new(), readings: []}}
  end

  @impl GenServer
  def handle_call(:notify_pid, _from, state), do: {:reply, self(), state}
  def handle_call(:list, _from, state), do: {:reply, Store.list(state.store), state}
  def handle_call(:readings, _from, state), do: {:reply, state.readings, state}
  def handle_call(:clear_readings, _from, state), do: {:reply, :ok, %{state | readings: []}}

  def handle_call({:put, handle, observation}, _from, state) do
    Logger.info(
      "OBSERVE registered id=#{observation.registration_id} " <>
        "paths=#{Enum.map_join(observation.paths, ",", &Path.format/1)}"
    )

    {:reply, :ok, %{state | store: Store.put(state.store, handle, observation)}}
  end

  def handle_call({:fetch, handle}, _from, state) do
    {:reply, Store.fetch(state.store, handle), state}
  end

  def handle_call({:forget, handle}, _from, state) do
    {:reply, :ok, %{state | store: Store.delete(state.store, handle)}}
  end

  def handle_call({:forget_registration, registration_id}, _from, state) do
    dropped = length(Store.handles_for_registration(state.store, registration_id))

    if dropped > 0 do
      Logger.info("OBSERVE dropped #{dropped} relation(s) with registration #{registration_id}")
    end

    {:reply, :ok, %{state | store: Store.delete_by_registration(state.store, registration_id)}}
  end

  def handle_call({:handles_for_path, path, opts}, _from, state) do
    {:reply, Store.handles_for_path(state.store, path, opts), state}
  end

  def handle_call({:handles_for_registration, registration_id}, _from, state) do
    {:reply, Store.handles_for_registration(state.store, registration_id), state}
  end

  def handle_call({:record_send, send, peer}, _from, state) do
    readings =
      case decode_readings(send.content_format, send.payload) do
        {:ok, decoded} -> decoded
        {:error, _undecodable} -> []
      end

    Logger.info("SEND from=#{Coap.format_peer(peer)} #{format_readings(readings)}")
    Events.publish(:send, peer: peer, readings: readings)

    {:reply, :ok, log_reading(state, %{source: :send, peer: peer, readings: readings})}
  end

  @impl GenServer
  def handle_info({:wick_coap_notification, handle, %Message{} = message}, state) do
    {:noreply, ingest_notification(handle, message, state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Notification ingest ────────────────────────────────────────────────────

  defp ingest_notification(handle, message, state) do
    with {:ok, observation} <- Store.fetch(state.store, handle),
         {:ok, wire} <- Coap.to_response_wire(message),
         {:ok, %Uplink.Notify{} = notify} <- Uplink.from_wire(wire) do
      apply_notification(handle, observation, notify, state)
    else
      :error ->
        # A notification for a relation we have already cancelled. Expected, not an error:
        # a Cancel-Observe and an in-flight Notify can cross on the wire.
        Logger.debug("NOTIFY for unknown handle #{inspect(handle)} — ignored")
        state

      {:error, error} ->
        Logger.warning("NOTIFY could not be decoded: #{inspect(error)}")
        state
    end
  end

  defp apply_notification(handle, observation, notify, state) do
    readings =
      case decode_readings(notify.content_format, notify.payload) do
        {:ok, decoded} -> label(decoded, observation)
        {:error, _undecodable} -> []
      end

    now = System.monotonic_time(:millisecond)
    value = single_value(readings)

    case Observation.accept_seq(observation, notify.observe_seq, now: now, value: value) do
      {:ok, updated} ->
        Logger.info(
          "NOTIFY id=#{observation.registration_id} seq=#{notify.observe_seq} " <>
            format_readings(readings)
        )

        Events.publish(:notify,
          registration_id: observation.registration_id,
          observe_seq: notify.observe_seq,
          readings: readings
        )

        state
        |> Map.put(:store, Store.put(state.store, handle, updated))
        |> log_reading(%{
          source: :notify,
          registration_id: observation.registration_id,
          observe_seq: notify.observe_seq,
          readings: readings
        })

      :stale ->
        Logger.debug("NOTIFY seq=#{notify.observe_seq} arrived out of order — discarded")
        state
    end
  end

  # A single-path Notify in a non-SenML format has no name in the body; take the path from
  # the relation, which is exactly what the relation is for.
  defp label([{nil, value}], %Observation{paths: [path]}), do: [{Path.format(path), value}]
  defp label(readings, _observation), do: readings

  # `last_value` feeds `Wick.Attributes.should_notify?/3`, which compares a *single* value against
  # a threshold. A Notify covering an Object Instance carries several Resources, and nominating
  # one of them — the first, say — would attribute a reading to the wrong path. Better to record
  # no single value than a misleading one; the full set is in the reading log either way.
  defp single_value([{_path, value}]), do: value
  defp single_value(_several_or_none), do: nil

  defp log_reading(state, entry) do
    entry = Map.put(entry, :at, System.monotonic_time(:millisecond))
    %{state | readings: [entry | state.readings]}
  end

  defp format_readings([]), do: "(no decodable readings)"

  defp format_readings(readings) do
    Enum.map_join(readings, " ", fn {path, value} -> "#{path}=#{inspect(value)}" end)
  end

  @doc """
  Build an `Wick.Observation` for a relation the server has just established.

  Carries the notification attributes the server wrote, if any, so that
  `Wick.Attributes.should_notify?/3` can be applied server-side to sanity-check a device that
  notifies more eagerly than it was told to.
  """
  @spec observation(String.t(), [Path.t()], keyword()) :: Observation.t()
  def observation(registration_id, paths, opts \\ []) do
    Observation.new(
      registration_id,
      paths,
      Keyword.put_new(opts, :attributes, Keyword.get(opts, :attributes, %Attributes{}))
    )
  end
end

defmodule WickDemoClient.Sensor do
  @moduledoc """
  Synthetic temperature readings for Object 3303, so the demo has a value that actually
  changes.

  Observe is meaningless against a static tree: the initial Notification arrives and nothing
  ever follows. This process makes the client behave like a real sensor — a reading every
  `:sensor_interval_ms`, drifting by a small random step — which is what makes the
  notification attributes (`pmin` / `pmax` / `gt` / `lt` / `st`) observable in practice.

  Each reading goes to `WickDemoClient.Device`, which decides whether a Notification is due.
  When it is, this process pushes it to every observer via
  `WickCoap.Endpoint.notify_observers/3`. Note the division of labour: the *decision* is
  Wick's (`Wick.Attributes.should_notify?/3`, applied in `Device`), the *dispatch* is
  WickCoap's, and all this process contributes is the clock.

  Set `:sensor_interval_ms` to `nil` to keep the sensor idle — the tests do, so that readings
  are driven explicitly by `tick/1` instead of by wall-clock time.
  """

  use GenServer

  require Logger

  alias Wick.Path
  alias WickCoap.Endpoint
  alias WickDemoClient.Coap
  alias WickDemoClient.Device
  alias WickDemoClient.Objects

  @name __MODULE__

  @default_interval_ms 10_000
  @default_drift 0.5

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Take one reading immediately, notifying observers if the attributes allow it.

  Returns `:notified` if a Notification went out, or `:quiet` if the notification attributes
  suppressed it. Useful from IEx and how the tests drive the sensor.
  """
  @spec tick(GenServer.server()) :: :notified | :quiet
  def tick(server \\ @name), do: GenServer.call(server, :tick)

  @doc "Force the next reading to a specific value, rather than drifting."
  @spec set(GenServer.server(), float()) :: :notified | :quiet
  def set(server \\ @name, reading), do: GenServer.call(server, {:set, reading})

  @doc "The last reading this process produced."
  @spec last_reading(GenServer.server()) :: float()
  def last_reading(server \\ @name), do: GenServer.call(server, :last_reading)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get_lazy(opts, :interval_ms, fn -> config(:sensor_interval_ms) end)

    state = %{
      device: Keyword.get(opts, :device, Device),
      endpoint: Keyword.get(opts, :endpoint),
      interval_ms: interval,
      reading: 20.0,
      drift: Keyword.get(opts, :drift, @default_drift)
    }

    if interval, do: Process.send_after(self(), :tick, interval)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:tick, _from, state) do
    {outcome, state} = take_reading(state, drift(state))
    {:reply, outcome, state}
  end

  def handle_call({:set, reading}, _from, state) do
    {outcome, state} = take_reading(state, reading)
    {:reply, outcome, state}
  end

  def handle_call(:last_reading, _from, state), do: {:reply, state.reading, state}

  @impl GenServer
  def handle_info(:tick, state) do
    {_outcome, state} = take_reading(state, drift(state))
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  defp take_reading(state, reading) do
    reading = Float.round(reading, 2)
    state = %{state | reading: reading}

    case Device.record_temperature(state.device, reading) do
      {:notify, _content_format, _payload} ->
        dispatched = push(state, Objects.temperature_path())

        Logger.info(
          "SENSOR #{Path.format(Objects.temperature_path())} = #{reading} → " <>
            "notified #{dispatched} observer(s)"
        )

        {:notified, state}

      :quiet ->
        {:quiet, state}
    end
  end

  # A change to a Resource is also a change to its Object Instance and to its Object, and LwM2M
  # lets a server Observe at any of those levels (§6.5). `WickCoap.Endpoint` keys relations by
  # exact URI path, so notifying only the Resource path leaves an Instance-level observer — the
  # natural thing for a server operator to ask for — silently receiving nothing.
  #
  # Each level gets its own payload, because an Instance-level Notify must carry the Instance's
  # Resources rather than just the one that moved. Levels with no observers cost one call that
  # returns 0.
  defp push(state, %Path{} = path) do
    case endpoint(state) do
      nil ->
        0

      endpoint ->
        path
        |> notify_targets()
        |> Enum.map(&notify_level(state, endpoint, &1))
        |> Enum.sum()
    end
  end

  defp notify_level(state, endpoint, %Path{} = target) do
    {content_format, payload} = Device.encode_paths(state.device, [target])

    Endpoint.notify_observers(
      endpoint,
      Path.to_segments(target),
      Coap.notification(content_format, payload)
    )
  end

  # The Resource itself, then each ancestor: /3303/0/5700 → /3303/0 → /3303.
  defp notify_targets(%Path{} = path) do
    [
      path,
      %Path{object_id: path.object_id, object_instance_id: path.object_instance_id},
      %Path{object_id: path.object_id}
    ]
    |> Enum.uniq()
  end

  # Resolved lazily rather than at init: the Endpoint is a sibling under the same supervisor,
  # and resolving it eagerly would couple this process's startup to the other's.
  defp endpoint(%{endpoint: nil}) do
    if Process.whereis(WickDemoClient.Endpoint), do: WickDemoClient.Endpoint.pid()
  end

  defp endpoint(%{endpoint: endpoint}), do: endpoint

  # A random walk, clamped to a plausible indoor range so a long-running demo does not drift
  # to absurd values.
  defp drift(state) do
    step = (:rand.uniform() - 0.5) * 2 * state.drift
    state.reading + step
  end

  defp config(key), do: Application.get_env(:wick_demo_client, key, @default_interval_ms)
end

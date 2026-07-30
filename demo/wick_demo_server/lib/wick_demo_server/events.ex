defmodule WickDemoServer.Events do
  @moduledoc """
  A tiny publish/subscribe bus for protocol events, so the web layer can watch LwM2M traffic
  without the protocol code knowing a web layer exists.

  `WickDemoServer.Store`, `.Observations`, and `.Handler` call `publish/2` on anything
  interesting. Whether anybody is listening is not their concern — with no subscribers
  `publish/2` is a no-op, which keeps the IEx-only path exactly as cheap as it was before the
  UI existed.

  Built on `Registry` in `:duplicate` mode rather than a GenServer: fan-out happens in the
  publishing process, there is no mailbox to become a bottleneck, and a subscriber that dies
  is cleaned up automatically. That last part matters — every browser tab holding an SSE
  connection is a subscriber, and tabs close without warning.

  ## Events

  Each event is a map with an `:event` tag, a monotonic `:at`, and event-specific fields.
  This is the shape the SSE stream serialises straight to JSON:

  | `:event`        | Fields                                            |
  |-----------------|---------------------------------------------------|
  | `:register`     | `:registration_id`, `:endpoint_name`, `:lifetime`, `:objects`, `:peer` |
  | `:update`       | `:registration_id`, `:endpoint_name`, `:lifetime` |
  | `:deregister`   | `:registration_id`, `:endpoint_name`              |
  | `:expire`       | `:registration_id`, `:endpoint_name`, `:lifetime` |
  | `:notify`       | `:registration_id`, `:observe_seq`, `:readings`    |
  | `:send`         | `:peer`, `:readings`                              |
  | `:observe`      | `:registration_id`, `:paths`                      |
  | `:cancel`       | `:registration_id`, `:paths`                      |
  | `:request`      | `:registration_id`, `:operation`, `:path`, `:status` |

  ## Examples

      iex> WickDemoServer.Events.subscribe()
      :ok
      iex> WickDemoServer.Events.publish(:register, endpoint_name: "device-1")
      :ok
      iex> receive do: ({:wick_demo_event, event} -> event.endpoint_name)
      "device-1"
  """

  @registry __MODULE__.Registry
  @topic :events

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry, partitions: 1)
  end

  @doc """
  Subscribe the calling process to every event.

  Events arrive as `{:wick_demo_event, event_map}`. Idempotent per process only in the sense
  that subscribing twice delivers twice — subscribe once.
  """
  @spec subscribe() :: :ok
  def subscribe do
    {:ok, _owner} = Registry.register(@registry, @topic, nil)
    :ok
  end

  @doc "Unsubscribe the calling process. Dying also unsubscribes, so this is rarely needed."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Registry.unregister(@registry, @topic)
    :ok
  end

  @doc "How many processes are currently listening. Useful for a health endpoint."
  @spec subscriber_count() :: non_neg_integer()
  def subscriber_count do
    if Process.whereis(@registry), do: Registry.count_match(@registry, @topic, nil), else: 0
  end

  @doc """
  Broadcast an event to every subscriber.

  `fields` is a keyword list or map merged into the event. A `:at` timestamp is added unless
  one is supplied. Safe to call before the registry starts — during application boot, or in a
  test that runs the protocol code without the supervision tree — in which case it does
  nothing rather than raising.
  """
  @spec publish(atom(), keyword() | map()) :: :ok
  def publish(event, fields \\ []) when is_atom(event) do
    if Process.whereis(@registry), do: dispatch(event, fields)
    :ok
  end

  defp dispatch(event, fields) do
    payload =
      fields
      |> Map.new()
      |> Map.put(:event, event)
      |> Map.put_new_lazy(:at, fn -> System.monotonic_time(:millisecond) end)

    Registry.dispatch(@registry, @topic, fn subscribers ->
      Enum.each(subscribers, fn {pid, _value} -> send(pid, {:wick_demo_event, payload}) end)
    end)
  end
end

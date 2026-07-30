defmodule WickDemoServer.Store do
  @moduledoc """
  GenServer wrapping `Wick.Registration.Store` for the demo server.

  Two responsibilities the pure store can't take on:

  1. **Serialised access** — `Wick.Registration.Server.handle/2` reads and writes the
     store as a single transaction. This process owns the store struct so concurrent
     CoAP exchanges interleave safely.
  2. **Lifetime reaping** — LwM2M registrations carry a `lifetime` (seconds). If the
     device fails to Update before it expires, the record must be removed. A periodic
     sweep here checks `updated_at + lifetime*1000` against the wall clock.

  The reaper interval comes from `config :wick_demo_server, :reaper_interval_ms` and
  defaults to `1_000`. A shorter interval reduces eviction latency at the cost of more
  scheduler activity.
  """

  use GenServer

  require Logger

  alias Wick.Registration.Record
  alias Wick.Registration.Server
  alias Wick.Registration.Store
  alias WickDemoServer.Events
  alias WickDemoServer.Observations

  @name __MODULE__

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || @name)
  end

  @spec pid() :: pid()
  def pid, do: Process.whereis(@name)

  @doc "List every active registration (sorted by `created_at`)."
  @spec list() :: [Record.t()]
  def list, do: GenServer.call(@name, :list)

  @doc """
  Run a registration request through `Wick.Registration.Server.handle/2` against the
  shared store. Returns the `%Server.Response{}` so the handler can shape the CoAP
  reply.
  """
  @spec handle_request(Server.request()) :: Server.Response.t()
  def handle_request(parsed_request), do: GenServer.call(@name, {:handle, parsed_request})

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    reaper_interval =
      Keyword.get(opts, :reaper_interval_ms) ||
        Application.get_env(:wick_demo_server, :reaper_interval_ms, 1_000)

    schedule_sweep(reaper_interval)

    {:ok,
     %{
       store: Store.new(),
       reaper_interval: reaper_interval
     }}
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    records = state.store |> Store.list() |> Enum.sort_by(& &1.created_at)
    {:reply, records, state}
  end

  def handle_call({:handle, parsed_request}, _from, state) do
    {response, updated_store} = Server.handle(parsed_request, state.store)

    # A Deregister takes the device's observations with it (§6.2): the relations are scoped to
    # the registration, and holding them would leave the server correlating notifications
    # against a device that has gone.
    if deregister?(parsed_request, response) do
      forget_observations(location_of(parsed_request))
    end

    publish_registration_event(parsed_request, response, updated_store)

    {:reply, response, %{state | store: updated_store}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    {store, expired} = sweep_expired(state.store, now)

    Enum.each(expired, fn record ->
      Logger.info(
        "WickDemoServer.Store: reaped #{record.endpoint_name} " <>
          "(#{record.location_id}) — lifetime #{record.lifetime}s elapsed"
      )

      forget_observations(record.location_id)

      Events.publish(:expire,
        registration_id: record.location_id,
        endpoint_name: record.endpoint_name,
        lifetime: record.lifetime
      )
    end)

    schedule_sweep(state.reaper_interval)
    {:noreply, %{state | store: store}}
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp deregister?(%{method: :delete, path: ["rd", _id]}, %Server.Response{code: :deleted}),
    do: true

  defp deregister?(_request, _response), do: false

  # ── Event publishing ───────────────────────────────────────────────────────

  # Emitted for the web UI. `Events.publish/2` is a no-op with no subscribers, so the IEx-only
  # path costs nothing.
  defp publish_registration_event(
         %{method: :post, path: ["rd"]},
         %Server.Response{code: :created, location_path: ["rd", id]},
         store
       ) do
    case Store.fetch(store, id) do
      {:ok, record} ->
        Events.publish(:register,
          registration_id: id,
          endpoint_name: record.endpoint_name,
          lifetime: record.lifetime,
          objects: record.objects,
          peer: record.peer
        )

      :error ->
        :ok
    end
  end

  defp publish_registration_event(
         %{method: :post, path: ["rd", id]},
         %Server.Response{code: :changed},
         store
       ) do
    case Store.fetch(store, id) do
      {:ok, record} ->
        Events.publish(:update,
          registration_id: id,
          endpoint_name: record.endpoint_name,
          lifetime: record.lifetime
        )

      :error ->
        :ok
    end
  end

  defp publish_registration_event(
         %{method: :delete, path: ["rd", id]},
         %Server.Response{code: :deleted},
         _store
       ) do
    Events.publish(:deregister, registration_id: id)
  end

  defp publish_registration_event(_request, _response, _store), do: :ok

  defp location_of(%{path: ["rd", id]}), do: id
  defp location_of(_request), do: nil

  # Guarded on the process being alive: the Store can outlive Observations during shutdown,
  # and a registration expiring is not a reason to crash the reaper.
  defp forget_observations(nil), do: :ok

  defp forget_observations(location_id) do
    if Process.whereis(Observations) do
      Observations.forget_registration(Observations, location_id)
    end

    :ok
  end

  defp sweep_expired(%Store{} = store, now) do
    Enum.reduce(Store.list(store), {store, []}, fn record, {acc_store, acc_expired} ->
      if expired?(record, now) do
        {Store.delete(acc_store, record.location_id), [record | acc_expired]}
      else
        {acc_store, acc_expired}
      end
    end)
  end

  defp expired?(%Record{lifetime: lifetime, updated_at: updated_at}, now) do
    now - updated_at > lifetime * 1_000
  end
end

defmodule WickDemoClient.Registrar do
  @moduledoc """
  Registration lifecycle for the demo client.

  Drives the LwM2M client side of the Registration interface:

      :idle  ──register/0──▶  :registered  ──update/0──▶  :registered
                                   │                          │
                                   └────────deregister/0──────┘ ▶ :idle

  After a successful Register, the Registrar schedules a self-message to fire an
  Update at `lifetime * 0.8 seconds` later — early enough to survive jitter and
  server-side reaper sweeps. Successive Updates re-arm the same timer. A failed
  Register or Update logs the error and retries after a short back-off.

  The Registrar owns the location ID returned in the `Location-Path` of the
  `2.01 Created` response. Deregister takes that ID and emits the `DELETE /rd/<id>`.

  ## Concurrency

  All state lives in this single GenServer. The actual CoAP work happens via the
  endpoint passed in at start. The endpoint can outlive this process (and vice versa);
  on shutdown we make a best-effort Deregister but do not block on the response.

  ## Configuration

  Reads runtime config from `:wick_demo_client`:

  * `:server_host` — `{a, b, c, d}` tuple
  * `:server_port` — integer
  * `:endpoint_name` — string
  * `:lifetime` — seconds
  * `:autostart` — boolean
  """

  use GenServer

  require Logger

  alias Wick.Registration
  alias Wick.Registration.Deregister
  alias Wick.Registration.Register
  alias Wick.Registration.Update
  alias Wick.Wire
  alias WickCoap.Endpoint
  alias WickCoap.Message
  alias WickDemoClient.Coap
  alias WickDemoClient.Device

  @name __MODULE__

  # Send Update at `lifetime * @update_lead` seconds. 0.8 = update at 80% of the
  # lifetime, leaves 20% of headroom before reaper-side eviction.
  @update_lead 0.8

  # Back-off when Register/Update fails (ms). Keep short for the demo — production
  # would do exponential back-off with jitter.
  @retry_after_ms 5_000

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Trigger a fresh Register synchronously. Returns `:ok` or `{:error, term}`."
  @spec register() :: :ok | {:error, term()}
  def register, do: GenServer.call(@name, :register, 10_000)

  @doc "Trigger an Update synchronously. Returns `:ok` or `{:error, term}`."
  @spec update() :: :ok | {:error, term()}
  def update, do: GenServer.call(@name, :update, 10_000)

  @doc "Tear down the registration. Returns `:ok` even if the server replies 4.04."
  @spec deregister() :: :ok
  def deregister, do: GenServer.call(@name, :deregister, 10_000)

  @doc "Inspect the current registration state — `{:registered, location_id}` or `:idle`."
  @spec status() :: :idle | {:registered, String.t()}
  def status, do: GenServer.call(@name, :status)

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # The Endpoint child is started before this one (rest_for_one), so its pid is
    # already available via the registered name. Tests can override with `:endpoint`.
    endpoint = Keyword.get(opts, :endpoint) || WickDemoClient.Endpoint.pid()

    state = %{
      endpoint: endpoint,
      device: Keyword.get(opts, :device, Device),
      endpoint_name: endpoint_name(),
      lifetime: lifetime(),
      status: :idle,
      update_timer: nil
    }

    if Application.get_env(:wick_demo_client, :autostart, true) do
      send(self(), :auto_register)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:register, _from, state), do: do_register(state)

  def handle_call(:update, _from, state) do
    case state.status do
      {:registered, _id} ->
        do_update(state)

      :idle ->
        {:reply, {:error, :not_registered}, state}
    end
  end

  def handle_call(:deregister, _from, state) do
    state = cancel_update_timer(state)

    state =
      case state.status do
        :idle ->
          state

        {:registered, location_id} ->
          send_deregister(state, location_id)
          %{state | status: :idle}
      end

    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl GenServer
  def handle_info(:auto_register, state) do
    {_, _, state} = do_register(state)
    {:noreply, state}
  end

  def handle_info(:scheduled_update, state) do
    case state.status do
      {:registered, _id} ->
        {_, _, state} = do_update(state)
        {:noreply, state}

      :idle ->
        # Stale timer fired after a deregister — ignore.
        {:noreply, state}
    end
  end

  def handle_info(:retry, state) do
    case state.status do
      :idle ->
        {_, _, state} = do_register(state)
        {:noreply, state}

      {:registered, _} ->
        {_, _, state} = do_update(state)
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Best-effort goodbye. We can't block here — the endpoint may already be down — so
    # we ignore errors. A production client would prefer a graceful shutdown step ahead
    # of the supervisor tearing us down.
    case state.status do
      {:registered, location_id} -> send_deregister(state, location_id)
      :idle -> :ok
    end
  end

  # ── Internal — operations ──────────────────────────────────────────────────

  defp do_register(state) do
    # Links come from the live Object tree rather than a hard-coded list, so anything a
    # Bootstrap-Write or a Create added is advertised on the next Register.
    request =
      Registration.to_wire(%Register{
        endpoint_name: state.endpoint_name,
        lifetime: state.lifetime,
        objects: Device.links(state.device)
      })

    case send_request(state.endpoint, current_server_peer(), request) do
      {:ok, %Message{code: :created} = response} ->
        location_id = extract_location_id(response)

        Logger.info(
          "REGISTER ok ep=#{state.endpoint_name} → id=#{location_id} (lifetime=#{state.lifetime}s)"
        )

        state =
          state
          |> Map.put(:status, {:registered, location_id})
          |> schedule_next_update()

        {:reply, :ok, state}

      {:ok, %Message{code: code, payload: payload}} ->
        Logger.warning("REGISTER server returned #{code}: #{inspect(payload)}")
        {:reply, {:error, {:server_response, code}}, schedule_retry(state)}

      {:error, reason} ->
        Logger.warning("REGISTER transport error: #{inspect(reason)}")
        {:reply, {:error, reason}, schedule_retry(state)}
    end
  end

  defp do_update(state) do
    {:registered, location_id} = state.status

    request =
      Registration.to_wire(%Update{
        location: location_id,
        lifetime: state.lifetime
      })

    case send_request(state.endpoint, current_server_peer(), request) do
      {:ok, %Message{code: :changed}} ->
        Logger.info("UPDATE ok id=#{location_id}")
        {:reply, :ok, schedule_next_update(state)}

      {:ok, %Message{code: :not_found}} ->
        # Server forgot us (probably reaped). Re-register from scratch.
        Logger.info("UPDATE id=#{location_id} got 4.04 — re-registering")
        do_register(%{state | status: :idle})

      {:ok, %Message{code: code}} ->
        Logger.warning("UPDATE id=#{location_id} server returned #{code}")
        {:reply, {:error, {:server_response, code}}, schedule_retry(state)}

      {:error, reason} ->
        Logger.warning("UPDATE id=#{location_id} transport error: #{inspect(reason)}")
        {:reply, {:error, reason}, schedule_retry(state)}
    end
  end

  defp send_deregister(state, location_id) do
    request = Registration.to_wire(%Deregister{location: location_id})

    case send_request(state.endpoint, current_server_peer(), request) do
      {:ok, %Message{code: code}} ->
        Logger.info("DEREGISTER id=#{location_id} server response=#{code}")
        :ok

      {:error, reason} ->
        Logger.warning("DEREGISTER id=#{location_id} transport error: #{inspect(reason)}")
        :ok
    end
  end

  # ── Internal — CoAP plumbing ───────────────────────────────────────────────

  defp send_request(endpoint, peer, %Wire{} = wire) do
    Endpoint.request(endpoint, peer, Coap.to_message(wire), timeout: 5_000)
  end

  defp extract_location_id(%Message{options: options}) do
    options
    |> Enum.filter(&(&1.number == Wire.location_path_option()))
    |> Enum.map(& &1.value)
    |> case do
      # `Location-Path: /rd/<id>` → strip the leading "rd" and take the id segment.
      ["rd", id] -> id
      [_, id | _] -> id
      [id] -> id
      _ -> ""
    end
  end

  # ── Internal — timers ──────────────────────────────────────────────────────

  defp schedule_next_update(state) do
    state = cancel_update_timer(state)
    delay = trunc(state.lifetime * 1_000 * @update_lead)
    timer = Process.send_after(self(), :scheduled_update, delay)
    %{state | update_timer: timer}
  end

  defp schedule_retry(state) do
    state = cancel_update_timer(state)
    timer = Process.send_after(self(), :retry, @retry_after_ms)
    %{state | update_timer: timer}
  end

  defp cancel_update_timer(%{update_timer: nil} = state), do: state

  defp cancel_update_timer(%{update_timer: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | update_timer: nil}
  end

  # ── Internal — config plumbing ─────────────────────────────────────────────

  defp current_server_peer do
    host = Application.get_env(:wick_demo_client, :server_host, {127, 0, 0, 1})
    port = Application.get_env(:wick_demo_client, :server_port, 5683)
    {host, port}
  end

  defp endpoint_name,
    do: Application.get_env(:wick_demo_client, :endpoint_name, "wick-demo-client")

  defp lifetime, do: Application.get_env(:wick_demo_client, :lifetime, 60)
end

defmodule WickCoap.Retransmit do
  @moduledoc """
  CoAP confirmable-message retransmission state machine.

  Per [RFC 7252 §4.2 / §4.8](https://www.rfc-editor.org/rfc/rfc7252#section-4.8): a CON
  message that doesn't get an ACK within `ACK_TIMEOUT` is retransmitted. The interval
  doubles each retry (`ACK_RANDOM_FACTOR` jitters the initial timeout). After
  `MAX_RETRANSMIT` retries with no ACK, the exchange is aborted.

  Default constants from RFC 7252 §4.8:

  | Constant            | Default | Notes |
  |---------------------|--------:|-------|
  | `ACK_TIMEOUT`       | 2.0 s   | Initial timeout |
  | `ACK_RANDOM_FACTOR` | 1.5     | Initial timeout is uniformly random in `[ACK_TIMEOUT, ACK_TIMEOUT * ACK_RANDOM_FACTOR]` |
  | `MAX_RETRANSMIT`    | 4       | Total of 5 transmits before abort (initial + 4 retries) |

  This module is **pure** — it does not schedule timers or perform IO. The Endpoint
  GenServer that owns sockets calls `next_step/2` with the current monotonic time and
  decides what to do based on the returned `{:retransmit, …}` / `{:expire, …}` / `:wait`
  outcome.

  ## Lifecycle

      iex> r = WickCoap.Retransmit.new(now: 0)
      iex> WickCoap.Retransmit.next_step(r, 0)
      :wait

      iex> # Time passes; retransmit due
      iex> r = WickCoap.Retransmit.new(now: 0, ack_timeout: 1000, ack_random_factor: 1.0)
      iex> {:retransmit, r2} = WickCoap.Retransmit.next_step(r, 1000)
      iex> r2.attempts
      2

      iex> # Exhaust retransmits
      iex> r = WickCoap.Retransmit.new(now: 0, ack_timeout: 1000, ack_random_factor: 1.0, max_retransmit: 1)
      iex> {:retransmit, r} = WickCoap.Retransmit.next_step(r, 1000)
      iex> {:expire, _} = WickCoap.Retransmit.next_step(r, 100_000)
  """

  @typedoc """
  The retransmission state for a single in-flight CON message.

  All time fields are in **milliseconds** on the same monotonic clock (the caller chooses
  which — typically `System.monotonic_time(:millisecond)`).
  """
  @type t :: %__MODULE__{
          attempts: pos_integer(),
          next_at: integer(),
          interval: pos_integer(),
          max_retransmit: pos_integer()
        }

  @enforce_keys [:attempts, :next_at, :interval, :max_retransmit]
  defstruct [:attempts, :next_at, :interval, :max_retransmit]

  # RFC 7252 §4.8 default values, all in milliseconds.
  @default_ack_timeout 2_000
  @default_random_factor 1.5
  @default_max_retransmit 4

  @doc """
  Build the initial retransmission state for a freshly-sent CON message.

  ## Options

  * `:now` — current monotonic time in milliseconds. Required.
  * `:ack_timeout` — `ACK_TIMEOUT`, default `2000`.
  * `:ack_random_factor` — `ACK_RANDOM_FACTOR`, default `1.5`. The initial interval is
    drawn uniformly from `[ack_timeout, ack_timeout * ack_random_factor]`.
  * `:max_retransmit` — `MAX_RETRANSMIT`, default `4`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    now = Keyword.fetch!(opts, :now)
    base = Keyword.get(opts, :ack_timeout, @default_ack_timeout)
    random_factor = Keyword.get(opts, :ack_random_factor, @default_random_factor)
    max_retransmit = Keyword.get(opts, :max_retransmit, @default_max_retransmit)

    initial = jittered_initial(base, random_factor)

    %__MODULE__{
      attempts: 1,
      next_at: now + initial,
      interval: initial,
      max_retransmit: max_retransmit
    }
  end

  @doc """
  Decide what to do for an in-flight CON given the current monotonic time.

  Returns:

  * `:wait` — retransmit deadline not yet reached
  * `{:retransmit, t/0}` — caller should resend the CON; the returned struct holds the
    next deadline and incremented attempt count
  * `{:expire, t/0}` — `MAX_RETRANSMIT` reached without an ACK; caller should abandon
  """
  @spec next_step(t(), integer()) :: :wait | {:retransmit, t()} | {:expire, t()}
  def next_step(%__MODULE__{} = state, now) when is_integer(now) do
    cond do
      now < state.next_at ->
        :wait

      state.attempts > state.max_retransmit ->
        {:expire, state}

      true ->
        new_interval = state.interval * 2

        next =
          %__MODULE__{
            state
            | attempts: state.attempts + 1,
              next_at: now + new_interval,
              interval: new_interval
          }

        {:retransmit, next}
    end
  end

  defp jittered_initial(base, factor) when factor >= 1.0 do
    span = round(base * factor) - base
    base + :rand.uniform(max(span, 1)) - 1
  end
end

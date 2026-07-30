defmodule WickCoap.Dedup do
  @moduledoc """
  Server-side CoAP deduplication window.

  Per [RFC 7252 §4.5](https://www.rfc-editor.org/rfc/rfc7252#section-4.5) the recipient of
  a CON message must remember its Message ID for at least `EXCHANGE_LIFETIME` (default
  ~247 s) so that retransmissions can be detected and answered with the cached ACK
  rather than re-processed.

  Wick's deduplicator is **per-peer** — duplicate detection is meaningless across peers
  because Message IDs are scoped to a `(source, destination)` pair. The Endpoint
  GenServer holds one of these per active peer.

  This module is pure — the caller advances time. Insertion is `O(log n)`; lookup is
  `O(log n)`; eviction prunes any entries past the lifetime in one sweep.

  ## Examples

      iex> dedup = WickCoap.Dedup.new()
      iex> {:fresh, dedup} = WickCoap.Dedup.observe(dedup, 1234, _now = 0)
      iex> {:duplicate, _} = WickCoap.Dedup.observe(dedup, 1234, 1000)
  """

  @typedoc """
  The deduplication window. Tracks recently-seen Message IDs along with the time they
  were first observed so the implementation can prune entries past `EXCHANGE_LIFETIME`.
  """
  @type t :: %__MODULE__{
          # Map<message_id, first_seen_ms> — small enough that a plain Map outperforms
          # any tree-based structure for our typical window sizes (<1000 entries).
          window: %{optional(0..0xFFFF) => integer()},
          lifetime_ms: pos_integer()
        }

  @enforce_keys [:window, :lifetime_ms]
  defstruct [:window, :lifetime_ms]

  # RFC 7252 §4.8.2: EXCHANGE_LIFETIME = 247 s by default.
  @default_lifetime_ms 247_000

  @doc """
  Build a new (empty) deduplicator.

  ## Options

  * `:lifetime_ms` — how long to remember each Message ID. Default 247 000 ms (RFC 7252's
    `EXCHANGE_LIFETIME`).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      window: %{},
      lifetime_ms: Keyword.get(opts, :lifetime_ms, @default_lifetime_ms)
    }
  end

  @doc """
  Record an inbound Message ID and tell the caller whether it's been seen before.

  Returns:

  * `{:fresh, t/0}` — Message ID has not been seen recently; caller processes the message
    normally
  * `{:duplicate, t/0}` — Message ID was seen within the lifetime window; caller should
    re-emit the cached ACK without re-processing the request
  """
  @spec observe(t(), 0..0xFFFF, integer()) :: {:fresh | :duplicate, t()}
  def observe(%__MODULE__{} = dedup, message_id, now)
      when is_integer(message_id) and message_id in 0..0xFFFF and is_integer(now) do
    dedup = sweep(dedup, now)

    case Map.fetch(dedup.window, message_id) do
      {:ok, _} -> {:duplicate, dedup}
      :error -> {:fresh, %__MODULE__{dedup | window: Map.put(dedup.window, message_id, now)}}
    end
  end

  @doc "Number of Message IDs currently being remembered."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{window: window}), do: map_size(window)

  defp sweep(%__MODULE__{window: window, lifetime_ms: lifetime} = dedup, now) do
    cutoff = now - lifetime
    pruned = :maps.filter(fn _mid, t -> t > cutoff end, window)
    %__MODULE__{dedup | window: pruned}
  end
end

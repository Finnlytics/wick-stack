defmodule Wick.Observation do
  @moduledoc """
  One Observe relation, as the server side of it needs to be remembered.

  A Notification carries almost nothing: a payload, a Content-Format, and an RFC 7641
  sequence number. It does **not** say what it is a notification *of*. The binding between
  "this token from this device" and "the path(s) I asked to observe" lives here — without
  it an inbound Notify is uninterpretable.

  Pure data. The server owns the lifetime: create a record when the Observe succeeds, look
  it up on each Notification, drop it on Cancel-Observe or when the registration expires.
  `Wick.Observation.Store` is a minimal in-memory holder.

  ## Single vs Composite

  `paths` is always a list. A plain `Wick.Request.Observe` yields a one-element list; an
  `ObserveComposite` yields one entry per requested path. `composite?/1` distinguishes
  them, which matters when decoding: a single-path Notify may carry a bare value in any
  Content-Format, while a Composite Notify is always a SenML Pack whose record names give
  the paths.

  ## Sequence numbers

  `last_seq` holds the most recent accepted sequence number. `accept_seq/2` applies the
  [RFC 7641 §3.4](https://www.rfc-editor.org/rfc/rfc7641#section-3.4) reordering test so a
  Notification that arrives late — UDP gives no ordering guarantee — is rejected rather
  than overwriting fresher data. Note that `WickCoap.Endpoint` already filters reordered
  notifications for observations it initiated; this is the same rule available to consumers
  that track relations themselves, or that receive notifications through another path.

  Time fields are plain integers in monotonic milliseconds, per ADR 0003.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3303/0/5700")
      iex> obs = Wick.Observation.new("r0", [path], token: <<1, 2>>, now: 1_000)
      iex> {obs.registration_id, Wick.Observation.composite?(obs)}
      {"r0", false}
  """

  alias Wick.Attributes
  alias Wick.Path

  # RFC 7641 §3.4: values within 2^23 of each other are "recent"; beyond that the counter
  # is assumed to have wrapped.
  @seq_space 0x1000000
  @seq_half 0x800000

  @typedoc "A stored Observe relation."
  @type t :: %__MODULE__{
          registration_id: String.t(),
          paths: [Path.t()],
          token: binary() | nil,
          content_format: non_neg_integer() | nil,
          attributes: Attributes.t(),
          last_seq: non_neg_integer() | nil,
          last_value: term(),
          created_at: integer(),
          notified_at: integer() | nil
        }

  @enforce_keys [:registration_id, :paths, :created_at]
  defstruct [
    :registration_id,
    :paths,
    :token,
    :content_format,
    :last_seq,
    :last_value,
    :created_at,
    :notified_at,
    attributes: %Attributes{}
  ]

  @doc """
  Build an observation for `registration_id` covering `paths`.

  ## Options

  * `:token` — the CoAP token the relation is keyed by, if the transport exposes one.
  * `:content_format` — the Content-Format notifications are expected in.
  * `:attributes` — the `Wick.Attributes` in force, if the server has written any.
  * `:now` — creation timestamp in monotonic milliseconds. Defaults to
    `System.monotonic_time(:millisecond)`.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0/9")
      iex> obs = Wick.Observation.new("r0", [path], now: 500, content_format: 112)
      iex> {obs.created_at, obs.content_format, obs.notified_at}
      {500, 112, nil}
  """
  @spec new(String.t(), [Path.t()], keyword()) :: t()
  def new(registration_id, paths, opts \\ [])
      when is_binary(registration_id) and is_list(paths) do
    %__MODULE__{
      registration_id: registration_id,
      paths: paths,
      token: Keyword.get(opts, :token),
      content_format: Keyword.get(opts, :content_format),
      attributes: Keyword.get(opts, :attributes, %Attributes{}),
      created_at: Keyword.get_lazy(opts, :now, &monotonic_ms/0)
    }
  end

  @doc """
  True when the relation covers more than one path, i.e. it came from an
  Observe-Composite.

  ## Examples

      iex> {:ok, p1} = Wick.Path.parse("/3/0/9")
      iex> {:ok, p2} = Wick.Path.parse("/6/0/0")
      iex> Wick.Observation.composite?(Wick.Observation.new("r0", [p1, p2], now: 0))
      true
  """
  @spec composite?(t()) :: boolean()
  def composite?(%__MODULE__{paths: [_single]}), do: false
  def composite?(%__MODULE__{}), do: true

  @doc """
  Apply the RFC 7641 §3.4 reordering test to an arriving sequence number.

  Returns `{:ok, observation}` with `last_seq` and `notified_at` advanced when the
  notification is newer, or `:stale` when it should be discarded. The first notification
  on a relation is always accepted.

  `opts` accepts `:now` (monotonic milliseconds, defaults to the current time) and
  `:value`, the decoded value to remember for `Wick.Attributes.should_notify?/3`.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0/9")
      iex> obs = Wick.Observation.new("r0", [path], now: 0)
      iex> {:ok, obs} = Wick.Observation.accept_seq(obs, 10, now: 1_000, value: 22)
      iex> {obs.last_seq, obs.last_value, obs.notified_at}
      {10, 22, 1000}
      iex> Wick.Observation.accept_seq(obs, 9, now: 2_000)
      :stale
      iex> {:ok, obs} = Wick.Observation.accept_seq(obs, 11, now: 2_000)
      iex> obs.last_seq
      11
  """
  @spec accept_seq(t(), non_neg_integer(), keyword()) :: {:ok, t()} | :stale
  def accept_seq(%__MODULE__{} = observation, seq, opts \\ [])
      when is_integer(seq) and seq >= 0 do
    if newer?(seq, observation.last_seq) do
      {:ok,
       %{
         observation
         | last_seq: seq,
           last_value: Keyword.get(opts, :value, observation.last_value),
           notified_at: Keyword.get_lazy(opts, :now, &monotonic_ms/0)
       }}
    else
      :stale
    end
  end

  @doc """
  True when `arrived` is newer than `seen` under the RFC 7641 §3.4 comparison. A `nil`
  `seen` (no notification yet) makes anything newer.

  ## Examples

      iex> Wick.Observation.newer?(1, nil)
      true

      iex> Wick.Observation.newer?(2, 1)
      true

      iex> Wick.Observation.newer?(1, 2)
      false

      iex> Wick.Observation.newer?(0, 16_777_215)
      true
  """
  @spec newer?(non_neg_integer(), non_neg_integer() | nil) :: boolean()
  def newer?(_arrived, nil), do: true

  def newer?(arrived, seen) when is_integer(arrived) and is_integer(seen) do
    (seen < arrived and arrived - seen < @seq_half) or
      (arrived < seen and seen - arrived > @seq_half)
  end

  @doc """
  The observation state `Wick.Attributes.should_notify?/3` expects, derived from this
  relation at time `now`.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0/9")
      iex> obs = Wick.Observation.new("r0", [path], now: 0)
      iex> Wick.Observation.state(obs, 5_000)
      %{last_value: nil, since_last_ms: nil}

      iex> {:ok, path} = Wick.Path.parse("/3/0/9")
      iex> obs = Wick.Observation.new("r0", [path], now: 0)
      iex> {:ok, obs} = Wick.Observation.accept_seq(obs, 0, now: 1_000, value: 22)
      iex> Wick.Observation.state(obs, 6_000)
      %{last_value: 22, since_last_ms: 5_000}
  """
  @spec state(t(), integer()) :: Attributes.observation_state()
  def state(%__MODULE__{notified_at: nil} = observation, _now) do
    %{last_value: observation.last_value, since_last_ms: nil}
  end

  def state(%__MODULE__{} = observation, now) do
    %{last_value: observation.last_value, since_last_ms: now - observation.notified_at}
  end

  @doc """
  The sequence number to put on the next outbound Notification, wrapping at 2^24.

  A client emitting notifications owns the counter; this advances it.

  ## Examples

      iex> Wick.Observation.next_seq(nil)
      0

      iex> Wick.Observation.next_seq(0)
      1

      iex> Wick.Observation.next_seq(16_777_215)
      0
  """
  @spec next_seq(non_neg_integer() | nil) :: non_neg_integer()
  def next_seq(nil), do: 0
  def next_seq(seq) when is_integer(seq) and seq >= 0, do: rem(seq + 1, @seq_space)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end

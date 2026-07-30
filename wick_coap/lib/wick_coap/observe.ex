defmodule WickCoap.Observe do
  @moduledoc """
  Helpers for the [RFC 7641](https://www.rfc-editor.org/rfc/rfc7641) Observe option.

  ## The option

  CoAP option number 6, type uint, repeatable: no.

  * **In requests** — value `0` registers the relation, value `1` deregisters it.
  * **In responses (notifications)** — value is a 24-bit sequence number used by the
    client to detect out-of-order delivery.

  ## Sequence numbers

  Per [RFC 7641 §3.4](https://www.rfc-editor.org/rfc/rfc7641#section-3.4), notification
  sequence numbers wrap modulo 2^24. The "newer than" comparison is asymmetric:

      V1 is newer than V2  iff
        (V1 < V2 and V2 - V1 > 2^23) or
        (V1 > V2 and V1 - V2 < 2^23)

  Wick's `newer?/2` (and `select_newer/2`) implement this exactly, with one extension:
  if the second argument is `nil` (no prior notification seen), any new value is newer.

  ## Examples

      iex> WickCoap.Observe.option_number()
      6

      iex> WickCoap.Observe.action(0)
      :register

      iex> WickCoap.Observe.action(1)
      :deregister

      iex> WickCoap.Observe.next_sequence(0)
      1

      iex> WickCoap.Observe.next_sequence(0xFFFFFF)
      0

      iex> WickCoap.Observe.newer?(_arrived = 5, _seen = 3)
      true

      iex> WickCoap.Observe.newer?(3, 5)
      false

      # Wrap-around: 0 is newer than 0xFFFFFF
      iex> WickCoap.Observe.newer?(0, 0xFFFFFF)
      true
  """

  alias WickCoap.Option

  @option_number 6
  @max_seq 0x1000000
  @half_max 0x800000

  @typedoc "Action requested by the Observe option in a request."
  @type action :: :register | :deregister

  @typedoc "A 24-bit notification sequence number."
  @type sequence :: 0..0xFFFFFF

  @doc "The CoAP option number for Observe."
  @spec option_number() :: 6
  def option_number, do: @option_number

  @doc """
  Interpret the unsigned-integer value of an Observe option in a *request* as either
  `:register` (0) or `:deregister` (1).
  """
  @spec action(non_neg_integer()) :: action() | nil
  def action(0), do: :register
  def action(1), do: :deregister
  def action(_), do: nil

  @doc "Return the next sequence number, wrapping at `2^24`."
  @spec next_sequence(sequence()) :: sequence()
  def next_sequence(seq) when seq in 0..0xFFFFFF, do: rem(seq + 1, @max_seq)

  @doc """
  True iff `arrived` represents a newer notification than `seen` (the last accepted
  sequence number) per RFC 7641 §3.4.

  `seen = nil` means no prior notification — any value is newer.
  """
  @spec newer?(sequence(), sequence() | nil) :: boolean()
  def newer?(_arrived, nil), do: true

  def newer?(arrived, seen) when arrived in 0..0xFFFFFF and seen in 0..0xFFFFFF do
    cond do
      arrived < seen and seen - arrived > @half_max -> true
      arrived > seen and arrived - seen < @half_max -> true
      true -> false
    end
  end

  @doc """
  Extract the Observe option from a message, returning either `{:ok, value}` (an unsigned
  integer 0..2^24-1) or `:not_present`.

  ## Examples

      iex> opts = [WickCoap.Option.from_uint(6, 5)]
      iex> WickCoap.Observe.extract(%WickCoap.Message{type: :ack, code: :content, message_id: 0, options: opts})
      {:ok, 5}

      iex> WickCoap.Observe.extract(%WickCoap.Message{type: :ack, code: :content, message_id: 0, options: []})
      :not_present
  """
  @spec extract(WickCoap.Message.t()) :: {:ok, non_neg_integer()} | :not_present
  def extract(%WickCoap.Message{options: options}) do
    case Enum.find(options, &(&1.number == @option_number)) do
      nil -> :not_present
      option -> {:ok, Option.value_as_uint(option)}
    end
  end

  @doc """
  Build a fresh Observe option carrying the given value.

  Use with `0` / `1` for request register/deregister, or with a sequence number for
  notification responses.
  """
  @spec option(non_neg_integer()) :: Option.t()
  def option(value) when is_integer(value) and value >= 0 do
    Option.from_uint(@option_number, value)
  end
end

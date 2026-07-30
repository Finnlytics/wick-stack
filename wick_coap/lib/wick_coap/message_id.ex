defmodule WickCoap.MessageId do
  @moduledoc """
  CoAP Message ID allocator.

  Per [RFC 7252 §4.2](https://www.rfc-editor.org/rfc/rfc7252#section-4.2) every CoAP
  message carries a 16-bit Message ID used for matching ACK/RST to the originating CON
  and for deduplicating retransmissions. The MID space is shared per `(source, destination)`
  endpoint pair — typically one allocator per peer.

  This module wraps a 16-bit counter. The initial value should be randomised — RFC 7252 §4.4
  recommends starting at a random point to avoid clashing with whatever any previous instance
  on the same endpoint emitted.

  ## Examples

      iex> alloc = WickCoap.MessageId.new(1234)
      iex> {mid, alloc} = WickCoap.MessageId.next(alloc)
      iex> mid
      1234
      iex> {mid, _} = WickCoap.MessageId.next(alloc)
      iex> mid
      1235

      iex> alloc = WickCoap.MessageId.new(0xFFFF)
      iex> {0xFFFF, alloc} = WickCoap.MessageId.next(alloc)
      iex> {0, _} = WickCoap.MessageId.next(alloc)
  """

  @typedoc "A Message ID allocator state."
  @type t :: %__MODULE__{counter: 0..0xFFFF}

  @enforce_keys [:counter]
  defstruct [:counter]

  @doc "Build a new allocator starting at the given Message ID."
  @spec new(0..0xFFFF) :: t()
  def new(initial \\ random()) when is_integer(initial) and initial in 0..0xFFFF do
    %__MODULE__{counter: initial}
  end

  @doc """
  Build a new allocator starting at a random Message ID, per RFC 7252 §4.4 guidance.
  """
  @spec random() :: 0..0xFFFF
  def random, do: :rand.uniform(0x10000) - 1

  @doc "Allocate the next Message ID. Wraps modulo 65536."
  @spec next(t()) :: {0..0xFFFF, t()}
  def next(%__MODULE__{counter: c}) do
    {c, %__MODULE__{counter: rem(c + 1, 0x10000)}}
  end
end

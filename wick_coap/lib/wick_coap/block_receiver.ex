defmodule WickCoap.BlockReceiver do
  @moduledoc """
  Inbound Block-wise transfer state machine.

  Receives a sequence of blocks and assembles them into a single payload. The receiver
  notes the SZX from the first block, validates that subsequent blocks share that SZX,
  and tolerates blocks arriving out of order.

  Returns `{:complete, payload}` when:

  1. A block with `more: false` has been received, **and**
  2. Every block from `0..final_num` is present.

  Returns `{:error, %WickCoap.Error{code: :inconsistent_block_size}}` if a later block
  has a different SZX than the first.

  ## Lifecycle

      iex> receiver = WickCoap.BlockReceiver.new()
      iex> b0 = %WickCoap.Block{num: 0, more: true, szx: 0}
      iex> {:more, receiver} = WickCoap.BlockReceiver.observe(receiver, b0, "0123456789ABCDEF")
      iex> b1 = %WickCoap.Block{num: 1, more: false, szx: 0}
      iex> {:complete, payload} = WickCoap.BlockReceiver.observe(receiver, b1, "tail")
      iex> payload
      "0123456789ABCDEFtail"
  """

  alias WickCoap.Block
  alias WickCoap.Error

  @typedoc "Inbound transfer state."
  @type t :: %__MODULE__{
          szx: 0..6 | nil,
          block_size: pos_integer() | nil,
          chunks: %{optional(non_neg_integer()) => binary()},
          final_num: non_neg_integer() | nil
        }

  defstruct szx: nil, block_size: nil, chunks: %{}, final_num: nil

  @doc "Build a fresh, empty receiver."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Record an inbound block. Returns:

  * `{:more, t/0}` — payload incomplete; caller continues to observe further blocks
  * `{:complete, binary()}` — final block plus all earlier blocks have arrived; payload
    assembled
  * `{:error, %WickCoap.Error{}}` — block size changed mid-transfer or chunk size doesn't
    match SZX (RFC 7959 §2.5 is strict about this)
  """
  @spec observe(t(), Block.t(), binary()) ::
          {:more, t()} | {:complete, binary()} | {:error, Error.t()}
  def observe(%__MODULE__{} = receiver, %Block{} = block, chunk) when is_binary(chunk) do
    expected_size = Block.size(block.szx)

    cond do
      receiver.szx != nil and receiver.szx != block.szx ->
        {:error,
         Error.new(
           :inconsistent_block_size,
           "block #{block.num} reported SZX #{block.szx}; transfer started with SZX #{receiver.szx}",
           expected_szx: receiver.szx,
           got_szx: block.szx
         )}

      block.more and byte_size(chunk) != expected_size ->
        {:error,
         Error.new(
           :inconsistent_block_size,
           "non-final block #{block.num} carried #{byte_size(chunk)} bytes, expected #{expected_size}",
           expected: expected_size,
           got: byte_size(chunk)
         )}

      true ->
        receiver = adopt_szx(receiver, block.szx, expected_size)
        receiver = put_chunk(receiver, block, chunk)

        if complete?(receiver) do
          {:complete, assemble(receiver)}
        else
          {:more, receiver}
        end
    end
  end

  @doc "True if every block needed for completion has arrived."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{final_num: nil}), do: false

  def complete?(%__MODULE__{final_num: final, chunks: chunks}) do
    map_size(chunks) == final + 1 and Enum.all?(0..final, &Map.has_key?(chunks, &1))
  end

  defp adopt_szx(%__MODULE__{szx: nil} = receiver, szx, block_size) do
    %{receiver | szx: szx, block_size: block_size}
  end

  defp adopt_szx(receiver, _szx, _size), do: receiver

  defp put_chunk(receiver, %Block{} = block, chunk) do
    chunks = Map.put(receiver.chunks, block.num, chunk)
    final_num = if block.more, do: receiver.final_num, else: block.num
    %{receiver | chunks: chunks, final_num: final_num}
  end

  defp assemble(%__MODULE__{final_num: final, chunks: chunks}) do
    0..final
    |> Enum.map(&Map.fetch!(chunks, &1))
    |> IO.iodata_to_binary()
  end
end

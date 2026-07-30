defmodule WickCoap.BlockSender do
  @moduledoc """
  Outbound Block-wise transfer state machine.

  When a payload is too large for one CoAP datagram, RFC 7959 splits it into a sequence
  of blocks. The sender chooses a block size (`SZX`), splits the payload, and sends one
  block per round-trip:

  * **Block1** flow (request body): every block is a separate CON request carrying the
    same Token; the server ACKs each non-final block with a `2.31 Continue` and the
    final block with the actual response code.
  * **Block2** flow (response body): the server returns the first block in response to
    the original request; the client requests subsequent blocks by re-issuing the same
    request with `Block2.num` set to the next index.

  The state machine here is purely the **chunking** half — it doesn't care which flow
  drives it. The caller (Endpoint integration) decides whether to wrap each chunk in a
  request or a response.

  ## Lifecycle

      iex> sender = WickCoap.BlockSender.new("hello world", szx: 0)
      iex> sender.total_blocks
      1
      iex> {chunk, block, _} = WickCoap.BlockSender.current(sender)
      iex> chunk
      "hello world"
      iex> block.more
      false

      iex> sender = WickCoap.BlockSender.new(:binary.copy("x", 100), szx: 0)
      iex> sender.total_blocks  # 100 bytes / 16 = 7 blocks (last partial)
      7
      iex> {first, block, _} = WickCoap.BlockSender.current(sender)
      iex> {byte_size(first), block.num, block.more}
      {16, 0, true}

      iex> sender = WickCoap.BlockSender.new(:binary.copy("x", 100), szx: 0)
      iex> {:ok, sender} = WickCoap.BlockSender.advance(sender)
      iex> {_, block, _} = WickCoap.BlockSender.current(sender)
      iex> {block.num, block.more}
      {1, true}
  """

  alias WickCoap.Block

  @typedoc "Outbound transfer state."
  @type t :: %__MODULE__{
          payload: binary(),
          szx: 0..6,
          block_size: pos_integer(),
          num: non_neg_integer(),
          total_blocks: pos_integer()
        }

  @enforce_keys [:payload, :szx, :block_size, :num, :total_blocks]
  defstruct [:payload, :szx, :block_size, :num, :total_blocks]

  @doc """
  Build a new sender for the given payload.

  ## Options

  * `:szx` — block size exponent (`0..6`); block size is `2^(szx + 4)`. Default `6`
    (1024 bytes), the largest RFC 7959 size.
  """
  @spec new(binary(), keyword()) :: t()
  def new(payload, opts \\ []) when is_binary(payload) do
    szx = Keyword.get(opts, :szx, 6)
    block_size = Block.size(szx)

    total_blocks =
      case byte_size(payload) do
        0 -> 1
        n -> div(n + block_size - 1, block_size)
      end

    %__MODULE__{
      payload: payload,
      szx: szx,
      block_size: block_size,
      num: 0,
      total_blocks: total_blocks
    }
  end

  @doc """
  The current block, returned as `{chunk, block_option, sender}`.

  * `chunk` — the bytes for this block (last block may be shorter than `block_size`)
  * `block_option` — the `t:WickCoap.Block.t/0` to send alongside the chunk
  * `sender` — unchanged; included for chaining ergonomics
  """
  @spec current(t()) :: {binary(), Block.t(), t()}
  def current(%__MODULE__{} = sender) do
    offset = sender.num * sender.block_size
    remaining = byte_size(sender.payload) - offset
    chunk_size = min(sender.block_size, max(remaining, 0))
    chunk = if chunk_size > 0, do: binary_part(sender.payload, offset, chunk_size), else: <<>>
    more = sender.num + 1 < sender.total_blocks

    block = %Block{num: sender.num, more: more, szx: sender.szx}
    {chunk, block, sender}
  end

  @doc """
  Advance to the next block.

  Returns `{:ok, sender}` if more blocks remain, `:complete` if the previous `current/1`
  was already the final block.
  """
  @spec advance(t()) :: {:ok, t()} | :complete
  def advance(%__MODULE__{} = sender) do
    if sender.num + 1 < sender.total_blocks do
      {:ok, %{sender | num: sender.num + 1}}
    else
      :complete
    end
  end

  @doc "True if the last block has not yet been sent."
  @spec more?(t()) :: boolean()
  def more?(%__MODULE__{num: num, total_blocks: total}), do: num + 1 < total
end

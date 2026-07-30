defmodule WickCoap.Block do
  @moduledoc """
  Block-wise transfer option value — the (NUM, M, SZX) tuple shared by Block1 and Block2
  per [RFC 7959 §2.2](https://www.rfc-editor.org/rfc/rfc7959#section-2.2).

  ## Wire layout

  Both Block1 (option number 27) and Block2 (option number 23) carry a 0–3 byte unsigned
  integer with the same bit layout:

      0                   1                   2                   3
      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3
     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     |   NUM (varies)                  |M| SZX |
     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  * `NUM` — block index, 0-based. Width depends on the encoded byte length:
    `4 bits` (1-byte form, NUM 0..15), `12 bits` (2-byte, 0..4095), `20 bits` (3-byte,
    0..1 048 575).
  * `M` — "more" bit; `1` when more blocks follow, `0` on the final block.
  * `SZX` — size exponent. Block size in bytes is `2^(SZX + 4)`. Valid values 0..6 →
    16 / 32 / 64 / 128 / 256 / 512 / 1024 bytes. SZX = 7 is reserved.

  ## Examples

      iex> b = %WickCoap.Block{num: 0, more: true, szx: 6}
      iex> WickCoap.Block.encode(b)
      <<0x0E>>

      iex> WickCoap.Block.decode(<<0x0E>>)
      {:ok, %WickCoap.Block{num: 0, more: true, szx: 6}}

      iex> WickCoap.Block.size(6)
      1024

      iex> WickCoap.Block.size(0)
      16
  """

  alias WickCoap.Error

  @typedoc "A decoded Block option value."
  @type t :: %__MODULE__{
          num: non_neg_integer(),
          more: boolean(),
          szx: 0..6
        }

  @enforce_keys [:num, :more, :szx]
  defstruct [:num, :more, :szx]

  # CoAP option numbers — re-exported as constants for the Block options.
  @doc "CoAP option number for Block1 (request body block-wise transfer)."
  def block1, do: 27

  @doc "CoAP option number for Block2 (response body block-wise transfer)."
  def block2, do: 23

  @doc """
  Block size in bytes for a given size exponent.

  `2^(szx + 4)` for `szx ∈ 0..6`. SZX = 7 is reserved by RFC 7959.
  """
  @spec size(0..6) :: pos_integer()
  def size(szx) when szx in 0..6, do: Bitwise.bsl(1, szx + 4)

  @doc """
  Encode a Block option value to its wire bytes.

  Picks the shortest of the three forms (1, 2, or 3 bytes) that fits NUM.

  ## Examples

      iex> WickCoap.Block.encode(%WickCoap.Block{num: 0, more: false, szx: 0})
      <<0>>

      iex> WickCoap.Block.encode(%WickCoap.Block{num: 1, more: false, szx: 6})
      <<0x16>>

      iex> WickCoap.Block.encode(%WickCoap.Block{num: 16, more: true, szx: 6})
      <<0x01, 0x0E>>

      iex> WickCoap.Block.encode(%WickCoap.Block{num: 4096, more: false, szx: 6})
      <<0x01, 0x00, 0x06>>
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{num: num, more: more, szx: szx})
      when num >= 0 and szx in 0..6 do
    more_bit = if more, do: 0x08, else: 0
    last = Bitwise.bor(Bitwise.bor(Bitwise.bsl(Bitwise.band(num, 0x0F), 4), more_bit), szx)

    cond do
      num < 0x10 ->
        <<last>>

      num < 0x1000 ->
        <<Bitwise.band(Bitwise.bsr(num, 4), 0xFF), last>>

      num < 0x100000 ->
        <<Bitwise.band(Bitwise.bsr(num, 12), 0xFF), Bitwise.band(Bitwise.bsr(num, 4), 0xFF), last>>
    end
  end

  @doc """
  Decode a Block option value from its wire bytes.

  Returns `{:error, %WickCoap.Error{code: :malformed_block}}` for SZX = 7 (reserved) or
  for byte lengths outside `1..3`.

  ## Examples

      iex> WickCoap.Block.decode(<<0x0E>>)
      {:ok, %WickCoap.Block{num: 0, more: true, szx: 6}}

      iex> WickCoap.Block.decode(<<0x16>>)
      {:ok, %WickCoap.Block{num: 1, more: false, szx: 6}}

      iex> WickCoap.Block.decode(<<0x01, 0x0E>>)
      {:ok, %WickCoap.Block{num: 16, more: true, szx: 6}}

      iex> WickCoap.Block.decode(<<0x07>>)
      {:error, %WickCoap.Error{code: :malformed_block, message: "SZX=7 is reserved", meta: %{szx: 7}}}
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(<<>>) do
    # An empty value means NUM=0, M=0, SZX=0 — equivalent to the all-zero byte. Handle
    # explicitly because `WickCoap.Option.from_uint/2` produces `<<>>` for value 0.
    {:ok, %__MODULE__{num: 0, more: false, szx: 0}}
  end

  def decode(<<last::8>>), do: parse(0, last)

  def decode(<<high::8, last::8>>) do
    parse(high, last)
  end

  def decode(<<hi::8, mid::8, last::8>>) do
    high = Bitwise.bor(Bitwise.bsl(hi, 8), mid)
    parse(high, last)
  end

  def decode(_) do
    {:error, Error.new(:malformed_block, "Block option value must be 0..3 bytes")}
  end

  defp parse(high_bits, last_byte) do
    szx = Bitwise.band(last_byte, 0x07)
    more = Bitwise.band(last_byte, 0x08) != 0
    num_low = Bitwise.bsr(last_byte, 4)
    num = Bitwise.bor(Bitwise.bsl(high_bits, 4), num_low)

    if szx == 7 do
      {:error, Error.new(:malformed_block, "SZX=7 is reserved", szx: 7)}
    else
      {:ok, %__MODULE__{num: num, more: more, szx: szx}}
    end
  end
end

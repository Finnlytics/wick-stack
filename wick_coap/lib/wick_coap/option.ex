defmodule WickCoap.Option do
  @moduledoc """
  CoAP options — the variable-length headers between the token and the payload.

  Per [RFC 7252 §3.1](https://www.rfc-editor.org/rfc/rfc7252#section-3.1) options are
  encoded as a sequence of `(delta, length, value)` tuples where the **delta** is the
  difference from the previous option's number. The list is therefore ordered by option
  number ascending; multiple instances of the same option appear with delta 0.

  WickCoap represents an option as a struct of `number` (the absolute option number, not
  the delta) and `value` (the raw bytes). Helpers for typed values — string, uint, opaque,
  empty — are provided as `value_as_*/1` and `from_*/2` convenience functions.

  ## Registered options

  | Number | Name             | Type   | Reference            |
  |-------:|------------------|--------|----------------------|
  |      1 | If-Match         | opaque | RFC 7252 §5.10.8.1   |
  |      3 | Uri-Host         | string | RFC 7252 §5.10.1     |
  |      4 | ETag             | opaque | RFC 7252 §5.10.6     |
  |      5 | If-None-Match    | empty  | RFC 7252 §5.10.8.2   |
  |      6 | Observe          | uint   | RFC 7641             |
  |      7 | Uri-Port         | uint   | RFC 7252 §5.10.1     |
  |      8 | Location-Path    | string | RFC 7252 §5.10.7     |
  |     11 | Uri-Path         | string | RFC 7252 §5.10.1     |
  |     12 | Content-Format   | uint   | RFC 7252 §5.10.3     |
  |     14 | Max-Age          | uint   | RFC 7252 §5.10.5     |
  |     15 | Uri-Query        | string | RFC 7252 §5.10.1     |
  |     17 | Accept           | uint   | RFC 7252 §5.10.4     |
  |     20 | Location-Query   | string | RFC 7252 §5.10.7     |
  |     23 | Block2           | uint   | RFC 7959             |
  |     27 | Block1           | uint   | RFC 7959             |
  |     28 | Size2            | uint   | RFC 7959             |
  |     35 | Proxy-Uri        | string | RFC 7252 §5.10.2     |
  |     39 | Proxy-Scheme     | string | RFC 7252 §5.10.2     |
  |     60 | Size1            | uint   | RFC 7252 §5.10.9     |
  """

  alias WickCoap.Error

  @typedoc "A CoAP option."
  @type t :: %__MODULE__{
          number: non_neg_integer(),
          value: binary()
        }

  @enforce_keys [:number]
  defstruct [:number, value: <<>>]

  # ── Convenience constructors ────────────────────────────────────────────────

  @doc "Build a new option with raw bytes as the value."
  @spec new(non_neg_integer(), binary()) :: t()
  def new(number, value \\ <<>>) when is_integer(number) and number >= 0 and is_binary(value) do
    %__MODULE__{number: number, value: value}
  end

  @doc """
  Build a new option from an unsigned-integer value, using the **shortest** byte
  representation per RFC 7252 §3.2.

  ## Examples

      iex> WickCoap.Option.from_uint(12, 112).value
      <<112>>

      iex> WickCoap.Option.from_uint(14, 60).value
      <<60>>

      iex> WickCoap.Option.from_uint(14, 0).value
      <<>>

      iex> WickCoap.Option.from_uint(14, 256).value
      <<1, 0>>
  """
  @spec from_uint(non_neg_integer(), non_neg_integer()) :: t()
  def from_uint(number, value)
      when is_integer(number) and number >= 0 and is_integer(value) and value >= 0 do
    %__MODULE__{number: number, value: encode_uint_minimal(value)}
  end

  @doc """
  Read the option value as an unsigned integer per RFC 7252 §3.2.

  An empty value decodes to `0`. Any other byte sequence is interpreted as big-endian.
  """
  @spec value_as_uint(t()) :: non_neg_integer()
  def value_as_uint(%__MODULE__{value: <<>>}), do: 0

  def value_as_uint(%__MODULE__{value: value}) when is_binary(value) do
    bits = bit_size(value)
    <<n::unsigned-big-size(bits)>> = value
    n
  end

  # ── Wire encoding ───────────────────────────────────────────────────────────

  @doc """
  Encode a list of options to bytes per RFC 7252 §3.1.

  Options are sorted by number ascending; deltas are taken from the previous option's number.

  ## Examples

      iex> opts = [%WickCoap.Option{number: 11, value: "rd"}]
      iex> WickCoap.Option.encode(opts) |> Base.encode16()
      "B27264"
  """
  @spec encode([t()]) :: binary()
  def encode(options) when is_list(options) do
    options
    |> Enum.sort_by(& &1.number)
    |> encode_each(0, [])
    |> :binary.list_to_bin()
  end

  defp encode_each([], _previous, acc), do: Enum.reverse(acc)

  defp encode_each([%__MODULE__{number: n, value: value} | rest], previous, acc) do
    delta = n - previous
    encoded = encode_one(delta, value)
    encode_each(rest, n, [encoded | acc])
  end

  defp encode_one(delta, value) do
    {delta_nibble, delta_ext} = encode_extension(delta)
    {length_nibble, length_ext} = encode_extension(byte_size(value))
    head = <<delta_nibble::4, length_nibble::4>>
    head <> delta_ext <> length_ext <> value
  end

  # RFC 7252 §3.1: 0..12 fits in the nibble; 13 means "1-byte extension follows" with
  # value = 13 + ext; 14 means "2-byte extension" with value = 269 + ext; 15 is reserved
  # (only valid as the 0xFF payload marker).
  defp encode_extension(value) when value <= 12, do: {value, <<>>}

  defp encode_extension(value) when value <= 268 do
    {13, <<value - 13::8>>}
  end

  defp encode_extension(value) when value <= 65_804 do
    {14, <<value - 269::16>>}
  end

  # ── Wire decoding ──────────────────────────────────────────────────────────

  @doc """
  Decode an options blob to a list of `t/0` plus any trailing bytes (the payload, after
  its `0xFF` marker).

  Stops at end-of-input, the payload marker (`0xFF`), or returns `{:error, …}` for
  malformed encoding.

  ## Examples

      iex> WickCoap.Option.decode(<<0xB2, ?r, ?d>>)
      {:ok, [%WickCoap.Option{number: 11, value: "rd"}], ""}
  """
  @spec decode(binary()) :: {:ok, [t()], binary()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) do
    {options, rest} = parse(binary, 0, [])
    {:ok, Enum.reverse(options), rest}
  catch
    {:option_error, message} -> {:error, Error.new(:malformed_option, message)}
  end

  defp parse(<<>>, _previous, acc), do: {acc, <<>>}
  defp parse(<<0xFF, payload::binary>>, _previous, acc), do: {acc, payload}

  defp parse(<<delta_nibble::4, length_nibble::4, rest::binary>>, previous, acc) do
    {delta, rest} = decode_extension(delta_nibble, rest)
    {length, rest} = decode_extension(length_nibble, rest)
    number = previous + delta

    case rest do
      <<value::binary-size(length), rest::binary>> ->
        parse(rest, number, [%__MODULE__{number: number, value: value} | acc])

      _ ->
        throw({:option_error, "truncated option value at number #{number}"})
    end
  end

  defp parse(_, _, _), do: throw({:option_error, "truncated option header"})

  defp decode_extension(15, _rest) do
    throw({:option_error, "extension nibble 15 is reserved (payload marker, not extension)"})
  end

  defp decode_extension(nibble, rest) when nibble <= 12, do: {nibble, rest}

  defp decode_extension(13, <<ext::8, rest::binary>>), do: {13 + ext, rest}
  defp decode_extension(13, _), do: throw({:option_error, "missing 1-byte option extension"})

  defp decode_extension(14, <<ext::16, rest::binary>>), do: {269 + ext, rest}
  defp decode_extension(14, _), do: throw({:option_error, "missing 2-byte option extension"})

  # ── Internal — uint encoding (also used by from_uint/2) ────────────────────

  defp encode_uint_minimal(0), do: <<>>

  defp encode_uint_minimal(n) when is_integer(n) and n > 0 do
    bytes = for <<byte <- :binary.encode_unsigned(n)>>, into: <<>>, do: <<byte>>
    bytes
  end
end

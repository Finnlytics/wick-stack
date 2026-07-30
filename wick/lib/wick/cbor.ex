defmodule Wick.Cbor do
  @moduledoc false

  # Internal CBOR primitives. Hand-written against [RFC 8949](https://www.rfc-editor.org/rfc/rfc8949).
  #
  # This module exists because Wick produces deterministic, bit-identical CBOR output (matching
  # the upokecenter CBOR library that Leshan uses). Off-the-shelf Elixir CBOR libraries do not
  # offer that — see ADR 0001 (`docs/decisions/0001-zero-runtime-dependencies.md`).
  #
  # Scope: the subset of CBOR that LwM2M wire formats actually use.
  #   * Major type 0 — unsigned integer
  #   * Major type 1 — negative integer
  #   * Major type 2 — byte string (definite length)
  #   * Major type 3 — text string (definite length, UTF-8)
  #   * Major type 4 — array (definite length, head only)
  #   * Major type 5 — map (definite length, head only)
  #   * Major type 7 — false / true / float16 / float32 / float64
  #
  # Out of scope: tags (major type 6), bignums, indefinite-length items, simple values other
  # than true/false. Add only when a wire format we ship actually requires them.
  #
  # Determinism: integer width is always the shortest form per RFC 8949 §3.1. Float width is
  # the shortest form that preserves the exact IEEE 754 value per RFC 8949 §4.2.1. Map and
  # array contents are the caller's responsibility to order — this module only emits the head.

  @typedoc "Encoded CBOR bytes."
  @type encoded :: binary()

  # ── Integers ────────────────────────────────────────────────────────────────

  @doc """
  Encode an integer of either sign as the shortest CBOR major-type-0 or -1 head.

  Per RFC 8949 §3.1, the encoding picks the smallest of: immediate (1 byte), uint8, uint16,
  uint32, uint64. Negative integers use major type 1 with the unsigned value `-1 - n`.

  ## Examples

      iex> Wick.Cbor.encode_int(0) |> Base.encode16()
      "00"

      iex> Wick.Cbor.encode_int(23) |> Base.encode16()
      "17"

      iex> Wick.Cbor.encode_int(24) |> Base.encode16()
      "1818"

      iex> Wick.Cbor.encode_int(255) |> Base.encode16()
      "18FF"

      iex> Wick.Cbor.encode_int(256) |> Base.encode16()
      "190100"

      iex> Wick.Cbor.encode_int(65_535) |> Base.encode16()
      "19FFFF"

      iex> Wick.Cbor.encode_int(65_536) |> Base.encode16()
      "1A00010000"

      iex> Wick.Cbor.encode_int(-1) |> Base.encode16()
      "20"

      iex> Wick.Cbor.encode_int(-24) |> Base.encode16()
      "37"

      iex> Wick.Cbor.encode_int(-25) |> Base.encode16()
      "3818"

      iex> Wick.Cbor.encode_int(-100) |> Base.encode16()
      "3863"
  """
  @spec encode_int(integer()) :: encoded()
  def encode_int(value) when is_integer(value) and value >= 0, do: encode_head(0, value)
  def encode_int(value) when is_integer(value) and value < 0, do: encode_head(1, -1 - value)

  # ── Strings & byte strings ──────────────────────────────────────────────────

  @doc """
  Encode a UTF-8 string as a CBOR text string (major type 3, definite length).

  ## Examples

      iex> Wick.Cbor.encode_text("") |> Base.encode16()
      "60"

      iex> Wick.Cbor.encode_text("9") |> Base.encode16()
      "6139"

      iex> Wick.Cbor.encode_text("/3/0/") |> Base.encode16()
      "652F332F302F"
  """
  @spec encode_text(String.t()) :: encoded()
  def encode_text(string) when is_binary(string) do
    encode_head(3, byte_size(string)) <> string
  end

  @doc """
  Encode raw bytes as a CBOR byte string (major type 2, definite length).

  ## Examples

      iex> Wick.Cbor.encode_bytes(<<>>) |> Base.encode16()
      "40"

      iex> Wick.Cbor.encode_bytes(<<1, 2, 3>>) |> Base.encode16()
      "43010203"
  """
  @spec encode_bytes(binary()) :: encoded()
  def encode_bytes(bytes) when is_binary(bytes) do
    encode_head(2, byte_size(bytes)) <> bytes
  end

  # ── Booleans ────────────────────────────────────────────────────────────────

  @doc """
  Encode a boolean. Per RFC 8949 §3.3 these are simple values 20 (false) and 21 (true).

  ## Examples

      iex> Wick.Cbor.encode_bool(false) |> Base.encode16()
      "F4"

      iex> Wick.Cbor.encode_bool(true) |> Base.encode16()
      "F5"
  """
  @spec encode_bool(boolean()) :: encoded()
  def encode_bool(false), do: <<0xF4>>
  def encode_bool(true), do: <<0xF5>>

  # ── Floats ──────────────────────────────────────────────────────────────────

  @doc """
  Encode a float using the shortest IEEE 754 width that preserves the exact value.

  Per RFC 8949 §4.2.1 (Preferred Serialization), a float-encoded value is emitted at the
  smallest of `float16` / `float32` / `float64` that round-trips bit-identically to the
  input float64.

  ## Examples

      # Small whole numbers pack into float16 (1.5 = 0x3E00, 100.0 = 0x5640)
      iex> Wick.Cbor.encode_float(1.5) |> Base.encode16()
      "F93E00"

      iex> Wick.Cbor.encode_float(100.0) |> Base.encode16()
      "F95640"

      # 100000.0 exceeds float16's range (max ~65504) but fits exactly in float32
      iex> Wick.Cbor.encode_float(100_000.0) |> Base.encode16()
      "FA47C35000"

      # 1.1 has no exact representation shorter than float64
      iex> Wick.Cbor.encode_float(1.1) |> Base.encode16()
      "FB3FF199999999999A"

      # Zero packs into float16
      iex> Wick.Cbor.encode_float(0.0) |> Base.encode16()
      "F90000"
  """
  @spec encode_float(float()) :: encoded()
  def encode_float(value) when is_float(value) do
    bytes16 = <<value::float-size(16)>>

    case bytes16 do
      <<^value::float-size(16)>> ->
        <<0xF9, bytes16::binary>>

      _ ->
        bytes32 = <<value::float-size(32)>>

        case bytes32 do
          <<^value::float-size(32)>> -> <<0xFA, bytes32::binary>>
          _ -> <<0xFB, value::float-size(64)>>
        end
    end
  end

  # ── Container heads ─────────────────────────────────────────────────────────

  @doc """
  Encode the head of a definite-length CBOR array (major type 4).

  The caller is responsible for emitting the array's `length` items immediately after.

  ## Examples

      iex> Wick.Cbor.encode_array_head(0) |> Base.encode16()
      "80"

      iex> Wick.Cbor.encode_array_head(1) |> Base.encode16()
      "81"

      iex> Wick.Cbor.encode_array_head(23) |> Base.encode16()
      "97"

      iex> Wick.Cbor.encode_array_head(24) |> Base.encode16()
      "9818"
  """
  @spec encode_array_head(non_neg_integer()) :: encoded()
  def encode_array_head(length) when is_integer(length) and length >= 0 do
    encode_head(4, length)
  end

  @doc """
  Encode the head of a definite-length CBOR map (major type 5).

  The caller is responsible for emitting `pairs` key-value pairs immediately after, in the
  exact order they should appear on the wire.

  ## Examples

      iex> Wick.Cbor.encode_map_head(0) |> Base.encode16()
      "A0"

      iex> Wick.Cbor.encode_map_head(3) |> Base.encode16()
      "A3"

      iex> Wick.Cbor.encode_map_head(33) |> Base.encode16()
      "B821"
  """
  @spec encode_map_head(non_neg_integer()) :: encoded()
  def encode_map_head(pairs) when is_integer(pairs) and pairs >= 0 do
    encode_head(5, pairs)
  end

  # ── Decoder ─────────────────────────────────────────────────────────────────

  alias Wick.Error

  @typedoc """
  A decoded CBOR value, in native Elixir form.

  * Unsigned and negative integers — `integer()`
  * Text strings — `binary()` (raw UTF-8 bytes; *not* validated as UTF-8 — accept whatever
    the encoder emitted, defer validation to the consumer if needed)
  * Byte strings — `{:bytes, binary()}` to disambiguate from text strings
  * Floats — `float()` (any width decodes to native float64 in Elixir)
  * Booleans — `boolean()`
  * Null — `nil`
  * Arrays — `[decoded()]`
  * Maps — `%{decoded() => decoded()}` (Elixir maps; duplicate-key behaviour follows
    `Map.put/3` — last write wins)
  * Tag 4 (decimal fraction `[exponent, mantissa]`) — resolved to `integer()` when the
    exponent is non-negative and the result fits a whole number, otherwise to `float()`
  * Other tags — `{:tag, integer(), decoded()}`
  """
  @type decoded ::
          integer()
          | binary()
          | {:bytes, binary()}
          | float()
          | boolean()
          | nil
          | [decoded()]
          | %{decoded() => decoded()}
          | {:tag, non_neg_integer(), decoded()}

  @doc """
  Decode a single CBOR data item from `binary`. Returns `{:ok, value, rest}` where `rest`
  is any unparsed trailing bytes (an empty binary if the input was exactly one item).

  ## Errors

  | Code              | When |
  |-------------------|------|
  | `:malformed_cbor` | Truncated input, reserved additional-info value, indefinite-length item, or invalid simple value |

  ## Examples

      iex> Wick.Cbor.decode(<<0x18, 87>>)
      {:ok, 87, ""}

      iex> Wick.Cbor.decode(<<0x37>>)
      {:ok, -24, ""}

      iex> Wick.Cbor.decode(<<0xF5>>)
      {:ok, true, ""}

      iex> Wick.Cbor.decode(<<0x82, 0x01, 0x02>>)
      {:ok, [1, 2], ""}

      iex> Wick.Cbor.decode(<<0xA1, 0x00, 0x18, 87>>)
      {:ok, %{0 => 87}, ""}

      iex> Wick.Cbor.decode(<<0x44, 0xDE, 0xAD, 0xBE, 0xEF>>)
      {:ok, {:bytes, <<0xDE, 0xAD, 0xBE, 0xEF>>}, ""}
  """
  @spec decode(binary()) :: {:ok, decoded(), binary()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) do
    {value, rest} = parse(binary)
    {:ok, value, rest}
  catch
    {:cbor_error, message} ->
      {:error, Error.new(:malformed_cbor, message)}
  end

  # ── Internal — encoder head ─────────────────────────────────────────────────

  # RFC 8949 §3 head encoding: 3-bit major type + 5-bit "additional info" determines whether
  # the value follows in 0/1/2/4/8 trailing bytes.
  defp encode_head(major_type, value) when value < 24 do
    <<major_type::3, value::5>>
  end

  defp encode_head(major_type, value) when value < 0x100 do
    <<major_type::3, 24::5, value::8>>
  end

  defp encode_head(major_type, value) when value < 0x10000 do
    <<major_type::3, 25::5, value::16>>
  end

  defp encode_head(major_type, value) when value < 0x1_0000_0000 do
    <<major_type::3, 26::5, value::32>>
  end

  defp encode_head(major_type, value) when value < 0x1_0000_0000_0000_0000 do
    <<major_type::3, 27::5, value::64>>
  end

  # ── Internal — decoder ──────────────────────────────────────────────────────

  defp parse(<<>>), do: throw({:cbor_error, "unexpected end of input"})

  defp parse(<<major_type::3, additional::5, rest::binary>>) do
    parse_value(major_type, additional, rest)
  end

  # Major type 0: unsigned integer
  defp parse_value(0, additional, rest) do
    {value, rest} = head_value(additional, rest)
    {value, rest}
  end

  # Major type 1: negative integer (encoded as -1 - n)
  defp parse_value(1, additional, rest) do
    {value, rest} = head_value(additional, rest)
    {-1 - value, rest}
  end

  # Major type 2: byte string
  defp parse_value(2, additional, rest) do
    {length, rest} = head_value(additional, rest)
    take_bytes(rest, length, &{:bytes, &1})
  end

  # Major type 3: text string
  defp parse_value(3, additional, rest) do
    {length, rest} = head_value(additional, rest)
    take_bytes(rest, length, & &1)
  end

  # Major type 4: array
  defp parse_value(4, additional, rest) do
    {length, rest} = head_value(additional, rest)
    take_n(rest, length, [])
  end

  # Major type 5: map
  defp parse_value(5, additional, rest) do
    {length, rest} = head_value(additional, rest)
    take_pairs(rest, length, %{})
  end

  # Major type 6: tagged item
  defp parse_value(6, additional, rest) do
    {tag, rest} = head_value(additional, rest)
    {value, rest} = parse(rest)
    {resolve_tag(tag, value), rest}
  end

  # Major type 7: simple values + floats
  defp parse_value(7, 20, rest), do: {false, rest}
  defp parse_value(7, 21, rest), do: {true, rest}
  defp parse_value(7, 22, rest), do: {nil, rest}

  defp parse_value(7, 25, <<value::float-size(16), rest::binary>>), do: {value, rest}
  defp parse_value(7, 26, <<value::float-size(32), rest::binary>>), do: {value, rest}
  defp parse_value(7, 27, <<value::float-size(64), rest::binary>>), do: {value, rest}

  defp parse_value(7, 25, _), do: throw({:cbor_error, "truncated float16"})
  defp parse_value(7, 26, _), do: throw({:cbor_error, "truncated float32"})
  defp parse_value(7, 27, _), do: throw({:cbor_error, "truncated float64"})

  defp parse_value(7, 31, _), do: throw({:cbor_error, "indefinite-length items not supported"})

  # Any other simple value (0..19, 23, 24, 28..30) — including CBOR's "undefined" (23) and
  # the "1-byte simple value" form (24). Wick rejects these because LwM2M wire formats
  # don't use them.
  defp parse_value(7, additional, _),
    do: throw({:cbor_error, "unsupported simple value or reserved encoding: #{additional}"})

  # Note: for major types 0..6, additional values 28..30 (reserved) and 31 (indefinite
  # length) are not handled by specific clauses here. Instead they fall through into
  # `head_value/2`, which has no matching clause and throws `"truncated head"`. That gives
  # a slightly less specific error message than handling them here, but earlier clauses
  # cover the reachable space — Dialyzer rejects more specific catches as unreachable.

  # Read the head's argument value, advancing past the trailing 0/1/2/4/8 bytes.
  defp head_value(additional, rest) when additional <= 23, do: {additional, rest}
  defp head_value(24, <<value::8, rest::binary>>), do: {value, rest}
  defp head_value(25, <<value::16, rest::binary>>), do: {value, rest}
  defp head_value(26, <<value::32, rest::binary>>), do: {value, rest}
  defp head_value(27, <<value::64, rest::binary>>), do: {value, rest}

  defp head_value(_, _), do: throw({:cbor_error, "truncated head"})

  defp take_bytes(rest, length, wrap) do
    case rest do
      <<bytes::binary-size(length), rest::binary>> -> {wrap.(bytes), rest}
      _ -> throw({:cbor_error, "truncated string of length #{length}"})
    end
  end

  defp take_n(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp take_n(rest, remaining, acc) do
    {value, rest} = parse(rest)
    take_n(rest, remaining - 1, [value | acc])
  end

  defp take_pairs(rest, 0, acc), do: {acc, rest}

  defp take_pairs(rest, remaining, acc) do
    {key, rest} = parse(rest)
    {value, rest} = parse(rest)
    take_pairs(rest, remaining - 1, Map.put(acc, key, value))
  end

  # Tag 4: decimal fraction. Item is `[exponent, mantissa]`; value is `mantissa * 10^exponent`.
  # Return as integer when the result is whole; float otherwise.
  defp resolve_tag(4, [exponent, mantissa]) when is_integer(exponent) and is_integer(mantissa) do
    if exponent >= 0 do
      mantissa * pow10(exponent)
    else
      mantissa * :math.pow(10, exponent)
    end
  end

  defp resolve_tag(4, _), do: throw({:cbor_error, "malformed tag-4 (decimal fraction)"})
  defp resolve_tag(tag, value), do: {:tag, tag, value}

  defp pow10(0), do: 1
  defp pow10(n) when n > 0, do: 10 * pow10(n - 1)
end

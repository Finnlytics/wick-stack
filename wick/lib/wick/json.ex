defmodule Wick.Json do
  @moduledoc false

  # Internal JSON primitives. Hand-written against [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259).
  #
  # This module exists for the same reason as `Wick.Cbor`: bit-level control over the wire output,
  # zero runtime dependencies (see ADR 0001). Scope is the subset of JSON that LwM2M wire formats
  # use:
  #
  #   * Numbers (integer + float)
  #   * Strings, with required escapes per RFC 8259 §7
  #   * Booleans (true / false)
  #   * null
  #   * Arrays (definite length, comma-separated)
  #   * Objects (caller-ordered, comma-separated)
  #
  # Out of scope: pretty-printing, sorted-key emission (caller decides order), Unicode escape
  # output for the BMP (we pass UTF-8 through; control chars get the `\uXXXX` form per spec).
  #
  # Float emission uses Erlang's `:short` formatter — the shortest decimal representation that
  # round-trips to the same IEEE 754 binary64 value. Matches Java's `Double.toString` for typical
  # SenML values. The two diverge at the threshold for switching to scientific notation
  # (Erlang switches at ≥ 10^6, Java at ≥ 10^7); add an ADR if that bites a real fixture.

  @typedoc "Encoded JSON bytes."
  @type encoded :: binary()

  # ── Strings ─────────────────────────────────────────────────────────────────

  @doc """
  Encode a string as a JSON string literal with required escapes.

  Per RFC 8259 §7: `"`, `\\`, and the control characters U+0000 through U+001F must be escaped.
  Everything else passes through (including raw UTF-8 multi-byte sequences).
  """
  @spec encode_text(String.t()) :: encoded()
  def encode_text(string) when is_binary(string) do
    <<?", escape(string)::binary, ?">>
  end

  # ── Numbers ─────────────────────────────────────────────────────────────────

  @doc "Encode an integer as a JSON number."
  @spec encode_int(integer()) :: encoded()
  def encode_int(value) when is_integer(value), do: Integer.to_string(value)

  @doc """
  Encode a float as a JSON number using shortest round-trip form.

  Examples (output uses Erlang's `:short` formatter):

      :erlang.float_to_binary(0.0,   [:short])  #=> "0.0"
      :erlang.float_to_binary(1.5,   [:short])  #=> "1.5"
      :erlang.float_to_binary(3.14,  [:short])  #=> "3.14"
      :erlang.float_to_binary(1.0e7, [:short])  #=> "1.0e7"
  """
  @spec encode_float(float()) :: encoded()
  def encode_float(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])

  # ── Constants ───────────────────────────────────────────────────────────────

  @doc "Encode a boolean as `true` or `false`."
  @spec encode_bool(boolean()) :: encoded()
  def encode_bool(true), do: "true"
  def encode_bool(false), do: "false"

  @doc "Encode `null`."
  @spec encode_null() :: encoded()
  def encode_null, do: "null"

  # ── Containers ──────────────────────────────────────────────────────────────

  @doc """
  Encode an array from a list of pre-encoded items.

  The caller is responsible for encoding each item; this function only wraps in `[…]` and
  joins with commas.
  """
  @spec encode_array([encoded()]) :: encoded()
  def encode_array(items) when is_list(items) do
    body = Enum.intersperse(items, ",") |> IO.iodata_to_binary()
    <<?[, body::binary, ?]>>
  end

  @doc """
  Encode an object from an ordered list of `{encoded_key, encoded_value}` pairs.

  Both key and value must already be JSON-encoded. The caller controls the order — this
  function does not sort. Use Leshan's declaration order or a canonical order at the call
  site, depending on the wire format's contract.
  """
  @spec encode_object([{encoded(), encoded()}]) :: encoded()
  def encode_object(pairs) when is_list(pairs) do
    body =
      pairs
      |> Enum.map(fn {k, v} -> <<k::binary, ?:, v::binary>> end)
      |> Enum.intersperse(",")
      |> IO.iodata_to_binary()

    <<?{, body::binary, ?}>>
  end

  # ── Internals ───────────────────────────────────────────────────────────────

  # RFC 8259 §7. Iterate UTF-8 bytes (not codepoints): the only bytes we need to escape are
  # < 0x20 plus `"` and `\`. All other bytes — including UTF-8 continuation bytes — pass
  # through verbatim.
  defp escape(string) do
    for <<b::8 <- string>>, into: <<>>, do: escape_byte(b)
  end

  defp escape_byte(?"), do: <<?\\, ?">>
  defp escape_byte(?\\), do: <<?\\, ?\\>>
  defp escape_byte(0x08), do: <<?\\, ?b>>
  defp escape_byte(0x09), do: <<?\\, ?t>>
  defp escape_byte(0x0A), do: <<?\\, ?n>>
  defp escape_byte(0x0C), do: <<?\\, ?f>>
  defp escape_byte(0x0D), do: <<?\\, ?r>>

  defp escape_byte(b) when b < 0x20 do
    hex = b |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    <<?\\, ?u, hex::binary>>
  end

  defp escape_byte(b), do: <<b>>

  # ── Decoder ─────────────────────────────────────────────────────────────────

  alias Wick.Error

  @typedoc """
  A decoded JSON value, in native Elixir form.

  * Numbers — `integer()` if the source has no fraction or exponent, `float()` otherwise
  * Strings — `binary()` (UTF-8, with all `\\uXXXX` escapes resolved including BMP-pair surrogates)
  * Booleans — `boolean()`
  * Null — `nil`
  * Arrays — `[decoded()]`
  * Objects — `%{binary() => decoded()}` (string keys; duplicate keys follow `Map.put/3`,
    last write wins)
  """
  @type decoded ::
          integer()
          | float()
          | binary()
          | boolean()
          | nil
          | [decoded()]
          | %{binary() => decoded()}

  @doc """
  Decode a single JSON document into Elixir terms.

  Returns `{:ok, value}` on success, `{:error, %Wick.Error{code: :malformed_json}}` on
  parse failure. Trailing whitespace is allowed; trailing non-whitespace content is rejected.

  ## Examples

      iex> Wick.Json.decode(~s|87|)
      {:ok, 87}

      iex> Wick.Json.decode(~s|1.5|)
      {:ok, 1.5}

      iex> Wick.Json.decode(~s|"hello"|)
      {:ok, "hello"}

      iex> Wick.Json.decode(~s|true|)
      {:ok, true}

      iex> Wick.Json.decode(~s|null|)
      {:ok, nil}

      iex> Wick.Json.decode(~s|[1, 2, 3]|)
      {:ok, [1, 2, 3]}

      iex> Wick.Json.decode(~s|{"n": "/3/0/9", "v": 87}|)
      {:ok, %{"n" => "/3/0/9", "v" => 87}}

      iex> Wick.Json.decode(~s|nope|)
      {:error, %Wick.Error{code: :malformed_json, message: ~s|unexpected character: "n"|, meta: %{}}}
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) do
    {value, rest} = parse_value(skip_ws(binary))

    case skip_ws(rest) do
      "" -> {:ok, value}
      _ -> throw({:json_error, "unexpected trailing content"})
    end
  catch
    {:json_error, message} -> {:error, Error.new(:malformed_json, message)}
  end

  # ── Internals — whitespace ─────────────────────────────────────────────────

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(rest), do: rest

  # ── Internals — values ─────────────────────────────────────────────────────

  defp parse_value(<<"true", rest::binary>>), do: {true, rest}
  defp parse_value(<<"false", rest::binary>>), do: {false, rest}
  defp parse_value(<<"null", rest::binary>>), do: {nil, rest}
  defp parse_value(<<"\"", rest::binary>>), do: parse_string(rest, [])
  defp parse_value(<<"{", rest::binary>>), do: parse_object(skip_ws(rest), %{})
  defp parse_value(<<"[", rest::binary>>), do: parse_array(skip_ws(rest), [])
  defp parse_value(<<"-", _::binary>> = bin), do: parse_number(bin)
  defp parse_value(<<c, _::binary>> = bin) when c in ?0..?9, do: parse_number(bin)
  defp parse_value(<<>>), do: throw({:json_error, "unexpected end of input"})

  defp parse_value(<<c, _::binary>>),
    do: throw({:json_error, "unexpected character: #{inspect(<<c>>)}"})

  # ── Internals — strings ────────────────────────────────────────────────────

  defp parse_string(<<"\"", rest::binary>>, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp parse_string(<<"\\", rest::binary>>, acc), do: parse_escape(rest, acc)

  defp parse_string(<<c, _::binary>>, _) when c < 0x20 do
    throw({:json_error, "unescaped control character (#{c}) in string"})
  end

  defp parse_string(<<c::utf8, rest::binary>>, acc) do
    parse_string(rest, [<<c::utf8>> | acc])
  end

  defp parse_string(<<>>, _), do: throw({:json_error, "unterminated string"})

  defp parse_escape(<<"\"", rest::binary>>, acc), do: parse_string(rest, [?" | acc])
  defp parse_escape(<<"\\", rest::binary>>, acc), do: parse_string(rest, [?\\ | acc])
  defp parse_escape(<<"/", rest::binary>>, acc), do: parse_string(rest, [?/ | acc])
  defp parse_escape(<<"b", rest::binary>>, acc), do: parse_string(rest, [?\b | acc])
  defp parse_escape(<<"f", rest::binary>>, acc), do: parse_string(rest, [?\f | acc])
  defp parse_escape(<<"n", rest::binary>>, acc), do: parse_string(rest, [?\n | acc])
  defp parse_escape(<<"r", rest::binary>>, acc), do: parse_string(rest, [?\r | acc])
  defp parse_escape(<<"t", rest::binary>>, acc), do: parse_string(rest, [?\t | acc])

  defp parse_escape(<<"u", a, b, c, d, rest::binary>>, acc) do
    cp = parse_hex_quad(a, b, c, d)
    handle_unicode_escape(cp, rest, acc)
  end

  defp parse_escape(_, _), do: throw({:json_error, "invalid escape sequence"})

  # High surrogate — must be followed by a low-surrogate \uXXXX. Combine into a single
  # codepoint per UTF-16 surrogate-pair rules.
  defp handle_unicode_escape(cp, <<"\\u", e, f, g, h, rest::binary>>, acc)
       when cp in 0xD800..0xDBFF do
    low = parse_hex_quad(e, f, g, h)

    if low in 0xDC00..0xDFFF do
      full = 0x10000 + Bitwise.bsl(cp - 0xD800, 10) + (low - 0xDC00)
      parse_string(rest, [<<full::utf8>> | acc])
    else
      throw({:json_error, "invalid low surrogate after high surrogate"})
    end
  end

  defp handle_unicode_escape(cp, _rest, _acc) when cp in 0xD800..0xDBFF do
    throw({:json_error, "high surrogate not followed by \\u low surrogate"})
  end

  defp handle_unicode_escape(cp, _rest, _acc) when cp in 0xDC00..0xDFFF do
    throw({:json_error, "lone low surrogate"})
  end

  defp handle_unicode_escape(cp, rest, acc), do: parse_string(rest, [<<cp::utf8>> | acc])

  defp parse_hex_quad(a, b, c, d) do
    Bitwise.bsl(hex_digit(a), 12) +
      Bitwise.bsl(hex_digit(b), 8) +
      Bitwise.bsl(hex_digit(c), 4) +
      hex_digit(d)
  end

  defp hex_digit(c) when c in ?0..?9, do: c - ?0
  defp hex_digit(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_digit(c) when c in ?A..?F, do: c - ?A + 10
  defp hex_digit(c), do: throw({:json_error, "invalid hex digit in \\u escape: #{<<c>>}"})

  # ── Internals — numbers ────────────────────────────────────────────────────

  defp parse_number(bin) do
    {chars, rest} = take_number_chars(bin, [])
    text = chars |> Enum.reverse() |> List.to_string()

    if floaty?(text) do
      case Float.parse(text) do
        {f, ""} -> {f, rest}
        _ -> throw({:json_error, "invalid number: #{inspect(text)}"})
      end
    else
      case Integer.parse(text) do
        {i, ""} -> {i, rest}
        _ -> throw({:json_error, "invalid number: #{inspect(text)}"})
      end
    end
  end

  defp take_number_chars(<<c, rest::binary>>, acc)
       when c in ?0..?9 or c in [?-, ?+, ?., ?e, ?E] do
    take_number_chars(rest, [c | acc])
  end

  defp take_number_chars(rest, acc), do: {acc, rest}

  defp floaty?(text), do: String.contains?(text, [".", "e", "E"])

  # ── Internals — arrays ─────────────────────────────────────────────────────

  defp parse_array(<<"]", rest::binary>>, acc), do: {Enum.reverse(acc), rest}

  defp parse_array(bin, acc) do
    {value, rest} = parse_value(bin)

    case skip_ws(rest) do
      <<",", more::binary>> -> parse_array(skip_ws(more), [value | acc])
      <<"]", more::binary>> -> {Enum.reverse([value | acc]), more}
      _ -> throw({:json_error, "expected ',' or ']' in array"})
    end
  end

  # ── Internals — objects ────────────────────────────────────────────────────

  defp parse_object(<<"}", rest::binary>>, acc), do: {acc, rest}
  defp parse_object(<<"\"", _::binary>> = bin, acc), do: parse_object_pair(bin, acc)
  defp parse_object(_, _), do: throw({:json_error, "expected string key in object"})

  # After a `,` we *must* see another key — never a `}`. Hence the dedicated entry point.
  defp parse_object_pair(<<"\"", _::binary>> = bin, acc) do
    {key, rest} = parse_value(bin)
    rest = skip_ws(rest)

    rest =
      case rest do
        <<":", r::binary>> -> skip_ws(r)
        _ -> throw({:json_error, "expected ':' after object key"})
      end

    {value, rest} = parse_value(rest)
    acc = Map.put(acc, key, value)

    case skip_ws(rest) do
      <<",", more::binary>> -> parse_object_pair(skip_ws(more), acc)
      <<"}", more::binary>> -> {acc, more}
      _ -> throw({:json_error, "expected ',' or '}' in object"})
    end
  end

  defp parse_object_pair(_, _),
    do: throw({:json_error, "expected string key after ',' in object"})
end

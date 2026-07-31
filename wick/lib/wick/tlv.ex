defmodule Wick.Tlv do
  @moduledoc """
  The LwM2M TLV primitive — structure and value encoding, with no LwM2M path semantics.

  TLV (`application/vnd.oma.lwm2m+tlv`, Content-Format 11542) is the original LwM2M binary
  format and the only one **mandatory** in LwM2M 1.0. `Wick.Codec.Tlv` layers the Object
  model on top of this module; everything here is the byte format on its own.

  ## An entry

  Each entry is a type byte, an identifier, an optional length field, and a value:

      ┌────────┬──────────────┬───────────────┬─────────┐
      │  type  │  identifier  │    length     │  value  │
      │ 1 byte │  1 or 2 B    │ 0, 1, 2 or 3 B│    …    │
      └────────┴──────────────┴───────────────┴─────────┘

  The type byte packs four fields:

  | Bits | Meaning |
  |------|---------|
  | 7–6  | entry type — see `t:type/0` |
  | 5    | identifier width: `0` = 8 bits, `1` = 16 bits |
  | 4–3  | length form: `00` inline, `01` 8-bit, `10` 16-bit, `11` 24-bit |
  | 2–0  | the length itself, when bits 4–3 are `00` (so values under 8 bytes carry no length field) |

  ## Nesting

  `:object_instance` and `:multiple_resource` entries carry **children**; `:resource` and
  `:resource_instance` entries carry a **value**. The struct reflects that: exactly one of
  `:value` and `:children` is set.

      %Wick.Tlv{type: :multiple_resource, id: 6, children: [
        %Wick.Tlv{type: :resource_instance, id: 0, value: <<1>>},
        %Wick.Tlv{type: :resource_instance, id: 1, value: <<2>>}
      ]}

  ## Values are not self-describing

  A TLV value is a bare byte string. Four bytes could be an Integer, a Float or a Time, and
  nothing on the wire says which — only the Object definition does. That is why the
  `decode_*` functions here are explicit about the type they read, and why
  `Wick.Codec.Tlv` takes a `Wick.Model`.

  ## Examples

      iex> tlvs = [%Wick.Tlv{type: :resource, id: 9, value: <<87>>}]
      iex> encoded = Wick.Tlv.encode(tlvs) |> IO.iodata_to_binary()
      iex> Base.encode16(encoded)
      "C10957"
      iex> Wick.Tlv.decode(encoded)
      {:ok, [%Wick.Tlv{type: :resource, id: 9, value: <<87>>, children: nil}]}
  """

  alias Wick.Error

  @typedoc """
  The kind of entry, taken from bits 7–6 of the type byte.

  * `:object_instance` — an Object Instance; children are Resources.
  * `:resource_instance` — one Instance of a multiple-instance Resource; carries a value.
  * `:multiple_resource` — a multiple-instance Resource; children are Resource Instances.
  * `:resource` — a single-instance Resource; carries a value.
  """
  @type type :: :object_instance | :resource_instance | :multiple_resource | :resource

  @typedoc "A TLV entry. Exactly one of `:value` and `:children` is set."
  @type t :: %__MODULE__{
          type: type(),
          id: non_neg_integer(),
          value: binary() | nil,
          children: [t()] | nil
        }

  @enforce_keys [:type, :id]
  defstruct [:type, :id, :value, :children]

  # Bits 7-6 of the type byte.
  @types [
    {0b00, :object_instance},
    {0b01, :resource_instance},
    {0b10, :multiple_resource},
    {0b11, :resource}
  ]

  @max_8bit 0xFF
  @max_16bit 0xFFFF
  @max_24bit 0xFFFFFF

  # ── Structure ───────────────────────────────────────────────────────────────

  @doc """
  Encode a list of entries to iodata.

  ## Examples

      iex> Wick.Tlv.encode([%Wick.Tlv{type: :resource, id: 0, value: "ACME"}])
      ...> |> IO.iodata_to_binary()
      ...> |> Base.encode16()
      "C40041434D45"
  """
  @spec encode([t()]) :: iodata()
  def encode(tlvs) when is_list(tlvs), do: Enum.map(tlvs, &encode_entry/1)

  defp encode_entry(%__MODULE__{type: type, id: id} = tlv) do
    body = entry_body(tlv)
    length = IO.iodata_length(body)

    [type_byte(type, id, length), identifier(id), length_field(length), body]
  end

  defp entry_body(%__MODULE__{value: value}) when is_binary(value), do: value
  defp entry_body(%__MODULE__{children: children}) when is_list(children), do: encode(children)
  defp entry_body(%__MODULE__{}), do: <<>>

  defp type_byte(type, id, length) do
    <<type_bits(type)::2, identifier_width(id)::1, length_form(length)::2,
      inline_length(length)::3>>
  end

  for {bits, type} <- @types do
    defp type_bits(unquote(type)), do: unquote(bits)
  end

  defp identifier_width(id) when id <= @max_8bit, do: 0
  defp identifier_width(_id), do: 1

  defp identifier(id) when id <= @max_8bit, do: <<id::8>>
  defp identifier(id), do: <<id::16>>

  # A length under 8 rides in bits 2-0 of the type byte and no length field follows. This is
  # why a one-byte Integer Resource is three bytes on the wire.
  defp length_form(length) when length < 8, do: 0b00
  defp length_form(length) when length <= @max_8bit, do: 0b01
  defp length_form(length) when length <= @max_16bit, do: 0b10
  defp length_form(length) when length <= @max_24bit, do: 0b11

  defp inline_length(length) when length < 8, do: length
  defp inline_length(_length), do: 0

  defp length_field(length) when length < 8, do: <<>>
  defp length_field(length) when length <= @max_8bit, do: <<length::8>>
  defp length_field(length) when length <= @max_16bit, do: <<length::16>>
  defp length_field(length) when length <= @max_24bit, do: <<length::24>>

  @doc """
  Decode TLV bytes into a list of entries.

  Returns `{:error, %Wick.Error{code: :malformed_tlv}}` when the input is truncated or an
  entry's declared length runs past the end of its container.

  ## Examples

      iex> Wick.Tlv.decode(Base.decode16!("C10957"))
      {:ok, [%Wick.Tlv{type: :resource, id: 9, value: <<87>>, children: nil}]}

      iex> {:error, error} = Wick.Tlv.decode(Base.decode16!("C109"))
      iex> error.code
      :malformed_tlv
  """
  @spec decode(binary()) :: {:ok, [t()]} | {:error, Error.t()}
  def decode(binary) when is_binary(binary), do: decode_entries(binary, [])

  defp decode_entries(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_entries(<<type::2, width::1, form::2, inline::3, rest::binary>>, acc) do
    with {:ok, id, rest} <- take_identifier(width, rest),
         {:ok, length, rest} <- take_length(form, inline, rest),
         {:ok, body, rest} <- take_body(length, rest),
         {:ok, entry} <- build(type_from_bits(type), id, body) do
      decode_entries(rest, [entry | acc])
    end
  end

  defp decode_entries(_truncated, _acc), do: {:error, malformed("truncated type byte")}

  defp take_identifier(0, <<id::8, rest::binary>>), do: {:ok, id, rest}
  defp take_identifier(1, <<id::16, rest::binary>>), do: {:ok, id, rest}
  defp take_identifier(_width, _rest), do: {:error, malformed("truncated identifier")}

  defp take_length(0b00, inline, rest), do: {:ok, inline, rest}
  defp take_length(0b01, _inline, <<n::8, rest::binary>>), do: {:ok, n, rest}
  defp take_length(0b10, _inline, <<n::16, rest::binary>>), do: {:ok, n, rest}
  defp take_length(0b11, _inline, <<n::24, rest::binary>>), do: {:ok, n, rest}
  defp take_length(_form, _inline, _rest), do: {:error, malformed("truncated length field")}

  defp take_body(length, binary) when byte_size(binary) >= length do
    <<body::binary-size(length), rest::binary>> = binary
    {:ok, body, rest}
  end

  defp take_body(length, binary) do
    {:error,
     malformed("declared length #{length} exceeds the #{byte_size(binary)} bytes remaining")}
  end

  for {bits, type} <- @types do
    defp type_from_bits(unquote(bits)), do: unquote(type)
  end

  defp build(type, id, body) when type in [:resource, :resource_instance] do
    {:ok, %__MODULE__{type: type, id: id, value: body}}
  end

  defp build(type, id, body) do
    with {:ok, children} <- decode(body) do
      {:ok, %__MODULE__{type: type, id: id, children: children}}
    end
  end

  defp malformed(message), do: Error.new(:malformed_tlv, message)

  # ── Values ──────────────────────────────────────────────────────────────────

  @doc """
  Encode an integer as the shortest signed big-endian representation: 1, 2, 4 or 8 bytes.

  Time uses the same encoding — it is seconds since the Unix epoch, per `Wick.Value`.
  Unsigned Integer does too, which is why a value of 200 takes two bytes rather than one:
  a single byte would read back as -56.

  ## Examples

      iex> Wick.Tlv.encode_integer(87)
      <<87>>

      iex> Wick.Tlv.encode_integer(200)
      <<0, 200>>

      iex> Wick.Tlv.encode_integer(-1)
      <<255>>
  """
  @spec encode_integer(integer()) :: binary()
  def encode_integer(value) when value in -0x80..0x7F, do: <<value::signed-8>>
  def encode_integer(value) when value in -0x8000..0x7FFF, do: <<value::signed-16>>
  def encode_integer(value) when value in -0x8000_0000..0x7FFF_FFFF, do: <<value::signed-32>>
  def encode_integer(value) when is_integer(value), do: <<value::signed-64>>

  @doc """
  Decode a signed big-endian integer of 1–8 bytes.

  ## Examples

      iex> Wick.Tlv.decode_integer(<<0, 200>>)
      {:ok, 200}

      iex> Wick.Tlv.decode_integer(<<255>>)
      {:ok, -1}

      iex> {:error, error} = Wick.Tlv.decode_integer(<<1, 2, 3, 4, 5, 6, 7, 8, 9>>)
      iex> error.code
      :malformed_tlv
  """
  @spec decode_integer(binary()) :: {:ok, integer()} | {:error, Error.t()}
  def decode_integer(value) when byte_size(value) in 1..8 do
    bits = byte_size(value) * 8
    <<n::signed-size(bits)>> = value
    {:ok, n}
  end

  def decode_integer(value) do
    {:error, malformed("invalid length for an integer: #{byte_size(value)} bytes")}
  end

  @doc """
  Encode a float as an 8-byte IEEE 754 double.

  Every Elixir float is a double, so encoding always produces 8 bytes. Decoding accepts the
  4-byte form too, because peers emit it.

  ## Examples

      iex> Wick.Tlv.encode_float(22.5) |> Base.encode16()
      "4036800000000000"
  """
  @spec encode_float(float() | integer()) :: binary()
  def encode_float(value) when is_float(value), do: <<value::float-64>>
  def encode_float(value) when is_integer(value), do: <<value * 1.0::float-64>>

  @doc """
  Decode a 4- or 8-byte IEEE 754 float.

  ## Examples

      iex> Wick.Tlv.decode_float(Base.decode16!("4036800000000000"))
      {:ok, 22.5}
  """
  @spec decode_float(binary()) :: {:ok, float()} | {:error, Error.t()}
  def decode_float(<<value::float-32>>), do: {:ok, value}
  def decode_float(<<value::float-64>>), do: {:ok, value}

  def decode_float(value) do
    {:error, malformed("invalid length for a float: #{byte_size(value)} bytes")}
  end

  @doc """
  Encode a boolean as a single `0` or `1` byte.

  ## Examples

      iex> Wick.Tlv.encode_boolean(true)
      <<1>>
  """
  @spec encode_boolean(boolean()) :: binary()
  def encode_boolean(true), do: <<1>>
  def encode_boolean(false), do: <<0>>

  @doc """
  Decode a single-byte boolean.

  Any non-zero byte reads as `true`. The spec says `0` or `1`, but a peer that sends `2`
  means "true" far more plausibly than it means "reject my payload".

  ## Examples

      iex> Wick.Tlv.decode_boolean(<<1>>)
      {:ok, true}

      iex> Wick.Tlv.decode_boolean(<<0>>)
      {:ok, false}
  """
  @spec decode_boolean(binary()) :: {:ok, boolean()} | {:error, Error.t()}
  def decode_boolean(<<0>>), do: {:ok, false}
  def decode_boolean(<<_byte>>), do: {:ok, true}

  def decode_boolean(value) do
    {:error, malformed("invalid length for a boolean: #{byte_size(value)} bytes")}
  end

  @doc """
  Encode an Objlnk as two 16-bit big-endian identifiers.

  ## Examples

      iex> Wick.Tlv.encode_objlnk({3, 0}) |> Base.encode16()
      "00030000"
  """
  @spec encode_objlnk(Wick.Value.objlnk()) :: binary()
  def encode_objlnk({object_id, instance_id}), do: <<object_id::16, instance_id::16>>

  @doc """
  Decode a 4-byte Objlnk.

  ## Examples

      iex> Wick.Tlv.decode_objlnk(Base.decode16!("00030000"))
      {:ok, {3, 0}}
  """
  @spec decode_objlnk(binary()) :: {:ok, Wick.Value.objlnk()} | {:error, Error.t()}
  def decode_objlnk(<<object_id::16, instance_id::16>>), do: {:ok, {object_id, instance_id}}

  def decode_objlnk(value) do
    {:error, malformed("invalid length for an objlnk: #{byte_size(value)} bytes")}
  end
end

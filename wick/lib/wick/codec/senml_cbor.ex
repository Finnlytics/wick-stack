defmodule Wick.Codec.SenmlCbor do
  @moduledoc """
  SenML CBOR codec for LwM2M payloads.

  CoAP Content-Format `112`. Carries a SenML Pack ([RFC 8428](https://www.rfc-editor.org/rfc/rfc8428))
  encoded as CBOR ([RFC 8949](https://www.rfc-editor.org/rfc/rfc8949)).

  Used in LwM2M 1.1 and 1.2 as the default Content-Format for Read/Write/Notify payloads.

  ## Determinism

  The encoder follows [RFC 8949 §4.2.1](https://www.rfc-editor.org/rfc/rfc8949#section-4.2.1)
  preferred serialization (Core Deterministic Encoding):

  * **Map keys are sorted in canonical CBOR order** — by encoded-key length first, then
    bytewise lexicographic. For our integer labels this means: `n(0), v(2), vs(3), vb(4),
    t(6), vd(8), bn(-2 → 0x21), bt(-3 → 0x22)`, then the 4-byte string key `"vlo"` last.
    This matches Eclipse Leshan 2.x's emission order ([ADR 0002](`docs/decisions/0002-oracle-pinned-to-leshan-2x.md`)).
  * The `<value>` slot is exactly one of `v (2) | vs (3) | vb (4) | vd (8) | "vlo"`,
    chosen by `Wick.Senml.Record.value_type/1`.
  * Integer width is the shortest CBOR representation that fits (RFC 8949 §3.1).
  * Float width is the shortest IEEE 754 size that round-trips bit-identically (§4.2.1).
  * `base_name` and `name` are skipped if `nil` or `""`, matching Leshan's
    `isEmpty()` checks.

  Time fields (`time`, `base_time`) are emitted as plain integers or floats — *not* as
  CBOR tag 4 (decimal fraction). This is a deliberate divergence from Leshan 2.x; see
  [ADR 0003](`docs/decisions/0003-time-fields-as-plain-numbers.md`).

  ## Examples

      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{name: "/3/0/9", number_value: 87}])
      iex> {:ok, bytes} = Wick.Codec.SenmlCbor.encode(pack)
      iex> Base.encode16(bytes)
      "81A200662F332F302F39021857"
  """

  @behaviour Wick.Codec

  alias Wick.Cbor
  alias Wick.Codec
  alias Wick.Error
  alias Wick.Senml.Pack
  alias Wick.Senml.Record

  @content_format 112

  @impl Codec
  @spec content_format() :: 112
  def content_format, do: @content_format

  @doc """
  Encode a `Wick.Senml.Pack` to SenML CBOR bytes.

  ## Options

  * `:allow_no_value` — if `true`, records with no value field set are emitted with only
    their metadata fields (`bn`, `bt`, `n`, `t`). Mirrors Leshan's `allowNoValue` flag,
    used for Read-Composite payloads. Defaults to `false`, which causes such records to
    return `{:error, %Wick.Error{code: :missing_value}}`.

  ## Errors

  | Code              | When |
  |-------------------|------|
  | `:missing_value`  | A record has no value field and `:allow_no_value` is `false` |

  ## Examples

      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{name: "/3/0/9", number_value: 87}])
      iex> {:ok, _bytes} = Wick.Codec.SenmlCbor.encode(pack)

      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{name: "/3/0/9"}])
      iex> {:error, err} = Wick.Codec.SenmlCbor.encode(pack)
      iex> err.code
      :missing_value
  """
  @impl Codec
  @spec encode(Pack.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(pack, opts \\ [])

  def encode(%Pack{records: records}, opts) do
    allow_no_value? = Keyword.get(opts, :allow_no_value, false)

    with :ok <- validate_records(records, allow_no_value?) do
      bytes =
        Cbor.encode_array_head(length(records)) <>
          Enum.map_join(records, "", &encode_record/1)

      {:ok, bytes}
    end
  end

  @doc """
  Decode SenML CBOR bytes into a `Wick.Senml.Pack`.

  Accepts both Wick-emitted output and Leshan-emitted output, including the CBOR tag 4
  (decimal fraction) representation Leshan uses for time fields (see ADR 0003). Tag 4 is
  resolved to a plain integer or float by the underlying `Wick.Cbor` decoder, so the
  produced `Wick.Senml.Record` looks the same regardless of how the time was on the wire.

  ## Errors

  | Code               | When |
  |--------------------|------|
  | `:malformed_cbor`  | The input is not parseable CBOR (truncated, reserved bits, indefinite-length, etc.) |
  | `:malformed_senml` | The CBOR is valid but does not match the SenML shape (top-level not an array, record not a map, value type wrong for its label, etc.) |

  ## Examples

      iex> {:ok, encoded} = Wick.Codec.SenmlCbor.encode(
      ...>   Wick.Senml.Pack.new([%Wick.Senml.Record{name: "/3/0/9", number_value: 87}])
      ...> )
      iex> {:ok, %Wick.Senml.Pack{records: [r]}} = Wick.Codec.SenmlCbor.decode(encoded)
      iex> r.name
      "/3/0/9"
      iex> r.number_value
      87
  """
  @impl Codec
  @spec decode(binary(), keyword()) :: {:ok, Pack.t()} | {:error, Error.t()}
  def decode(binary, opts \\ [])

  def decode(binary, _opts) when is_binary(binary) do
    with {:ok, decoded, _rest} <- Cbor.decode(binary) do
      decode_pack(decoded)
    end
  end

  @spec decode_pack(term()) :: {:ok, Pack.t()} | {:error, Error.t()}
  defp decode_pack(records) when is_list(records) do
    {:ok, %Pack{records: Enum.map(records, &decode_record!/1)}}
  catch
    {:senml_error, message, meta} ->
      {:error, Error.new(:malformed_senml, message, meta)}
  end

  defp decode_pack(other) do
    {:error,
     Error.new(:malformed_senml, "top-level CBOR value must be an array, got: #{inspect(other)}",
       got: type_name(other)
     )}
  end

  @spec decode_record!(term()) :: Record.t()
  defp decode_record!(map) when is_map(map) do
    %Record{
      base_name: take_text!(map, -2),
      base_time: take_number!(map, -3),
      name: take_text!(map, 0),
      time: take_number!(map, 6),
      number_value: take_number!(map, 2),
      string_value: take_text!(map, 3),
      boolean_value: take_bool!(map, 4),
      opaque_value: take_bytes!(map, 8),
      object_link_value: take_text!(map, "vlo")
    }
  end

  defp decode_record!(other),
    do: throw({:senml_error, "expected SenML record map, got: #{inspect(other)}", got: other})

  defp take_text!(map, key) do
    case Map.get(map, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value

      {:bytes, _} ->
        throw({:senml_error, "expected text at key #{inspect(key)}", key: key})

      other ->
        throw(
          {:senml_error, "expected text at key #{inspect(key)}, got: #{inspect(other)}", key: key}
        )
    end
  end

  defp take_number!(map, key) do
    case Map.get(map, key) do
      nil ->
        nil

      value when is_integer(value) or is_float(value) ->
        value

      other ->
        throw(
          {:senml_error, "expected number at key #{inspect(key)}, got: #{inspect(other)}", key: key}
        )
    end
  end

  defp take_bool!(map, key) do
    case Map.get(map, key) do
      nil ->
        nil

      value when is_boolean(value) ->
        value

      other ->
        throw(
          {:senml_error, "expected boolean at key #{inspect(key)}, got: #{inspect(other)}",
           key: key}
        )
    end
  end

  defp take_bytes!(map, key) do
    case Map.get(map, key) do
      nil ->
        nil

      {:bytes, value} ->
        value

      other ->
        throw(
          {:senml_error, "expected bytes at key #{inspect(key)}, got: #{inspect(other)}", key: key}
        )
    end
  end

  # Note: `type_name(list)` is unreachable — `decode_pack/1`'s list clause matches first.
  defp type_name(value) when is_map(value), do: :map
  defp type_name(value) when is_integer(value), do: :integer
  defp type_name(value) when is_float(value), do: :float
  defp type_name(value) when is_binary(value), do: :binary
  defp type_name(value) when is_boolean(value), do: :boolean
  defp type_name(nil), do: nil
  defp type_name(_), do: :unknown

  # ── Encoder internals ───────────────────────────────────────────────────────

  @spec validate_records([Record.t()], boolean()) :: :ok | {:error, Error.t()}
  defp validate_records(_records, true), do: :ok

  defp validate_records(records, false) do
    case Enum.find_index(records, &(Record.value_type(&1) == :none)) do
      nil ->
        :ok

      index ->
        {:error,
         Error.new(:missing_value, "record at index #{index} has no value field set", index: index)}
    end
  end

  @spec encode_record(Record.t()) :: binary()
  defp encode_record(%Record{} = record) do
    fields = record |> present_fields() |> Enum.sort_by(&sort_key/1)
    Cbor.encode_map_head(length(fields)) <> Enum.map_join(fields, "", &encode_pair/1)
  end

  # Returns every field that should appear in this record's map, in any order. The encoder
  # sorts canonically before emission.
  @spec present_fields(Record.t()) :: [{atom(), term()}]
  defp present_fields(%Record{} = record) do
    base = []

    base =
      if non_empty_string?(record.base_name),
        do: [{:base_name, record.base_name} | base],
        else: base

    base = if record.base_time != nil, do: [{:base_time, record.base_time} | base], else: base
    base = if non_empty_string?(record.name), do: [{:name, record.name} | base], else: base
    base = if record.time != nil, do: [{:time, record.time} | base], else: base
    base ++ value_field(record)
  end

  # Canonical CBOR map-key sort (RFC 8949 §4.2.1):
  # 1. Shorter encoded keys come first.
  # 2. Within the same length, bytewise lexicographic order.
  # `Enum.sort_by` with a `{length, bytes}` tuple gives both at once.
  @spec sort_key({atom(), term()}) :: {non_neg_integer(), binary()}
  defp sort_key({label, _value}) do
    encoded = encoded_key(label)
    {byte_size(encoded), encoded}
  end

  @spec encoded_key(atom()) :: binary()
  defp encoded_key(:base_name), do: Cbor.encode_int(-2)
  defp encoded_key(:base_time), do: Cbor.encode_int(-3)
  defp encoded_key(:name), do: Cbor.encode_int(0)
  defp encoded_key(:time), do: Cbor.encode_int(6)
  defp encoded_key(:number_value), do: Cbor.encode_int(2)
  defp encoded_key(:string_value), do: Cbor.encode_int(3)
  defp encoded_key(:boolean_value), do: Cbor.encode_int(4)
  defp encoded_key(:opaque_value), do: Cbor.encode_int(8)
  defp encoded_key(:object_link_value), do: Cbor.encode_text("vlo")

  @spec value_field(Record.t()) :: [{atom(), term()}]
  defp value_field(%Record{} = record) do
    case Record.value_type(record) do
      :number -> [{:number_value, record.number_value}]
      :string -> [{:string_value, record.string_value}]
      :boolean -> [{:boolean_value, record.boolean_value}]
      :opaque -> [{:opaque_value, record.opaque_value}]
      :objlnk -> [{:object_link_value, record.object_link_value}]
      :none -> []
    end
  end

  @spec encode_pair({atom(), term()}) :: binary()
  defp encode_pair({:base_name, value}), do: Cbor.encode_int(-2) <> Cbor.encode_text(value)
  defp encode_pair({:base_time, value}), do: Cbor.encode_int(-3) <> encode_number(value)
  defp encode_pair({:name, value}), do: Cbor.encode_int(0) <> Cbor.encode_text(value)
  defp encode_pair({:time, value}), do: Cbor.encode_int(6) <> encode_number(value)
  defp encode_pair({:number_value, value}), do: Cbor.encode_int(2) <> encode_number(value)
  defp encode_pair({:string_value, value}), do: Cbor.encode_int(3) <> Cbor.encode_text(value)
  defp encode_pair({:boolean_value, value}), do: Cbor.encode_int(4) <> Cbor.encode_bool(value)
  defp encode_pair({:opaque_value, value}), do: Cbor.encode_int(8) <> Cbor.encode_bytes(value)

  defp encode_pair({:object_link_value, value}),
    do: Cbor.encode_text("vlo") <> Cbor.encode_text(value)

  @spec encode_number(integer() | float()) :: binary()
  defp encode_number(value) when is_integer(value), do: Cbor.encode_int(value)
  defp encode_number(value) when is_float(value), do: Cbor.encode_float(value)

  @spec non_empty_string?(term()) :: boolean()
  defp non_empty_string?(value) when is_binary(value) and value != "", do: true
  defp non_empty_string?(_), do: false
end

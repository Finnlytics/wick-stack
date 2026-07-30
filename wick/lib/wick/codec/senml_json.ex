defmodule Wick.Codec.SenmlJson do
  @moduledoc """
  SenML JSON codec for LwM2M payloads.

  CoAP Content-Format `110`. Carries a SenML Pack ([RFC 8428](https://www.rfc-editor.org/rfc/rfc8428))
  encoded as a compact JSON array of objects.

  Used in LwM2M 1.1 and 1.2 alongside SenML CBOR. Less compact than CBOR but human-readable —
  useful for debug bring-up.

  ## Field order

  Map fields are emitted in **Leshan's declaration order**:
  `bn, bt, n, t, <value>` where `<value>` is exactly one of `v | vs | vb | vd | vlo`. This is
  *not* canonical alphabetical order; it matches Eclipse Leshan's
  [`SenMLJsonRecordSerDes.jSerialize`](https://github.com/eclipse-leshan/leshan/blob/leshan-2.0.0-M18/leshan-lwm2m-core/src/main/java/org/eclipse/leshan/senml/json/jackson/SenMLJsonRecordSerDes.java)
  exactly. RFC 8259 leaves object key order unspecified, so this is a deliberate choice for
  byte-identical interop, not a spec requirement.

  Unlike `Wick.Codec.SenmlCbor` (which sorts canonically because Leshan's CBOR path does),
  the JSON path uses Jackson's `ObjectNode` insertion order — which is field-declaration
  order. We match.

  ## Number, string, and opaque encoding

  * Integers — plain decimal digits (`87`, `-1`, `1700000000`).
  * Floats — Erlang's `:short` formatter (shortest round-trip decimal). Matches
    `Double.toString` for typical SenML values; diverges at the threshold for scientific
    notation (Erlang ≥ 1e6, Java ≥ 1e7). See `Wick.Json.encode_float/1`.
  * Strings — RFC 8259 §7 escapes only (`"`, `\\`, control chars). UTF-8 passes through.
  * Opaque values — base64 with standard alphabet and padding (RFC 4648 §4 / RFC 8428 §6.1.1).

  ## Examples

      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{name: "/3/0/9", number_value: 87}])
      iex> {:ok, bytes} = Wick.Codec.SenmlJson.encode(pack)
      iex> bytes
      ~s|[{"n":"/3/0/9","v":87}]|
  """

  @behaviour Wick.Codec

  alias Wick.Codec
  alias Wick.Error
  alias Wick.Json
  alias Wick.Senml.Pack
  alias Wick.Senml.Record

  @content_format 110

  @impl Codec
  @spec content_format() :: 110
  def content_format, do: @content_format

  @doc """
  Encode a `Wick.Senml.Pack` to SenML JSON bytes.

  ## Options

  * `:allow_no_value` — see `Wick.Codec.SenmlCbor.encode/2`. Same semantics.

  ## Errors

  | Code              | When |
  |-------------------|------|
  | `:missing_value`  | A record has no value field and `:allow_no_value` is `false` |
  """
  @impl Codec
  @spec encode(Pack.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(pack, opts \\ [])

  def encode(%Pack{records: records}, opts) do
    allow_no_value? = Keyword.get(opts, :allow_no_value, false)

    with :ok <- validate_records(records, allow_no_value?) do
      {:ok, Json.encode_array(Enum.map(records, &encode_record/1))}
    end
  end

  @doc """
  Decode SenML JSON bytes into a `Wick.Senml.Pack`.

  Accepts both Wick-emitted output and Leshan-emitted output. Opaque values (`vd` field)
  are base64-decoded into raw bytes during extraction.

  ## Errors

  | Code               | When |
  |--------------------|------|
  | `:malformed_json`  | The input is not parseable JSON |
  | `:malformed_senml` | JSON is valid but doesn't match the SenML shape (top-level not an array, record not an object, value type wrong for its label, malformed base64 in `vd`, etc.) |

  ## Examples

      iex> {:ok, %Wick.Senml.Pack{records: [r]}} = Wick.Codec.SenmlJson.decode(~s|[{"n":"/3/0/9","v":87}]|)
      iex> r.name
      "/3/0/9"
      iex> r.number_value
      87
  """
  @impl Codec
  @spec decode(binary(), keyword()) :: {:ok, Pack.t()} | {:error, Error.t()}
  def decode(binary, opts \\ [])

  def decode(binary, _opts) when is_binary(binary) do
    with {:ok, decoded} <- Json.decode(binary) do
      decode_pack(decoded)
    end
  end

  @spec decode_pack(term()) :: {:ok, Pack.t()} | {:error, Error.t()}
  defp decode_pack(records) when is_list(records) do
    {:ok, %Pack{records: Enum.map(records, &decode_record!/1)}}
  catch
    {:senml_error, message, meta} -> {:error, Error.new(:malformed_senml, message, meta)}
  end

  defp decode_pack(other) do
    {:error,
     Error.new(:malformed_senml, "top-level JSON value must be an array, got: #{inspect(other)}",
       got: type_name(other)
     )}
  end

  @spec decode_record!(term()) :: Record.t()
  defp decode_record!(map) when is_map(map) do
    %Record{
      base_name: take_text!(map, "bn"),
      base_time: take_number!(map, "bt"),
      name: take_text!(map, "n"),
      time: take_number!(map, "t"),
      number_value: take_number!(map, "v"),
      string_value: take_text!(map, "vs"),
      boolean_value: take_bool!(map, "vb"),
      opaque_value: take_base64!(map, "vd"),
      object_link_value: take_text!(map, "vlo")
    }
  end

  defp decode_record!(other),
    do: throw({:senml_error, "expected SenML record object, got: #{inspect(other)}", got: other})

  defp take_text!(map, key) do
    case Map.get(map, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value

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

  defp take_base64!(map, key) do
    case Map.get(map, key) do
      nil ->
        nil

      text when is_binary(text) ->
        case Base.decode64(text) do
          {:ok, bytes} -> bytes
          :error -> throw({:senml_error, "invalid base64 in #{key}", key: key})
        end

      other ->
        throw(
          {:senml_error, "expected base64 text at key #{inspect(key)}, got: #{inspect(other)}",
           key: key}
        )
    end
  end

  # `type_name(list)` is unreachable — `decode_pack/1`'s list clause matches first. JSON's
  # value space is closed, so unlike the CBOR variant we don't need a catch-all here.
  defp type_name(value) when is_map(value), do: :map
  defp type_name(value) when is_integer(value), do: :integer
  defp type_name(value) when is_float(value), do: :float
  defp type_name(value) when is_binary(value), do: :binary
  defp type_name(value) when is_boolean(value), do: :boolean
  defp type_name(nil), do: nil

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
    pairs = record |> ordered_fields() |> Enum.map(&encode_pair/1)
    Json.encode_object(pairs)
  end

  # Leshan's declaration order: bn, bt, n, t, then one value field.
  @spec ordered_fields(Record.t()) :: [{atom(), term()}]
  defp ordered_fields(%Record{} = record) do
    base = []

    base =
      if non_empty_string?(record.base_name),
        do: base ++ [{:base_name, record.base_name}],
        else: base

    base = if record.base_time != nil, do: base ++ [{:base_time, record.base_time}], else: base
    base = if non_empty_string?(record.name), do: base ++ [{:name, record.name}], else: base
    base = if record.time != nil, do: base ++ [{:time, record.time}], else: base
    base ++ value_field(record)
  end

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

  @spec encode_pair({atom(), term()}) :: {binary(), binary()}
  defp encode_pair({:base_name, value}), do: {Json.encode_text("bn"), Json.encode_text(value)}
  defp encode_pair({:base_time, value}), do: {Json.encode_text("bt"), encode_number(value)}
  defp encode_pair({:name, value}), do: {Json.encode_text("n"), Json.encode_text(value)}
  defp encode_pair({:time, value}), do: {Json.encode_text("t"), encode_number(value)}
  defp encode_pair({:number_value, value}), do: {Json.encode_text("v"), encode_number(value)}
  defp encode_pair({:string_value, value}), do: {Json.encode_text("vs"), Json.encode_text(value)}
  defp encode_pair({:boolean_value, value}), do: {Json.encode_text("vb"), Json.encode_bool(value)}

  defp encode_pair({:opaque_value, value}),
    do: {Json.encode_text("vd"), Json.encode_text(Base.encode64(value))}

  defp encode_pair({:object_link_value, value}),
    do: {Json.encode_text("vlo"), Json.encode_text(value)}

  @spec encode_number(integer() | float()) :: binary()
  defp encode_number(value) when is_integer(value), do: Json.encode_int(value)
  defp encode_number(value) when is_float(value), do: Json.encode_float(value)

  @spec non_empty_string?(term()) :: boolean()
  defp non_empty_string?(value) when is_binary(value) and value != "", do: true
  defp non_empty_string?(_), do: false
end

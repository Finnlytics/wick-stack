defmodule Wick.Codec.PlainText do
  @moduledoc """
  Plain Text codec for single-Resource LwM2M payloads.

  CoAP Content-Format `0` (`text/plain;charset=UTF-8`). Used for Read/Write of a single
  Resource value when the Content-Format is plain text — the payload is the textual
  representation of the value, with no metadata or framing.

  Plain Text supports only single Resources or single Resource Instances. Multi-instance
  Resources, Object Instances, and full Objects cannot be expressed.

  ## Encoding rules per [OMA LwM2M 1.2 §6.4.4](https://www.openmobilealliance.org/release/LightweightM2M/V1_2_1-20221209-A/OMA-TS-LightweightM2M_Core-V1_2_1-20221209-A.pdf)

  | Resource type     | Wire form |
  |-------------------|-----------|
  | Integer           | Decimal digits, optional `-` sign (e.g. `87`, `-1`) |
  | Float             | Decimal, optional `-` sign and exponent (e.g. `1.5`, `3.14`) |
  | String            | Raw UTF-8 bytes |
  | Boolean           | `1` for true, `0` for false |
  | Time              | Integer seconds since the Unix epoch |
  | Objlnk            | `objectId:instanceId` (e.g. `1:0`) |
  | Opaque            | Base64 with padding (per RFC 4648 §4) |

  This implementation matches Eclipse Leshan's
  [`LwM2mNodeTextEncoder.getStringValue`](https://github.com/eclipse-leshan/leshan/blob/leshan-2.0.0-M18/leshan-lwm2m-core/src/main/java/org/eclipse/leshan/core/node/codec/text/LwM2mNodeTextEncoder.java).

  ## Float formatting

  Floats use Erlang's `:short` shortest-round-trip formatter, the same as `Wick.Codec.SenmlJson`.
  This matches `Double.toString` for typical SenML / LwM2M sensor values; it diverges at the
  threshold for switching to scientific notation (Erlang ≥ `1e6`, Java ≥ `1e7`). See the note
  in `Wick.Json.encode_float/1`.

  ## Examples

      iex> Wick.Codec.PlainText.encode({:integer, 87})
      {:ok, "87"}

      iex> Wick.Codec.PlainText.encode({:boolean, true})
      {:ok, "1"}

      iex> Wick.Codec.PlainText.encode({:objlnk, {1, 0}})
      {:ok, "1:0"}

      iex> Wick.Codec.PlainText.encode({:opaque, <<0xDE, 0xAD, 0xBE, 0xEF>>})
      {:ok, "3q2+7w=="}
  """

  @behaviour Wick.Codec

  alias Wick.Codec
  alias Wick.Error
  alias Wick.Json

  @content_format 0

  @typedoc "A typed Resource value, ready for plain-text encoding."
  @type typed_value ::
          {:integer, integer()}
          | {:float, float()}
          | {:string, String.t()}
          | {:boolean, boolean()}
          | {:time, integer()}
          | {:objlnk, {non_neg_integer(), non_neg_integer()}}
          | {:opaque, binary()}

  @impl Codec
  @spec content_format() :: 0
  def content_format, do: @content_format

  @doc """
  Encode a typed Resource value to its plain-text wire form.

  Input is always a `{type, value}` tuple — the type tag drives encoding, since the wire
  format is type-dependent (e.g. booleans become `1`/`0`, opaque becomes base64).

  ## Errors

  | Code            | When |
  |-----------------|------|
  | `:invalid_type` | The tagged tuple has an unknown type or the value doesn't match the type |

  ## Examples

      iex> Wick.Codec.PlainText.encode({:integer, 87})
      {:ok, "87"}

      iex> Wick.Codec.PlainText.encode({:float, 1.5})
      {:ok, "1.5"}

      iex> Wick.Codec.PlainText.encode({:string, "café"})
      {:ok, "café"}

      iex> Wick.Codec.PlainText.encode({:boolean, false})
      {:ok, "0"}

      iex> Wick.Codec.PlainText.encode({:time, 1700000000})
      {:ok, "1700000000"}
  """
  @impl Codec
  @spec encode(typed_value(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(typed_value, opts \\ [])

  def encode({:integer, n}, _opts) when is_integer(n), do: {:ok, Integer.to_string(n)}
  def encode({:float, f}, _opts) when is_float(f), do: {:ok, Json.encode_float(f)}
  def encode({:string, s}, _opts) when is_binary(s), do: {:ok, s}
  def encode({:boolean, true}, _opts), do: {:ok, "1"}
  def encode({:boolean, false}, _opts), do: {:ok, "0"}
  def encode({:time, t}, _opts) when is_integer(t), do: {:ok, Integer.to_string(t)}

  def encode({:objlnk, {oid, iid}}, _opts)
      when is_integer(oid) and oid >= 0 and is_integer(iid) and iid >= 0 do
    {:ok, "#{oid}:#{iid}"}
  end

  def encode({:opaque, bytes}, _opts) when is_binary(bytes), do: {:ok, Base.encode64(bytes)}

  def encode(other, _opts) do
    {:error,
     Error.new(:invalid_type, "unsupported plain-text value: #{inspect(other)}", value: other)}
  end

  @doc """
  Decode plain-text bytes into a typed Resource value.

  Plain-text payloads are not self-describing — the same byte string `"87"` could be an
  integer, a string, a time, or even an objlnk-prefix. The caller must therefore supply
  the target type via the `:as` option:

      iex> Wick.Codec.PlainText.decode("87", as: :integer)
      {:ok, {:integer, 87}}

      iex> Wick.Codec.PlainText.decode("87", as: :string)
      {:ok, {:string, "87"}}

  ## Options

  * `:as` — required. One of `:integer`, `:float`, `:string`, `:boolean`, `:time`,
    `:objlnk`, `:opaque`. Drives the parse strategy.

  ## Errors

  | Code               | When |
  |--------------------|------|
  | `:missing_type`    | The `:as` option was not supplied |
  | `:invalid_type`    | The `:as` option is not a recognised type |
  | `:malformed_text`  | The bytes do not parse as the requested type |

  ## Examples

      iex> Wick.Codec.PlainText.decode("1.5", as: :float)
      {:ok, {:float, 1.5}}

      iex> Wick.Codec.PlainText.decode("hello", as: :string)
      {:ok, {:string, "hello"}}

      iex> Wick.Codec.PlainText.decode("1", as: :boolean)
      {:ok, {:boolean, true}}

      iex> Wick.Codec.PlainText.decode("0", as: :boolean)
      {:ok, {:boolean, false}}

      iex> Wick.Codec.PlainText.decode("1700000000", as: :time)
      {:ok, {:time, 1_700_000_000}}

      iex> Wick.Codec.PlainText.decode("1:0", as: :objlnk)
      {:ok, {:objlnk, {1, 0}}}

      iex> Wick.Codec.PlainText.decode("3q2+7w==", as: :opaque)
      {:ok, {:opaque, <<0xDE, 0xAD, 0xBE, 0xEF>>}}
  """
  @impl Codec
  @spec decode(binary(), keyword()) :: {:ok, typed_value()} | {:error, Error.t()}
  def decode(binary, opts \\ [])

  def decode(binary, opts) when is_binary(binary) do
    case Keyword.fetch(opts, :as) do
      :error ->
        {:error, Error.new(:missing_type, "Wick.Codec.PlainText.decode/2 requires :as type hint")}

      {:ok, type} ->
        decode_typed(binary, type)
    end
  end

  defp decode_typed(binary, :integer) do
    case Integer.parse(binary) do
      {n, ""} -> {:ok, {:integer, n}}
      _ -> malformed(binary, :integer, "not a decimal integer")
    end
  end

  defp decode_typed(binary, :float) do
    case Float.parse(binary) do
      {f, ""} -> {:ok, {:float, f}}
      _ -> malformed(binary, :float, "not a decimal float")
    end
  end

  defp decode_typed(binary, :string), do: {:ok, {:string, binary}}

  defp decode_typed("0", :boolean), do: {:ok, {:boolean, false}}
  defp decode_typed("1", :boolean), do: {:ok, {:boolean, true}}

  defp decode_typed(binary, :boolean),
    do: malformed(binary, :boolean, ~s|expected "0" or "1"|)

  defp decode_typed(binary, :time) do
    case Integer.parse(binary) do
      {n, ""} -> {:ok, {:time, n}}
      _ -> malformed(binary, :time, "not a Unix-epoch integer")
    end
  end

  defp decode_typed(binary, :objlnk) do
    with [oid_str, iid_str] <- String.split(binary, ":", parts: 2),
         {oid, ""} when oid >= 0 <- Integer.parse(oid_str),
         {iid, ""} when iid >= 0 <- Integer.parse(iid_str) do
      {:ok, {:objlnk, {oid, iid}}}
    else
      _ -> malformed(binary, :objlnk, "expected 'objectId:instanceId' with non-negative integers")
    end
  end

  defp decode_typed(binary, :opaque) do
    case Base.decode64(binary) do
      {:ok, bytes} -> {:ok, {:opaque, bytes}}
      :error -> malformed(binary, :opaque, "not a valid standard-alphabet base64 string")
    end
  end

  defp decode_typed(_binary, type) do
    {:error, Error.new(:invalid_type, "unsupported plain-text type: #{inspect(type)}", type: type)}
  end

  defp malformed(binary, type, reason) do
    {:error,
     Error.new(:malformed_text, "could not decode as #{type}: #{reason}",
       type: type,
       input: binary
     )}
  end
end

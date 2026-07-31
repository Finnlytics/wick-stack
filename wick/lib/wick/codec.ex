defmodule Wick.Codec do
  @moduledoc """
  Behaviour for LwM2M wire-format codecs.

  Each LwM2M wire format (SenML CBOR, SenML JSON, LwM2M CBOR, Plain Text, Opaque, ...) implements
  this behaviour. Encoders and decoders are pure functions: no process state, no side effects
  beyond `:telemetry` events.

  ## Implementations

  | Module                  | Content-Format | Reference |
  |-------------------------|:--------------:|-----------|
  | `Wick.Codec.PlainText`  | `0`            | `text/plain` |
  | `Wick.Codec.Opaque`     | `42`           | `application/octet-stream` |
  | `Wick.Codec.SenmlJson`  | `110`          | [RFC 8428](https://www.rfc-editor.org/rfc/rfc8428) |
  | `Wick.Codec.SenmlCbor`  | `112`          | [RFC 8428](https://www.rfc-editor.org/rfc/rfc8428) |
  | `Wick.Codec.Tlv`        | `11542`        | `application/vnd.oma.lwm2m+tlv` |

  `Wick.Codec.Tlv` needs more than a payload: TLV carries no names, so `encode/2` and
  `decode/2` require a `:path`, and typing values needs a `:model`. Resolving a
  Content-Format to a module is still the same call; supplying its options is the caller's
  job.

  `for_content_format/1` resolves a Content-Format integer to its module, which is what a
  request handler needs when it has to decode a payload whose format the peer chose.

  ## Telemetry

  All implementations emit telemetry from the public boundary:

  * `[:wick, :codec, :encode, :start | :stop | :exception]`
  * `[:wick, :codec, :decode, :start | :stop | :exception]`

  Metadata always includes the codec module under the `:codec` key. Measurements include
  `:duration` and (for `:stop`) `:byte_size`.
  """

  alias Wick.Error

  @typedoc "An iolist or binary that an encoder produces."
  @type encoded :: iodata()

  @typedoc "Decoded content. Shape is codec-specific; commonly a list of records or nodes."
  @type decoded :: term()

  @typedoc "Codec-specific options keyword list."
  @type opts :: keyword()

  @doc "The CoAP Content-Format integer registered for this codec."
  @callback content_format() :: non_neg_integer()

  @doc "Encode decoded content to the wire format."
  @callback encode(decoded(), opts()) :: {:ok, encoded()} | {:error, Error.t()}

  @doc "Decode a wire-format binary into decoded content."
  @callback decode(binary(), opts()) :: {:ok, decoded()} | {:error, Error.t()}

  @registry [
    {0, Wick.Codec.PlainText},
    {42, Wick.Codec.Opaque},
    {110, Wick.Codec.SenmlJson},
    {112, Wick.Codec.SenmlCbor},
    {11_542, Wick.Codec.Tlv}
  ]

  @doc """
  Resolve a CoAP Content-Format integer to the codec module that implements it, or `nil`
  when Wick ships no codec for it.

  ## Examples

      iex> Wick.Codec.for_content_format(112)
      Wick.Codec.SenmlCbor

      iex> Wick.Codec.for_content_format(0)
      Wick.Codec.PlainText

      iex> Wick.Codec.for_content_format(11_542)
      Wick.Codec.Tlv

      iex> Wick.Codec.for_content_format(11_543)
      nil
  """
  @spec for_content_format(non_neg_integer()) :: module() | nil
  for {content_format, module} <- @registry do
    def for_content_format(unquote(content_format)), do: unquote(module)
  end

  def for_content_format(content_format)
      when is_integer(content_format) and content_format >= 0,
      do: nil

  @doc """
  Every Content-Format Wick ships a codec for, ascending.

  ## Examples

      iex> Wick.Codec.content_formats()
      [0, 42, 110, 112, 11542]
  """
  @spec content_formats() :: [non_neg_integer()]
  def content_formats, do: Enum.map(@registry, &elem(&1, 0))

  @senml_modules [Wick.Codec.SenmlJson, Wick.Codec.SenmlCbor]

  @doc """
  Resolve `content_format` to a SenML codec module.

  The two SenML formats are the only ones that carry a `Wick.Senml.Pack`, and therefore
  the only ones valid for Composite operations and for multi-Resource Read / Notify / Send
  payloads. Returns `:error` for anything else — including `nil`, so callers can pass an
  absent Content-Format straight through.

  ## Examples

      iex> Wick.Codec.senml_codec(112)
      {:ok, Wick.Codec.SenmlCbor}

      iex> Wick.Codec.senml_codec(110)
      {:ok, Wick.Codec.SenmlJson}

      iex> Wick.Codec.senml_codec(0)
      :error

      iex> Wick.Codec.senml_codec(nil)
      :error
  """
  @spec senml_codec(non_neg_integer() | nil) :: {:ok, module()} | :error
  for {content_format, module} <- @registry, module in @senml_modules do
    def senml_codec(unquote(content_format)), do: {:ok, unquote(module)}
  end

  def senml_codec(content_format) when is_integer(content_format) or is_nil(content_format),
    do: :error

  @doc """
  True when `content_format` is one of the SenML codecs. See `senml_codec/1`.

  ## Examples

      iex> Wick.Codec.senml?(112)
      true

      iex> Wick.Codec.senml?(0)
      false
  """
  @spec senml?(non_neg_integer() | nil) :: boolean()
  def senml?(content_format), do: senml_codec(content_format) != :error
end

defmodule Wick.Codec.Opaque do
  @moduledoc """
  Opaque codec for single OPAQUE-typed Resource payloads.

  CoAP Content-Format `42` (`application/octet-stream`). The wire form is **the raw bytes**
  of the Resource value — no transformation, no framing.

  Per [OMA LwM2M 1.2 §6.4.5](https://www.openmobilealliance.org/release/LightweightM2M/V1_2_1-20221209-A/OMA-TS-LightweightM2M_Core-V1_2_1-20221209-A.pdf)
  and Eclipse Leshan's [`LwM2mNodeOpaqueEncoder`](https://github.com/eclipse-leshan/leshan/blob/leshan-2.0.0-M18/leshan-lwm2m-core/src/main/java/org/eclipse/leshan/core/node/codec/opaque/LwM2mNodeOpaqueEncoder.java),
  this codec only applies to single OPAQUE-typed Resources or Resource Instances. The codec
  itself doesn't know the Resource type — that's the consumer's responsibility — but the
  payload semantics are only well-defined for OPAQUE Resources.

  Use this when sending a firmware blob, an opaque configuration profile, or any binary
  data that is not naturally textual.

  ## Examples

      iex> Wick.Codec.Opaque.encode(<<0xDE, 0xAD, 0xBE, 0xEF>>)
      {:ok, <<0xDE, 0xAD, 0xBE, 0xEF>>}

      iex> Wick.Codec.Opaque.encode(<<>>)
      {:ok, ""}

      iex> Wick.Codec.Opaque.decode(<<0xCA, 0xFE>>)
      {:ok, <<0xCA, 0xFE>>}
  """

  @behaviour Wick.Codec

  alias Wick.Codec
  alias Wick.Error

  @content_format 42

  @impl Codec
  @spec content_format() :: 42
  def content_format, do: @content_format

  @doc """
  Encode raw bytes as the Opaque wire form (identity).

  Returns `{:error, %Wick.Error{code: :invalid_type}}` if input is not a binary.
  """
  @impl Codec
  @spec encode(binary(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(bytes, opts \\ [])
  def encode(bytes, _opts) when is_binary(bytes), do: {:ok, bytes}

  def encode(other, _opts) do
    {:error,
     Error.new(:invalid_type, "Opaque encoder requires a binary, got: #{inspect(other)}",
       value: other
     )}
  end

  @doc """
  Decode the Opaque wire form to raw bytes (identity).

  Returns `{:error, %Wick.Error{code: :invalid_type}}` if input is not a binary.
  """
  @impl Codec
  @spec decode(binary(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def decode(bytes, opts \\ [])
  def decode(bytes, _opts) when is_binary(bytes), do: {:ok, bytes}

  def decode(other, _opts) do
    {:error,
     Error.new(:invalid_type, "Opaque decoder requires a binary, got: #{inspect(other)}",
       value: other
     )}
  end
end

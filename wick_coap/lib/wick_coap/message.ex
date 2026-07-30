defmodule WickCoap.Message do
  @moduledoc """
  A CoAP message — the unit of CoAP communication.

  Per [RFC 7252 §3](https://www.rfc-editor.org/rfc/rfc7252#section-3) every CoAP message
  carries a 4-byte header, a 0-8 byte token, a (possibly empty) sequence of options, and
  an optional payload. WickCoap models that as a struct:

  | Field          | Type                          | RFC 7252 |
  |----------------|-------------------------------|----------|
  | `:type`        | `:con` `:non` `:ack` `:rst`   | §3       |
  | `:code`        | `t:WickCoap.Code.t/0`         | §3, §5.9 |
  | `:message_id`  | `0..65535`                    | §3       |
  | `:token`       | `binary()` (0–8 bytes)        | §3       |
  | `:options`     | `[t:WickCoap.Option.t/0]`     | §3.1     |
  | `:payload`     | `binary()`                    | §3       |

  ## Header layout

      0                   1                   2                   3
      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     |Ver| T |  TKL  |      Code     |          Message ID           |
     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     |   Token (if any, TKL bytes) ...
     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     |   Options (if any) ...
     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     |1 1 1 1 1 1 1 1|    Payload (if any) ...
     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  ## Examples

      iex> msg = %WickCoap.Message{
      ...>   type: :con,
      ...>   code: :get,
      ...>   message_id: 0x1234,
      ...>   token: <<0xCA, 0xFE>>,
      ...>   options: [WickCoap.Option.new(11, "rd")],
      ...>   payload: <<>>
      ...> }
      iex> {:ok, bytes} = WickCoap.Message.encode(msg)
      iex> Base.encode16(bytes)
      "42011234CAFEB27264"

      iex> {:ok, msg, ""} = WickCoap.Message.decode(<<0x42, 0x01, 0x12, 0x34, 0xCA, 0xFE, 0xB2, ?r, ?d>>)
      iex> {msg.type, msg.code, msg.message_id, msg.token}
      {:con, :get, 0x1234, <<0xCA, 0xFE>>}
  """

  alias WickCoap.Code
  alias WickCoap.Error
  alias WickCoap.Option

  @typedoc "CoAP message type — the 2-bit `T` header field."
  @type type :: :con | :non | :ack | :rst

  @typedoc "A CoAP message."
  @type t :: %__MODULE__{
          type: type(),
          code: Code.t(),
          message_id: 0..0xFFFF,
          token: binary(),
          options: [Option.t()],
          payload: binary()
        }

  @enforce_keys [:type, :code, :message_id]
  defstruct [:type, :code, :message_id, token: <<>>, options: [], payload: <<>>]

  # ── Encoding ────────────────────────────────────────────────────────────────

  @doc """
  Encode a message to a CoAP wire-format binary.

  ## Errors

  | Code            | When |
  |-----------------|------|
  | `:invalid_token` | Token is longer than 8 bytes (RFC 7252 §3 reserves TKL = 9..15) |
  """
  @spec encode(t()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(%__MODULE__{token: token}) when byte_size(token) > 8 do
    {:error,
     Error.new(:invalid_token, "token must be at most 8 bytes (got #{byte_size(token)})",
       length: byte_size(token)
     )}
  end

  def encode(%__MODULE__{} = msg) do
    header = <<
      1::2,
      encode_type(msg.type)::2,
      byte_size(msg.token)::4,
      Code.encode(msg.code)::8,
      msg.message_id::16
    >>

    options = Option.encode(msg.options)
    payload = encode_payload(msg.payload)

    {:ok, header <> msg.token <> options <> payload}
  end

  defp encode_payload(<<>>), do: <<>>
  defp encode_payload(payload) when is_binary(payload), do: <<0xFF>> <> payload

  defp encode_type(:con), do: 0
  defp encode_type(:non), do: 1
  defp encode_type(:ack), do: 2
  defp encode_type(:rst), do: 3

  # ── Decoding ────────────────────────────────────────────────────────────────

  @doc """
  Decode a CoAP wire-format binary to a message struct, returning any unparsed trailing
  bytes (always empty for a well-formed CoAP datagram, but exposed for completeness).

  ## Errors

  | Code                  | When |
  |-----------------------|------|
  | `:malformed_message`  | Truncated header, invalid version, reserved TKL, etc. |
  | `:malformed_option`   | An option's delta/length encoding is malformed |
  """
  @spec decode(binary()) :: {:ok, t(), binary()} | {:error, Error.t()}
  def decode(<<1::2, type_bits::2, tkl::4, code_byte::8, message_id::16, rest::binary>>)
      when tkl <= 8 do
    case rest do
      <<token::binary-size(tkl), rest::binary>> ->
        with {:ok, options, payload} <- Option.decode(rest) do
          message = %__MODULE__{
            type: decode_type(type_bits),
            code: Code.decode(code_byte),
            message_id: message_id,
            token: token,
            options: options,
            payload: payload
          }

          {:ok, message, <<>>}
        end

      _ ->
        {:error,
         Error.new(:malformed_message, "token field truncated; expected #{tkl} bytes", tkl: tkl)}
    end
  end

  def decode(<<1::2, _::2, tkl::4, _rest::binary>>) when tkl in 9..15 do
    {:error,
     Error.new(:malformed_message, "reserved TKL value #{tkl} (RFC 7252 §3 limits to 0..8)",
       tkl: tkl
     )}
  end

  def decode(<<version::2, _::bitstring>>) when version != 1 do
    {:error,
     Error.new(:malformed_message, "unsupported CoAP version #{version} (only v1 is defined)",
       version: version
     )}
  end

  def decode(_) do
    {:error, Error.new(:malformed_message, "header truncated; need at least 4 bytes")}
  end

  defp decode_type(0), do: :con
  defp decode_type(1), do: :non
  defp decode_type(2), do: :ack
  defp decode_type(3), do: :rst
end

defmodule WickCoap.Code do
  @moduledoc """
  CoAP message codes — methods, response codes, and the empty signal.

  CoAP packs the code into a single byte: 3-bit class + 5-bit detail, conventionally
  written as `c.dd`. WickCoap exposes the registered codes as **atoms** with bidirectional
  byte translation; unrecognised codes pass through as `{class, detail}` tuples so consumers
  can still inspect them.

  ## Code table

  | Atom                            | Byte   | c.dd | Source                                            |
  |---------------------------------|:------:|:----:|---------------------------------------------------|
  | `:empty`                        | `0x00` | 0.00 | RFC 7252 §4.1                                     |
  | `:get`                          | `0x01` | 0.01 | RFC 7252 §5.8.1                                   |
  | `:post`                         | `0x02` | 0.02 | RFC 7252 §5.8.2                                   |
  | `:put`                          | `0x03` | 0.03 | RFC 7252 §5.8.3                                   |
  | `:delete`                       | `0x04` | 0.04 | RFC 7252 §5.8.4                                   |
  | `:fetch`                        | `0x05` | 0.05 | RFC 8132                                          |
  | `:patch`                        | `0x06` | 0.06 | RFC 8132                                          |
  | `:ipatch`                       | `0x07` | 0.07 | RFC 8132                                          |
  | `:created`                      | `0x41` | 2.01 | RFC 7252 §5.9.1.1                                 |
  | `:deleted`                      | `0x42` | 2.02 | RFC 7252 §5.9.1.2                                 |
  | `:valid`                        | `0x43` | 2.03 | RFC 7252 §5.9.1.3                                 |
  | `:changed`                      | `0x44` | 2.04 | RFC 7252 §5.9.1.4                                 |
  | `:content`                      | `0x45` | 2.05 | RFC 7252 §5.9.1.5                                 |
  | `:continue`                     | `0x5F` | 2.31 | RFC 7959 §2.9                                     |
  | `:bad_request`                  | `0x80` | 4.00 | RFC 7252 §5.9.2.1                                 |
  | `:unauthorized`                 | `0x81` | 4.01 | RFC 7252 §5.9.2.2                                 |
  | `:bad_option`                   | `0x82` | 4.02 | RFC 7252 §5.9.2.3                                 |
  | `:forbidden`                    | `0x83` | 4.03 | RFC 7252 §5.9.2.4                                 |
  | `:not_found`                    | `0x84` | 4.04 | RFC 7252 §5.9.2.5                                 |
  | `:method_not_allowed`           | `0x85` | 4.05 | RFC 7252 §5.9.2.6                                 |
  | `:not_acceptable`               | `0x86` | 4.06 | RFC 7252 §5.9.2.7                                 |
  | `:request_entity_incomplete`    | `0x88` | 4.08 | RFC 7959 §2.9                                     |
  | `:precondition_failed`          | `0x8C` | 4.12 | RFC 7252 §5.9.2.8                                 |
  | `:request_entity_too_large`     | `0x8D` | 4.13 | RFC 7252 §5.9.2.9 / RFC 7959                       |
  | `:unsupported_content_format`   | `0x8F` | 4.15 | RFC 7252 §5.9.2.10                                |
  | `:internal_server_error`        | `0xA0` | 5.00 | RFC 7252 §5.9.3.1                                 |
  | `:not_implemented`              | `0xA1` | 5.01 | RFC 7252 §5.9.3.2                                 |
  | `:bad_gateway`                  | `0xA2` | 5.02 | RFC 7252 §5.9.3.3                                 |
  | `:service_unavailable`          | `0xA3` | 5.03 | RFC 7252 §5.9.3.4                                 |
  | `:gateway_timeout`              | `0xA4` | 5.04 | RFC 7252 §5.9.3.5                                 |
  | `:proxying_not_supported`       | `0xA5` | 5.05 | RFC 7252 §5.9.3.6                                 |

  ## Examples

      iex> WickCoap.Code.encode(:get)
      0x01

      iex> WickCoap.Code.decode(0x45)
      :content

      iex> WickCoap.Code.decode(0x99)
      {4, 25}

      iex> WickCoap.Code.class(:content)
      2

      iex> WickCoap.Code.class({:method, :get})
      0
  """

  @typedoc "A registered code, or an `{class, detail}` tuple for unrecognised values."
  @type t :: atom() | {0..7, 0..31}

  @table [
    {:empty, 0x00},
    {:get, 0x01},
    {:post, 0x02},
    {:put, 0x03},
    {:delete, 0x04},
    {:fetch, 0x05},
    {:patch, 0x06},
    {:ipatch, 0x07},
    {:created, 0x41},
    {:deleted, 0x42},
    {:valid, 0x43},
    {:changed, 0x44},
    {:content, 0x45},
    {:continue, 0x5F},
    {:bad_request, 0x80},
    {:unauthorized, 0x81},
    {:bad_option, 0x82},
    {:forbidden, 0x83},
    {:not_found, 0x84},
    {:method_not_allowed, 0x85},
    {:not_acceptable, 0x86},
    {:request_entity_incomplete, 0x88},
    {:precondition_failed, 0x8C},
    {:request_entity_too_large, 0x8D},
    {:unsupported_content_format, 0x8F},
    {:internal_server_error, 0xA0},
    {:not_implemented, 0xA1},
    {:bad_gateway, 0xA2},
    {:service_unavailable, 0xA3},
    {:gateway_timeout, 0xA4},
    {:proxying_not_supported, 0xA5}
  ]

  @doc "Encode a code atom (or `{class, detail}` tuple) to its single-byte CoAP form."
  @spec encode(t()) :: 0..255
  for {atom, byte} <- @table do
    def encode(unquote(atom)), do: unquote(byte)
  end

  def encode({class, detail}) when class in 0..7 and detail in 0..31 do
    Bitwise.bsl(class, 5) + detail
  end

  @doc """
  Decode a single CoAP code byte to its atom form, or `{class, detail}` for unrecognised
  values. Decoding is total — every input byte produces an output.
  """
  @spec decode(0..255) :: t()
  for {atom, byte} <- @table do
    def decode(unquote(byte)), do: unquote(atom)
  end

  def decode(byte) when byte in 0..255 do
    {Bitwise.bsr(byte, 5), Bitwise.band(byte, 0x1F)}
  end

  @doc """
  Returns the class (top 3 bits, `0..7`) of a code.

  Accepts either an atom, a raw byte, or a `{class, detail}` tuple. The convenience
  `{:method, name}` and `{:response, class, detail}` shapes are also accepted.

  ## Examples

      iex> WickCoap.Code.class(:get)
      0

      iex> WickCoap.Code.class(:not_found)
      4

      iex> WickCoap.Code.class({4, 4})
      4
  """
  @spec class(t() | 0..255 | {:method, atom()} | {:response, 0..7, 0..31}) :: 0..7
  def class(byte) when is_integer(byte) and byte in 0..255, do: Bitwise.bsr(byte, 5)
  def class({class, _detail}) when class in 0..7, do: class
  def class({:response, class, _detail}) when class in 0..7, do: class
  def class({:method, _atom}), do: 0
  def class(atom) when is_atom(atom), do: atom |> encode() |> Bitwise.bsr(5)

  @doc "True if the code is in the request-method class (0.xx)."
  @spec method?(t()) :: boolean()
  def method?(:empty), do: false

  def method?(code) do
    case class(code) do
      0 -> true
      _ -> false
    end
  end

  @doc "True if the code is in the success class (2.xx)."
  @spec success?(t()) :: boolean()
  def success?(code), do: class(code) == 2

  @doc "True if the code is in the client-error (4.xx) or server-error (5.xx) classes."
  @spec error?(t()) :: boolean()
  def error?(code) do
    case class(code) do
      4 -> true
      5 -> true
      _ -> false
    end
  end
end

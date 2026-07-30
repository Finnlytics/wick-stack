defmodule WickCoap.Token do
  @moduledoc """
  CoAP Token generator.

  Per [RFC 7252 §5.3.1](https://www.rfc-editor.org/rfc/rfc7252#section-5.3.1) the Token
  matches a response to a request — separately from the Message ID, which matches an ACK
  to its CON. Tokens are 0–8 bytes wide; the request uses any token it wants, the response
  echoes it.

  Wider tokens are harder to guess (RFC 8974 hardens this further with extended tokens, but
  RFC 7252 caps at 8). For a server with many concurrent peers, **8-byte random tokens are
  the safe default** — collision probability across 2^64 values is effectively zero.

  ## Examples

      iex> token = WickCoap.Token.new()
      iex> byte_size(token)
      8

      iex> token = WickCoap.Token.new(2)
      iex> byte_size(token)
      2

      iex> WickCoap.Token.new(0)
      <<>>
  """

  @typedoc "A CoAP token: 0–8 bytes."
  @type t :: binary()

  @doc """
  Generate a fresh random token of the given length (default 8).

  Lengths outside `0..8` raise — RFC 7252 §3 reserves TKL 9..15.
  """
  @spec new(0..8) :: t()
  def new(length \\ 8) when is_integer(length) and length in 0..8 do
    :crypto.strong_rand_bytes(length)
  end
end

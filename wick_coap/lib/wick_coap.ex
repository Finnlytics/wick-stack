defmodule WickCoap do
  @moduledoc """
  CoAP wire format and runtime for Elixir.

  WickCoap implements the [Constrained Application Protocol (CoAP, RFC 7252)](https://www.rfc-editor.org/rfc/rfc7252)
  and its core extensions ([Observe RFC 7641](https://www.rfc-editor.org/rfc/rfc7641),
  [Block-wise transfers RFC 7959](https://www.rfc-editor.org/rfc/rfc7959), and
  [FETCH/PATCH RFC 8132](https://www.rfc-editor.org/rfc/rfc8132)).

  This library is **transport- and application-agnostic**. It contains no LwM2M-specific
  knowledge. For LwM2M see the sibling [Wick](https://github.com/finnlytics/wick) library.

  ## Building blocks

  * `WickCoap.Code` — methods (`:get`, `:post`, …) and response codes (`{:created, 2, 1}`, …)
  * `WickCoap.Option` — typed CoAP options (Uri-Path, Content-Format, Block1/Block2, …)
  * `WickCoap.Message` — full message struct with `encode/1` and `decode/1`

  ## Specifications

  * [RFC 7252](https://www.rfc-editor.org/rfc/rfc7252) — CoAP base
  * [RFC 7641](https://www.rfc-editor.org/rfc/rfc7641) — Observing Resources
  * [RFC 7959](https://www.rfc-editor.org/rfc/rfc7959) — Block-wise transfers
  * [RFC 8132](https://www.rfc-editor.org/rfc/rfc8132) — PATCH, iPATCH, FETCH
  """

  @typedoc "WickCoap library version, as a string."
  @type version :: String.t()

  @doc """
  Returns the running WickCoap library version.

  ## Examples

      iex> is_binary(WickCoap.version())
      true
  """
  @spec version() :: version()
  def version, do: Application.spec(:wick_coap, :vsn) |> to_string()
end

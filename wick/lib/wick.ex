defmodule Wick do
  @moduledoc """
  LwM2M protocol primitives for Elixir.

  Wick is a library of pure protocol primitives for the
  [Lightweight M2M (LwM2M) 1.x](https://www.openmobilealliance.org/release/LightweightM2M/) device
  management protocol. It provides:

  * **Codecs** — `Wick.Codec.SenmlCbor` and friends, for the wire formats LwM2M uses on top of CoAP.
  * **Object Model** — `Wick.Object.Definition`, `Wick.Object.Resource`, `Wick.Object.Registry`
    for the OMA/IPSO/vendor object catalogue.
  * **Types** — `Wick.Path`, `Wick.Value`, and request/response structs for everything that
    crosses the wire.

  Wick deliberately does **not** include:

  * Any CoAP, DTLS, or UDP runtime — those belong in a transport library that consumes Wick.
  * Any registration store, session manager, Queue Mode flush, or other long-lived state — those
    belong in a gateway service that consumes Wick.

  ## Reference implementation

  Wick is informed by [Eclipse Leshan](https://eclipse.dev/leshan/) (Java). Codec correctness is
  validated against Leshan as an oracle — see `tools/leshan_oracle/` and the fixtures under
  `test/fixtures/`.

  ## Specifications

  * [OMA LwM2M Core 1.2](https://www.openmobilealliance.org/release/LightweightM2M/V1_2_1-20221209-A/OMA-TS-LightweightM2M_Core-V1_2_1-20221209-A.pdf)
  * [SenML — RFC 8428](https://www.rfc-editor.org/rfc/rfc8428)
  * [CBOR — RFC 8949](https://www.rfc-editor.org/rfc/rfc8949)
  * [CoAP — RFC 7252](https://www.rfc-editor.org/rfc/rfc7252)
  """

  @typedoc "Wick library version, as a string."
  @type version :: String.t()

  @doc """
  Returns the running Wick library version.

  ## Examples

      iex> is_binary(Wick.version())
      true
  """
  @spec version() :: version()
  def version, do: Application.spec(:wick, :vsn) |> to_string()
end

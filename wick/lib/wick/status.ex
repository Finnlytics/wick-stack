defmodule Wick.Status do
  @moduledoc """
  LwM2M response status codes — symbolic atoms with CoAP code translation.

  LwM2M operates over CoAP and inherits CoAP's response code space ([RFC 7252 §5.9](https://www.rfc-editor.org/rfc/rfc7252#section-5.9)).
  CoAP codes are a `(class, detail)` pair packed into a single byte
  (`class << 5 | detail`), conventionally written as `2.05`, `4.04`, etc.

  Wick exposes statuses as **atoms**: `:content`, `:not_found`, `:bad_request`. Codecs and
  the gateway layer convert to/from CoAP integers at the wire boundary.

  ## Status table

  Per [OMA LwM2M 1.2 §6.4](https://www.openmobilealliance.org/release/LightweightM2M/V1_2_1-20221209-A/OMA-TS-LightweightM2M_Core-V1_2_1-20221209-A.pdf):

  | Atom                            | CoAP   | Class | Meaning                                     |
  |---------------------------------|:------:|:-----:|---------------------------------------------|
  | `:created`                      | 2.01   | success | Resource / Object instance created       |
  | `:deleted`                      | 2.02   | success | Object instance deleted                  |
  | `:changed`                      | 2.04   | success | Write or Execute succeeded               |
  | `:content`                      | 2.05   | success | Read returned a value                    |
  | `:bad_request`                  | 4.00   | client error | Malformed request                   |
  | `:unauthorized`                 | 4.01   | client error | Authentication / authorisation failed |
  | `:not_found`                    | 4.04   | client error | Path does not exist                 |
  | `:method_not_allowed`           | 4.05   | client error | Operation not allowed on this Resource |
  | `:not_acceptable`               | 4.06   | client error | Server cannot produce the requested Content-Format |
  | `:request_entity_too_large`     | 4.13   | client error | Payload too large                   |
  | `:unsupported_content_format`   | 4.15   | client error | Server doesn't understand Content-Format |
  | `:internal_server_error`        | 5.00   | server error | Generic failure                     |
  | `:not_implemented`              | 5.01   | server error | Operation not implemented           |
  | `:service_unavailable`          | 5.03   | server error | Server temporarily unavailable      |

  ## Examples

      iex> Wick.Status.to_coap(:content)
      {2, 5}

      iex> Wick.Status.from_coap({2, 5})
      :content

      iex> Wick.Status.from_coap({4, 3})
      nil

      iex> Wick.Status.success?(:content)
      true

      iex> Wick.Status.success?(:not_found)
      false

      iex> Wick.Status.error?(:not_found)
      true
  """

  @typedoc "An LwM2M response status, as a symbolic atom."
  @type t ::
          :created
          | :deleted
          | :changed
          | :content
          | :bad_request
          | :unauthorized
          | :not_found
          | :method_not_allowed
          | :not_acceptable
          | :request_entity_too_large
          | :unsupported_content_format
          | :internal_server_error
          | :not_implemented
          | :service_unavailable

  @typedoc """
  A CoAP response code split into its class (top 3 bits) and detail (bottom 5 bits).
  """
  @type coap_code :: {0..7, 0..31}

  # Tabular definition: single source of truth for the mapping. Each tuple is
  # `{atom, {class, detail}}`. Order has no semantic meaning.
  @table [
    # 2.xx — Success
    {:created, {2, 1}},
    {:deleted, {2, 2}},
    {:changed, {2, 4}},
    {:content, {2, 5}},
    # 4.xx — Client error
    {:bad_request, {4, 0}},
    {:unauthorized, {4, 1}},
    {:not_found, {4, 4}},
    {:method_not_allowed, {4, 5}},
    {:not_acceptable, {4, 6}},
    {:request_entity_too_large, {4, 13}},
    {:unsupported_content_format, {4, 15}},
    # 5.xx — Server error
    {:internal_server_error, {5, 0}},
    {:not_implemented, {5, 1}},
    {:service_unavailable, {5, 3}}
  ]

  @doc "Convert a status atom to its `{class, detail}` CoAP code pair."
  @spec to_coap(t()) :: coap_code()
  for {atom, code} <- @table do
    def to_coap(unquote(atom)), do: unquote(code)
  end

  @doc """
  Convert a `{class, detail}` CoAP code pair back to a status atom.

  Returns `nil` for codes that are not part of LwM2M's recognised set — the gateway
  layer can decide whether to coerce these into `:internal_server_error` or surface them
  as a CoAP-level transport error.
  """
  @spec from_coap(coap_code()) :: t() | nil
  for {atom, code} <- @table do
    def from_coap(unquote(code)), do: unquote(atom)
  end

  def from_coap({class, detail}) when class in 0..7 and detail in 0..31, do: nil

  @doc "True if the status is in the 2.xx success class."
  @spec success?(t()) :: boolean()
  def success?(status) when is_atom(status) do
    case to_coap(status) do
      {2, _} -> true
      _ -> false
    end
  end

  @doc "True if the status is in the 4.xx (client) or 5.xx (server) error classes."
  @spec error?(t()) :: boolean()
  def error?(status) when is_atom(status) do
    case to_coap(status) do
      {class, _} when class in [4, 5] -> true
      _ -> false
    end
  end

  @doc "All recognised status atoms, sorted alphabetically for stable iteration."
  @spec all() :: [t()]
  def all, do: @table |> Enum.map(&elem(&1, 0)) |> Enum.sort()
end

defmodule Wick.Test.CoapRegistrationHandler do
  @moduledoc """
  Test adapter that wires `Wick.Registration.Server` (pure LwM2M logic) onto the
  `WickCoap.Handler` behaviour (CoAP transport).

  Responsibilities:

  * Parse incoming CoAP requests into the `%Server.Request{} 
    shape `Wick.Registration.Server.handle/2` expects.
  * Translate the returned `%Server.Response{}` into a CoAP message, including
    `Location-Path` options for Register and a CoAP code drawn from the response atom.
  * Serialise access to the store with an Agent so multiple inbound exchanges interleave
    safely.

  The Agent pid is passed via `handler_state` from `WickCoap.Endpoint.start_link/1`.

  See `test/wick/integration/registration_e2e_test.exs` for usage.
  """

  @behaviour WickCoap.Handler

  alias Wick.Registration.Server
  alias Wick.Registration.Store
  alias WickCoap.Handler
  alias WickCoap.Message
  alias WickCoap.Option

  @core_link_format 40

  @impl WickCoap.Handler
  def handle_request(%Message{} = request, peer, %{store: store_agent}) do
    parsed = %Server.Request{
      method: coap_method(request.code),
      path: Handler.uri_path(request.options),
      query: parse_query(request.options),
      payload: request.payload || "",
      peer: peer,
      now: System.monotonic_time(:millisecond)
    }

    response =
      Agent.get_and_update(store_agent, fn store ->
        {response, store} = Server.handle(parsed, store)
        {response, store}
      end)

    {:reply, to_coap(response, request)}
  end

  defp coap_method(:get), do: :get
  defp coap_method(:post), do: :post
  defp coap_method(:put), do: :put
  defp coap_method(:delete), do: :delete

  defp parse_query(options) do
    options
    |> Enum.filter(&(&1.number == 15))
    |> Enum.map(fn %Option{value: raw} ->
      case String.split(raw, "=", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, nil}
      end
    end)
  end

  defp to_coap(%Server.Response{} = response, %Message{} = request) do
    %Message{
      type: :ack,
      code: response.code,
      message_id: request.message_id,
      token: request.token,
      options: location_options(response.location_path),
      payload: ""
    }
    |> maybe_add_diagnostic(response.diagnostic)
  end

  defp location_options(nil), do: []

  defp location_options(segments) when is_list(segments) do
    # Location-Path is option number 8 (RFC 7252 §5.10.7). One option per segment.
    Enum.map(segments, &Option.new(8, &1))
  end

  defp maybe_add_diagnostic(message, nil), do: message

  defp maybe_add_diagnostic(message, diagnostic) when is_binary(diagnostic) do
    %{message | payload: diagnostic}
  end

  @doc "Convenience for test setup blocks — start an Agent holding an empty store."
  def start_store do
    Agent.start_link(fn -> Store.new() end)
  end

  @doc "Content-Format integer for the CoRE Link Format registration payload."
  def core_link_content_format, do: @core_link_format
end

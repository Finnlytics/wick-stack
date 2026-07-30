defmodule WickDemoClient.Coap do
  @moduledoc """
  The adapter between Wick's transport-agnostic types and `WickCoap`'s messages.

  Wick deliberately ships no CoAP dependency (see Wick ADR 0001 and 0004), so something has
  to sit in the middle. That something is this module, and it is small on purpose:
  `Wick.Wire.to_coap_options/1` already reduces a request to `{option_number, value}` pairs,
  so the adapter is a `map` over an option constructor rather than a per-operation
  translation table.

  Everything in `WickDemoClient` that talks CoAP goes through here — the Registrar, the
  inbound request handler, the uplink sender, and the bootstrap client. That is the whole
  reason it exists: four call sites, one translation.
  """

  alias Wick.Response
  alias Wick.Status
  alias Wick.Wire
  alias WickCoap.Code
  alias WickCoap.Endpoint
  alias WickCoap.Message
  alias WickCoap.Option

  @default_timeout 5_000

  @typedoc "A peer address — `{ip, port}`."
  @type peer :: {:inet.ip_address(), :inet.port_number()}

  @doc """
  Build a Confirmable CoAP request from a `Wick.Wire`.

  Message ID and Token are left for the Endpoint to allocate.
  """
  @spec to_message(Wire.t()) :: Message.t()
  def to_message(%Wire{} = wire) do
    %Message{
      type: :con,
      code: wire.method,
      message_id: 0,
      token: <<>>,
      options: to_options(Wire.to_coap_options(wire)),
      payload: wire.payload
    }
  end

  @doc """
  Send a `Wick.Wire` and wait for the reply, returning a decoded `Wick.Response`.

  Returns `{:error, reason}` on a transport failure, or `{:error, %Wick.Error{}}` if the peer
  answered with a CoAP code that is not an LwM2M status.
  """
  @spec request(GenServer.server(), peer(), Wire.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def request(endpoint, peer, %Wire{} = wire, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, reply} <- Endpoint.request(endpoint, peer, to_message(wire), timeout: timeout),
         {:ok, response_wire} <- to_response_wire(reply) do
      {:ok, Response.from_wire(response_wire)}
    end
  end

  @doc """
  Turn a raw CoAP reply into a `Wick.Wire.Response`.

  `WickCoap` exposes codes as atoms, so this converts back through
  `WickCoap.Code.encode/1` — the packed byte is the form `Wick.Wire.Response.parse/3` takes.
  """
  @spec to_response_wire(Message.t()) :: {:ok, Wire.Response.t()} | {:error, Wick.Error.t()}
  def to_response_wire(%Message{} = message) do
    Wire.Response.parse(
      Code.encode(message.code),
      from_options(message.options),
      message.payload || ""
    )
  end

  @doc """
  Turn an inbound CoAP request into a `Wick.Wire`, ready for `Wick.Request.from_wire/1` or
  `Wick.Bootstrap.from_wire/1`.
  """
  @spec to_request_wire(Message.t()) :: {:ok, Wire.t()} | {:error, Wick.Error.t()}
  def to_request_wire(%Message{} = message) do
    Wire.parse(message.code, from_options(message.options), message.payload || "")
  end

  @doc """
  Build a piggy-backed ACK carrying a `Wick.Response`, echoing the request's Message ID and
  Token.
  """
  @spec reply(Response.t(), Message.t()) :: Message.t()
  def reply(%Response{} = response, %Message{} = request) do
    wire = Response.to_wire(response)

    %Message{
      type: :ack,
      code: Status.to_coap(wire.status),
      message_id: request.message_id,
      token: request.token,
      options: to_options(Wire.Response.to_coap_options(wire)),
      payload: wire.payload
    }
  end

  @doc """
  Build a Non-confirmable notification template for `WickCoap.Endpoint.notify_observers/3`.

  The Endpoint overrides type, Message ID, Token, and the Observe option — the caller only
  supplies the code, Content-Format, and payload.
  """
  @spec notification(non_neg_integer(), binary()) :: Message.t()
  def notification(content_format, payload) do
    %Message{
      type: :non,
      code: :content,
      message_id: 0,
      token: <<>>,
      options: [Option.from_uint(Wire.content_format_option(), content_format)],
      payload: payload
    }
  end

  defp to_options(pairs), do: Enum.map(pairs, fn {number, value} -> Option.new(number, value) end)

  defp from_options(options), do: Enum.map(options, &{&1.number, &1.value})
end

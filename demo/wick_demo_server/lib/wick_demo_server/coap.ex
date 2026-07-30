defmodule WickDemoServer.Coap do
  @moduledoc """
  The adapter between Wick's transport-agnostic types and `WickCoap`'s messages.

  Same job and same shape as `WickDemoClient.Coap` — the two demos are separate Mix projects,
  so the module is duplicated rather than shared. It is small enough (`Wick.Wire` has already
  reduced a request to `{option_number, value}` pairs) that a third library to hold it would
  cost more than it saves.
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

  @doc "Build a Confirmable CoAP request from a `Wick.Wire`."
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

  @doc "Send a `Wick.Wire` and wait for the reply, returning a decoded `Wick.Response`."
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
  Establish an Observe relation, returning the handle plus the decoded initial response.

  The handle is opaque and is what `WickDemoServer.Observations` keys the relation by.
  """
  @spec observe(GenServer.server(), peer(), Wire.t(), keyword()) ::
          {:ok, term(), Response.t(), non_neg_integer() | nil} | {:error, term()}
  def observe(endpoint, peer, %Wire{} = wire, opts \\ []) do
    coap_opts = Keyword.take(opts, [:notify, :timeout])

    with {:ok, handle, reply} <- Endpoint.observe(endpoint, peer, to_message(wire), coap_opts),
         {:ok, response_wire} <- to_response_wire(reply) do
      {:ok, handle, Response.from_wire(response_wire), response_wire.observe_seq}
    end
  end

  @doc "Turn a raw CoAP reply into a `Wick.Wire.Response`."
  @spec to_response_wire(Message.t()) :: {:ok, Wire.Response.t()} | {:error, Wick.Error.t()}
  def to_response_wire(%Message{} = message) do
    Wire.Response.parse(
      Code.encode(message.code),
      from_options(message.options),
      message.payload || ""
    )
  end

  @doc "Turn an inbound CoAP request into a `Wick.Wire`."
  @spec to_request_wire(Message.t()) :: {:ok, Wire.t()} | {:error, Wick.Error.t()}
  def to_request_wire(%Message{} = message) do
    Wire.parse(message.code, from_options(message.options), message.payload || "")
  end

  @doc "Build a piggy-backed ACK carrying a `Wick.Response`."
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

  @doc "Render a peer address for logs."
  @spec format_peer(term()) :: String.t()
  def format_peer({{a, b, c, d}, port}), do: "#{a}.#{b}.#{c}.#{d}:#{port}"
  def format_peer({ip, port}), do: "#{inspect(ip)}:#{port}"
  def format_peer(other), do: inspect(other)

  defp to_options(pairs), do: Enum.map(pairs, fn {number, value} -> Option.new(number, value) end)

  defp from_options(options), do: Enum.map(options, &{&1.number, &1.value})
end

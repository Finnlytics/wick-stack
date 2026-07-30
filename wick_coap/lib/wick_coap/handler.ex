defmodule WickCoap.Handler do
  @moduledoc """
  Behaviour for handling inbound CoAP requests on a `WickCoap.Endpoint`.

  An Endpoint dispatches every well-formed inbound **request** (i.e., a message whose
  `code` is in the 0.xx method class) to its configured handler module by calling
  `c:handle_request/3`. The handler decides what to do with the request and returns one
  of three outcomes:

  * `{:reply, message}` — the Endpoint sends `message` back to the peer as a piggy-backed
    ACK (for CON requests) or a NON response (for NON requests). The Endpoint copies the
    request's token onto the reply automatically; the handler is responsible only for the
    code, options, and payload.
  * `:ack` — the Endpoint sends an empty ACK. Use this when you want to acknowledge
    receipt without producing a response (e.g., for one-way messaging).
  * `:ignore` — the Endpoint sends nothing.

  Responses, ACKs, and RSTs that arrive at the Endpoint are *not* dispatched to the
  handler; they're matched against in-flight outbound exchanges via Token.

  ## Example

      defmodule HelloHandler do
        @behaviour WickCoap.Handler

        @impl true
        def handle_request(%WickCoap.Message{code: :get, options: opts}, _peer, _state) do
          payload =
            case WickCoap.Handler.uri_path(opts) do
              ["hello"] -> "world"
              other -> "echo: \#{inspect(other)}"
            end

          response = %WickCoap.Message{
            type: :ack,
            code: :content,
            message_id: 0,
            token: <<>>,
            options: [WickCoap.Option.from_uint(12, 0)],
            payload: payload
          }

          {:reply, response}
        end
      end
  """

  alias WickCoap.Message
  alias WickCoap.Option

  @typedoc "Opaque peer identifier — typically `{ip, port}` for UDP CoAP."
  @type peer :: term()

  @typedoc "Handler-level outcome of one inbound request."
  @type outcome :: {:reply, Message.t()} | :ack | :ignore

  @doc """
  Decide what to do with an inbound CoAP request.

  Called from the Endpoint's process. Should be cheap — long-running work (e.g. database
  reads, downstream calls) should happen in spawned worker processes, with the response
  delivered via `WickCoap.Endpoint.respond/3` (separate-response pattern).

  The third argument is opaque consumer state — passed through unchanged from the
  Endpoint's `:handler_state` option.
  """
  @callback handle_request(Message.t(), peer(), state :: term()) :: outcome()

  @doc """
  Convenience: extract the Uri-Path option values (number 11) from a message's options
  list, in order, as a list of strings.

  ## Examples

      iex> opts = [
      ...>   WickCoap.Option.new(11, "3"),
      ...>   WickCoap.Option.new(11, "0"),
      ...>   WickCoap.Option.new(11, "9")
      ...> ]
      iex> WickCoap.Handler.uri_path(opts)
      ["3", "0", "9"]
  """
  @spec uri_path([Option.t()]) :: [String.t()]
  def uri_path(options) when is_list(options) do
    options
    |> Enum.filter(&(&1.number == 11))
    |> Enum.map(& &1.value)
  end

  @doc """
  Convenience: extract the Content-Format option (number 12) as an unsigned integer, or
  `nil` if no Content-Format is present.

  ## Examples

      iex> opts = [WickCoap.Option.from_uint(12, 112)]
      iex> WickCoap.Handler.content_format(opts)
      112

      iex> WickCoap.Handler.content_format([])
      nil
  """
  @spec content_format([Option.t()]) :: non_neg_integer() | nil
  def content_format(options) when is_list(options) do
    case Enum.find(options, &(&1.number == 12)) do
      nil -> nil
      option -> Option.value_as_uint(option)
    end
  end
end

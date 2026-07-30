defmodule WickCoap.Exchange do
  @moduledoc """
  An in-flight CoAP request/response exchange.

  Per [RFC 7252 §4.4 / §5](https://www.rfc-editor.org/rfc/rfc7252) every request a CoAP
  client sends is identified by its **Token** at the request/response layer (independent
  of the Message ID, which lives at the messaging layer). The matching response carries
  the same Token. An Exchange tracks one such pairing — outbound request, expected
  response — including the retransmission state for the underlying CON.

  ## Roles

  An Exchange represents either side of the wire:

  * **Client side** — `:outbound` exchange tracking a request we sent, awaiting a response.
  * **Server side** — `:inbound` exchange tracking a request we received, awaiting our
    application to produce a response.

  ## Peer

  The peer is opaque to this module — typically `{ip, port}` for UDP CoAP but anything
  hashable works. Pass through what your transport gives you.

  ## Lifecycle

      # Client side: starting a request
      {:ok, exchange} = WickCoap.Exchange.start_outbound(
        peer: {{127, 0, 0, 1}, 5683},
        message: request_message,
        now: System.monotonic_time(:millisecond)
      )

      # later, when the response arrives
      {:matched, exchange} = WickCoap.Exchange.match_response(exchange, response_message)
  """

  alias WickCoap.Message
  alias WickCoap.Retransmit

  @typedoc "Which side of the wire this exchange is on."
  @type role :: :outbound | :inbound

  @typedoc "Lifecycle state of the exchange."
  @type state :: :pending | :acked | :completed | :expired

  @typedoc "An opaque peer identifier — typically `{ip, port}` for UDP CoAP."
  @type peer :: term()

  @typedoc "An in-flight exchange."
  @type t :: %__MODULE__{
          role: role(),
          peer: peer(),
          message: Message.t(),
          state: state(),
          retransmit: Retransmit.t() | nil,
          response: Message.t() | nil
        }

  @enforce_keys [:role, :peer, :message, :state]
  defstruct [:role, :peer, :message, :state, :retransmit, :response]

  @doc """
  Start a new outbound exchange — we are about to send `message` to `peer`.

  Returns the exchange in `:pending` state. If the message is confirmable (`type: :con`),
  the returned exchange carries a fresh `Retransmit` state initialised at `:now`. For
  `:non` / `:ack` / `:rst` messages, the retransmit state is `nil` since those types are
  not retransmitted.

  ## Required options

  * `:peer` — opaque peer identifier
  * `:message` — `t:WickCoap.Message.t/0`, fully constructed (token and message_id set)
  * `:now` — current monotonic time in milliseconds (only required for CON messages but
    accepted for all)

  ## Optional options

  Forwarded to `WickCoap.Retransmit.new/1` when the message type is `:con`:

  * `:ack_timeout`
  * `:ack_random_factor`
  * `:max_retransmit`
  """
  @spec start_outbound(keyword()) :: t()
  def start_outbound(opts) do
    peer = Keyword.fetch!(opts, :peer)
    message = Keyword.fetch!(opts, :message)

    retransmit =
      case message.type do
        :con -> Retransmit.new(opts)
        _ -> nil
      end

    %__MODULE__{
      role: :outbound,
      peer: peer,
      message: message,
      state: :pending,
      retransmit: retransmit
    }
  end

  @doc """
  Start a new inbound exchange — we just received `message` from `peer`.

  Returned in `:pending` state. The application is expected to produce a response, after
  which the caller marks the exchange complete.
  """
  @spec start_inbound(peer(), Message.t()) :: t()
  def start_inbound(peer, %Message{} = message) do
    %__MODULE__{
      role: :inbound,
      peer: peer,
      message: message,
      state: :pending
    }
  end

  @doc """
  Match an inbound message against an outbound exchange. The match is by **Token** — the
  message_id correspondence is handled at the messaging layer (`Wick.Coap.Dedup`,
  `WickCoap.Retransmit`).

  Returns:

  * `{:matched, t/0}` — token matched, response stored, state moves to `:completed`
  * `{:no_match, t/0}` — token didn't match; exchange unchanged
  """
  @spec match_response(t(), Message.t()) :: {:matched | :no_match, t()}
  def match_response(%__MODULE__{role: :outbound, message: req} = exchange, %Message{} = response) do
    if req.token == response.token do
      {:matched, %__MODULE__{exchange | state: :completed, response: response}}
    else
      {:no_match, exchange}
    end
  end

  @doc """
  Mark a CON exchange as acked when a separate ACK arrives (no piggy-backed response).

  The exchange remains in flight at the request/response layer — we got the ACK, but
  haven't seen the response yet — so retransmission stops but `state` becomes `:acked`.
  """
  @spec ack(t()) :: t()
  def ack(%__MODULE__{} = exchange) do
    %__MODULE__{exchange | state: :acked, retransmit: nil}
  end

  @doc "Mark the exchange as expired (`MAX_RETRANSMIT` exhausted, server timeout, etc.)."
  @spec expire(t()) :: t()
  def expire(%__MODULE__{} = exchange) do
    %__MODULE__{exchange | state: :expired}
  end

  @doc "True if the exchange is still awaiting a response or ACK."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{state: :pending}), do: true
  def pending?(%__MODULE__{}), do: false

  @doc "True if the exchange is finished (matched or expired)."
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{state: state}), do: state in [:completed, :expired]

  @doc "The lookup key for an exchange — `{peer, token}`."
  @spec key(t()) :: {peer(), binary()}
  def key(%__MODULE__{peer: peer, message: %Message{token: token}}), do: {peer, token}
end

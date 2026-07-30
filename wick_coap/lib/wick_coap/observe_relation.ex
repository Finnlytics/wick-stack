defmodule WickCoap.ObserveRelation do
  @moduledoc """
  A single server-side Observe relation per [RFC 7641 §4.1](https://www.rfc-editor.org/rfc/rfc7641#section-4.1).

  When a client sends a GET with `Observe: 0` (register), the server (us) creates one of
  these. Successive notifications carry the same Token as the original request, an
  incrementing sequence number, and (typically) NON type messages. The relation lives
  until the client deregisters or the application drops it.

  Wick stores relations on the Endpoint, indexed by `{peer, uri_path_segments}`. The
  combination is enough to address "this client wants this resource" — a client may
  observe several resources concurrently via different paths; one resource may be
  observed by many clients.

  ## Field meaning

  | Field             | Type                          | Notes |
  |-------------------|-------------------------------|-------|
  | `:peer`           | opaque (typically `{ip, port}`) | Who's observing |
  | `:token`          | `binary()` (1–8 bytes)         | Echoed on every notification |
  | `:path`           | `[binary()]`                   | Uri-Path segments — what they're observing |
  | `:next_sequence`  | `0..2^24-1`                    | The next notification's Observe value |
  | `:type`           | `:non` \\| `:con`             | Outbound notification type |
  | `:registered_at`  | `integer()` (monotonic ms)     | When the relation was first established |
  """

  alias WickCoap.Observe

  @typedoc "An Observe relation."
  @type t :: %__MODULE__{
          peer: term(),
          token: binary(),
          path: [binary()],
          next_sequence: Observe.sequence(),
          type: :non | :con,
          registered_at: integer()
        }

  @enforce_keys [:peer, :token, :path, :registered_at]
  defstruct [
    :peer,
    :token,
    :path,
    :registered_at,
    next_sequence: 0,
    type: :non
  ]

  @doc """
  Allocate a sequence number from the relation, returning the value to attach to the
  next notification and the relation with its counter advanced.
  """
  @spec take_sequence(t()) :: {Observe.sequence(), t()}
  def take_sequence(%__MODULE__{next_sequence: current} = relation) do
    {current, %{relation | next_sequence: Observe.next_sequence(current)}}
  end

  @doc "Lookup key for the relation in the Endpoint's relation map."
  @spec key(t()) :: {term(), [binary()]}
  def key(%__MODULE__{peer: peer, path: path}), do: {peer, path}
end

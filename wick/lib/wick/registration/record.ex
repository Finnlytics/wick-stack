defmodule Wick.Registration.Record do
  @moduledoc """
  One stored registration. `location_id` is server-assigned; `endpoint_name` is the
  device's globally-unique identity (LwM2M `ep` parameter).

  Time fields are plain integers in monotonic milliseconds, per ADR 0003.
  """

  alias Wick.CoreLink

  @type binding :: String.t() | nil

  @type t :: %__MODULE__{
          location_id: String.t() | nil,
          endpoint_name: String.t(),
          lifetime: pos_integer(),
          lwm2m_version: String.t(),
          binding: binding(),
          queue_mode: boolean(),
          sms_number: String.t() | nil,
          profile_id: String.t() | nil,
          objects: [CoreLink.Link.t()],
          peer: term() | nil,
          created_at: integer(),
          updated_at: integer()
        }

  @enforce_keys [:endpoint_name, :lifetime, :created_at, :updated_at]
  defstruct [
    :endpoint_name,
    :lifetime,
    :created_at,
    :updated_at,
    :location_id,
    :binding,
    :sms_number,
    :profile_id,
    :peer,
    lwm2m_version: "1.2",
    queue_mode: false,
    objects: []
  ]
end

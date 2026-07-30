defmodule Wick.Object.Resource do
  @moduledoc """
  A single Resource definition from a parsed DDF Object.

  Each LwM2M Object exposes a fixed set of Resources, identified by integer Resource IDs.
  The DDF (Data Definition Format) XML file for an Object enumerates them with their type,
  multiplicity, mandatory/optional status, allowed operations, units, and human-readable
  documentation.

  ## Field meaning

  | Field                 | Source XML element / attribute             |
  |-----------------------|--------------------------------------------|
  | `:resource_id`        | `<Item ID="…">` attribute                  |
  | `:name`               | `<Name>`                                   |
  | `:description`        | `<Description>` (CDATA contents)           |
  | `:type`               | `<Type>` — see `t:value_type/0`            |
  | `:operations`         | `<Operations>` — see `t:operation/0`       |
  | `:multiple_instances` | `<MultipleInstances>` — `:single`/`:multiple` |
  | `:mandatory`          | `<Mandatory>` — `:mandatory`/`:optional`   |
  | `:range_enumeration`  | `<RangeEnumeration>` (free text, may be `nil`) |
  | `:units`              | `<Units>` (free text, may be `nil`)        |

  ## Examples

      iex> r = %Wick.Object.Resource{
      ...>   resource_id: 0,
      ...>   name: "Latitude",
      ...>   description: "Decimal latitude",
      ...>   type: :float,
      ...>   operations: [:read],
      ...>   multiple_instances: :single,
      ...>   mandatory: :mandatory,
      ...>   range_enumeration: nil,
      ...>   units: "lat"
      ...> }
      iex> Wick.Object.Resource.readable?(r)
      true
      iex> Wick.Object.Resource.writable?(r)
      false
  """

  @typedoc "An LwM2M Resource value type (per OMA LwM2M 1.2 §7.4)."
  @type value_type ::
          :string
          | :integer
          | :unsigned_integer
          | :float
          | :boolean
          | :opaque
          | :time
          | :objlnk
          | :corelnk
          | :none

  @typedoc "An operation a server may perform on this Resource."
  @type operation :: :read | :write | :execute

  @typedoc "Whether the Resource holds zero-or-one (`:single`) or many (`:multiple`) instances."
  @type multiplicity :: :single | :multiple

  @typedoc "Whether the Resource is mandatory or optional within its Object."
  @type requirement :: :mandatory | :optional

  @typedoc "A parsed Resource definition."
  @type t :: %__MODULE__{
          resource_id: Wick.Path.id(),
          name: String.t(),
          description: String.t(),
          type: value_type(),
          operations: [operation()],
          multiple_instances: multiplicity(),
          mandatory: requirement(),
          range_enumeration: String.t() | nil,
          units: String.t() | nil
        }

  @enforce_keys [:resource_id, :name, :type, :operations, :multiple_instances, :mandatory]
  defstruct [
    :resource_id,
    :name,
    :description,
    :type,
    :operations,
    :multiple_instances,
    :mandatory,
    :range_enumeration,
    :units
  ]

  @doc "True if the Resource grants the Read operation."
  @spec readable?(t()) :: boolean()
  def readable?(%__MODULE__{operations: ops}), do: :read in ops

  @doc "True if the Resource grants the Write operation."
  @spec writable?(t()) :: boolean()
  def writable?(%__MODULE__{operations: ops}), do: :write in ops

  @doc "True if the Resource is Execute-only (no value, server invokes it)."
  @spec executable?(t()) :: boolean()
  def executable?(%__MODULE__{operations: ops}), do: :execute in ops

  @doc "True if the Resource holds multiple instances (`/oid/iid/rid/0`, `/oid/iid/rid/1`, …)."
  @spec multi_instance?(t()) :: boolean()
  def multi_instance?(%__MODULE__{multiple_instances: :multiple}), do: true
  def multi_instance?(%__MODULE__{}), do: false
end

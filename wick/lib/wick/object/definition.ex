defmodule Wick.Object.Definition do
  @moduledoc """
  A parsed LwM2M Object definition from a DDF XML file.

  An Object Definition declares the wire-level shape of one LwM2M Object: its ID, version,
  multiplicity (single-instance vs multi-instance Object), mandatoriness, and the full set
  of `Wick.Object.Resource` definitions it exposes.

  Object Definitions are produced by `Wick.Object.Ddf.parse/1`. The Object Registry
  (a future module) holds a collection of these and answers lookups like
  *"what does Resource 9 on Object 3 look like?"*.

  ## Field meaning

  | Field                 | Source XML element                                 |
  |-----------------------|----------------------------------------------------|
  | `:object_id`          | `<ObjectID>`                                       |
  | `:name`               | `<Name>`                                           |
  | `:description`        | `<Description1>` (CDATA contents)                  |
  | `:urn`                | `<ObjectURN>` (e.g. `urn:oma:lwm2m:oma:6`)         |
  | `:lwm2m_version`      | `<LWM2MVersion>` (e.g. `1.0`, `1.1`, `1.2`)        |
  | `:object_version`     | `<ObjectVersion>` (Object's own version)           |
  | `:multiple_instances` | `<MultipleInstances>` — `:single` / `:multiple`    |
  | `:mandatory`          | `<Mandatory>` — `:mandatory` / `:optional`         |
  | `:resources`          | `<Resources>` / `<Item>` list, ordered by `ID`     |

  ## Examples

      iex> obj = %Wick.Object.Definition{
      ...>   object_id: 6,
      ...>   name: "Location",
      ...>   description: "Location telemetry",
      ...>   urn: "urn:oma:lwm2m:oma:6",
      ...>   lwm2m_version: "1.0",
      ...>   object_version: "1.0",
      ...>   multiple_instances: :single,
      ...>   mandatory: :optional,
      ...>   resources: [
      ...>     %Wick.Object.Resource{
      ...>       resource_id: 0, name: "Latitude", type: :float,
      ...>       operations: [:read], multiple_instances: :single, mandatory: :mandatory
      ...>     }
      ...>   ]
      ...> }
      iex> Wick.Object.Definition.find_resource(obj, 0).name
      "Latitude"
      iex> Wick.Object.Definition.find_resource(obj, 999)
      nil
  """

  alias Wick.Object.Resource

  @typedoc "A parsed Object definition."
  @type t :: %__MODULE__{
          object_id: Wick.Path.id(),
          name: String.t(),
          description: String.t(),
          urn: String.t(),
          lwm2m_version: String.t(),
          object_version: String.t(),
          multiple_instances: Resource.multiplicity(),
          mandatory: Resource.requirement(),
          resources: [Resource.t()]
        }

  @enforce_keys [
    :object_id,
    :name,
    :multiple_instances,
    :mandatory,
    :resources
  ]
  defstruct [
    :object_id,
    :name,
    :description,
    :urn,
    :lwm2m_version,
    :object_version,
    :multiple_instances,
    :mandatory,
    :resources
  ]

  @doc """
  Look up a `Wick.Object.Resource` by its Resource ID. Returns `nil` if not found.
  """
  @spec find_resource(t(), Wick.Path.id()) :: Resource.t() | nil
  def find_resource(%__MODULE__{resources: resources}, resource_id) do
    Enum.find(resources, &(&1.resource_id == resource_id))
  end
end

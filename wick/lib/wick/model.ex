defmodule Wick.Model do
  @moduledoc """
  Resolving a Resource path to the LwM2M type it is declared to hold.

  Wick has an Object model — `Wick.Object.Registry` and the DDF it is loaded from — and it
  has values, stored in a `Wick.Object.Tree` as `{type, value}` pairs. This module is the
  seam between them: given a path, what type *should* the value at that path be?

  That question has no answer on the wire for two of the four LwM2M formats. TLV and LwM2M
  CBOR are not self-describing — four bytes of TLV value could be an Integer, a Float or a
  Time, and only the Object definition says which. SenML is partially self-describing, so it
  can guess, but it still cannot tell an Integer from an Unsigned Integer from a Time, nor a
  String from a CoRE Link.

  ## No model is a valid model

  Every function here accepts `nil`, meaning "no model available", and returns `nil` for the
  type. Callers are expected to fall back to inferring from the wire shape — which is what
  `Wick.Object.Tree` does today, and remains the default. Supplying a model is an
  improvement, never a requirement, so a consumer with no DDF for a vendor Object keeps
  working.

  ## What counts as a model

  Three shapes, checked in this order:

  * `nil` — no model.
  * a `Wick.Object.Registry` — the common case, loaded from DDF.
  * a 1-arity function `(Wick.Path.t() -> Wick.Value.type() | nil)` — an escape hatch for
    consumers who keep their model somewhere else (a database, a config file, a versioned
    store) and do not want to materialise a `Registry` to answer one question.

  The function form takes the whole path rather than `{object_id, resource_id}` so that a
  resolver can be Instance-aware or version-aware without another breaking change. Object
  version support is not built in yet — see the version-aware model lookup issue.

  ## Examples

      iex> definition = %Wick.Object.Definition{
      ...>   object_id: 3,
      ...>   name: "Device",
      ...>   multiple_instances: :single,
      ...>   mandatory: :mandatory,
      ...>   resources: [
      ...>     %Wick.Object.Resource{
      ...>       resource_id: 13, name: "Current Time", type: :time,
      ...>       operations: [:read], multiple_instances: :single, mandatory: :optional
      ...>     }
      ...>   ]
      ...> }
      iex> registry = Wick.Object.Registry.from_definitions([definition])
      iex> {:ok, path} = Wick.Path.parse("/3/0/13")
      iex> Wick.Model.resource_type(registry, path)
      :time

      iex> {:ok, path} = Wick.Path.parse("/3/0/13")
      iex> Wick.Model.resource_type(nil, path)
      nil
  """

  alias Wick.Object.Registry
  alias Wick.Object.Resource
  alias Wick.Path

  @typedoc """
  A source of Resource type declarations.

  See the module documentation for the three accepted shapes.
  """
  @type t :: Registry.t() | (Path.t() -> Wick.Value.type() | nil) | nil

  @doc """
  The LwM2M type declared for the Resource at `path`, or `nil` when unknown.

  `nil` is returned when there is no model, when the model has no definition for the Object,
  when the Object has no such Resource, or when the path does not identify a Resource at all
  (an Object or Object Instance path has no single type).

  A Resource Instance path resolves through its parent Resource — `/3/0/6/0` and `/3/0/6/1`
  both answer with the type declared for Resource 6 — because multi-instance Resources
  declare one type for every Instance.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0")
      iex> Wick.Model.resource_type(nil, path)
      nil
  """
  @spec resource_type(t(), Path.t()) :: Wick.Value.type() | nil
  def resource_type(nil, %Path{}), do: nil

  def resource_type(_model, %Path{resource_id: nil}), do: nil

  def resource_type(%Registry{} = registry, %Path{} = path) do
    case Registry.lookup_resource(registry, path.object_id, path.resource_id) do
      %Resource{type: type} -> type
      nil -> nil
    end
  end

  def resource_type(resolver, %Path{} = path) when is_function(resolver, 1) do
    resolver.(path)
  end

  @doc """
  True when `term` is something `resource_type/2` accepts.

  ## Examples

      iex> Wick.Model.model?(nil)
      true

      iex> Wick.Model.model?(Wick.Object.Registry.new())
      true

      iex> Wick.Model.model?(fn _path -> :integer end)
      true

      iex> Wick.Model.model?(:not_a_model)
      false
  """
  @spec model?(term()) :: boolean()
  def model?(nil), do: true
  def model?(%Registry{}), do: true
  def model?(term) when is_function(term, 1), do: true
  def model?(_term), do: false
end

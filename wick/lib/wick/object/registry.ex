defmodule Wick.Object.Registry do
  @moduledoc """
  An in-memory registry of `Wick.Object.Definition` keyed by Object ID.

  Used by codec consumers (and a future Object lookup layer) to answer:

  * "What does Object 3 look like?" — via `lookup/2`.
  * "What's the type of Resource 9 on Object 3?" — via `lookup_resource/3`.

  ## Design

  The registry is **a plain immutable struct** holding a `Map.t/0` of
  `id => Wick.Object.Definition`. There is no GenServer, no ETS, no lifecycle, and no
  global state.

  Consumers who need mutable shared state should wrap a registry in their own GenServer or
  Agent — Wick stays out of process management. Consumers who want O(1) lookup at scale
  can swap to a custom backend (the data is just a struct of definitions; build whatever
  storage you want from it).

  This shape was chosen over a GenServer-owned ETS table because:

  * **No startup dance.** A library consumer doesn't need to add a child to their
    supervision tree just to look up a Resource definition.
  * **No naming conflicts.** Each registry is just a value; you can hold any number of
    them simultaneously (handy in tests, multi-tenant setups, or A/B-ing Object versions).
  * **Easy to test.** No process state, no `setup` / `on_exit` to reset.

  Lookups are `O(log n)` over Erlang `Map`. For the LwM2M-OMNA standard set (≈ 60 Objects)
  this is operationally indistinguishable from `O(1)`.

  ## Examples

      iex> registry = Wick.Object.Registry.new()
      iex> Wick.Object.Registry.size(registry)
      0

      iex> registry = Wick.Object.Registry.standard()
      iex> Wick.Object.Registry.object_ids(registry)
      [0, 1, 2, 3, 4, 5, 6, 7, 21, 3303]

      iex> registry = Wick.Object.Registry.standard()
      iex> Wick.Object.Registry.lookup(registry, 6).name
      "Location"
      iex> Wick.Object.Registry.lookup_resource(registry, 6, 0).name
      "Latitude"
      iex> Wick.Object.Registry.lookup_resource(registry, 6, 999)
      nil
  """

  alias Wick.Error
  alias Wick.Object.Ddf
  alias Wick.Object.Definition
  alias Wick.Object.Resource

  @typedoc "An object registry."
  @type t :: %__MODULE__{
          objects: %{optional(Wick.Path.id()) => Definition.t()}
        }

  defstruct objects: %{}

  @doc "Build an empty registry."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # The bundled catalogue, parsed at compile time and embedded in the BEAM. Reading and
  # parsing XML on every call — or worse, once per request — would be a poor default for
  # something this static, and `Application.app_dir/2` is unavailable in an escript or a
  # release that strips priv. `@external_resource` makes a change to any DDF file recompile
  # this module.
  @ddf_dir Path.expand("../../../priv/ddf", __DIR__)

  @ddf_files @ddf_dir
             |> File.ls!()
             |> Enum.filter(&String.ends_with?(&1, ".xml"))
             |> Enum.sort()
             |> Enum.map(&Path.join(@ddf_dir, &1))

  for file <- @ddf_files do
    @external_resource file
  end

  @standard_objects Map.new(@ddf_files, fn file ->
                      {:ok, definition} = Ddf.parse(File.read!(file))
                      {definition.object_id, definition}
                    end)

  @doc """
  A registry preloaded with the Object definitions Wick bundles.

  The catalogue is vendored from the [OMNA LwM2M
  Registry](https://github.com/OpenMobileAlliance/lwm2m-registry) and covers the Objects the
  protocol itself depends on — Security (0), Server (1), Access Control (2), Device (3),
  Connectivity Monitoring (4), Firmware Update (5), Location (6), Connectivity Statistics
  (7), OSCORE (21) — plus Temperature (3303) as a representative IPSO Object. See
  `priv/ddf/README.md` for provenance and how to re-sync.

  Parsed at compile time, so this is a struct literal at runtime: no file IO, no XML parsing,
  and it works in a release that strips `priv`.

  A model matters most for the formats that are not self-describing. `Wick.Codec.Tlv` cannot
  tell an Integer from a Float from a Time without one:

      registry = Wick.Object.Registry.standard()
      {:ok, pack} = Wick.Codec.Tlv.decode(payload, path: path, model: registry)

  Object versions are not yet part of lookup — the bundled files are the latest published
  version of each Object, and a device advertising an older one resolves against that.

  ## Examples

      iex> Wick.Object.Registry.lookup(Wick.Object.Registry.standard(), 3).name
      "Device"

      iex> {:ok, path} = Wick.Path.parse("/3/0/13")
      iex> Wick.Model.resource_type(Wick.Object.Registry.standard(), path)
      :time

      iex> {:ok, path} = Wick.Path.parse("/1/0/1")
      iex> Wick.Model.resource_type(Wick.Object.Registry.standard(), path)
      :integer
  """
  @spec standard() :: t()
  def standard, do: %__MODULE__{objects: @standard_objects}

  @doc """
  Build a registry from a list of `Wick.Object.Definition`s.

  Later definitions overwrite earlier ones with the same Object ID.

  ## Examples

      iex> alias Wick.Object.{Definition, Registry}
      iex> def_a = %Definition{
      ...>   object_id: 6, name: "Location",
      ...>   multiple_instances: :single, mandatory: :optional, resources: []
      ...> }
      iex> registry = Registry.from_definitions([def_a])
      iex> Registry.lookup(registry, 6).name
      "Location"
  """
  @spec from_definitions([Definition.t()]) :: t()
  def from_definitions(definitions) when is_list(definitions) do
    Enum.reduce(definitions, new(), &register(&2, &1))
  end

  @doc """
  Add or replace an Object Definition. Last write wins on duplicate IDs.
  """
  @spec register(t(), Definition.t()) :: t()
  def register(%__MODULE__{objects: objects} = registry, %Definition{object_id: id} = definition) do
    %{registry | objects: Map.put(objects, id, definition)}
  end

  @doc "Remove an Object by ID. Returns the registry unchanged if the ID is not present."
  @spec unregister(t(), Wick.Path.id()) :: t()
  def unregister(%__MODULE__{objects: objects} = registry, object_id) do
    %{registry | objects: Map.delete(objects, object_id)}
  end

  @doc "Look up an Object Definition by ID. Returns `nil` if not registered."
  @spec lookup(t(), Wick.Path.id()) :: Definition.t() | nil
  def lookup(%__MODULE__{objects: objects}, object_id) do
    Map.get(objects, object_id)
  end

  @doc """
  Look up a Resource Definition by Object ID + Resource ID. Returns `nil` if either the
  Object or the Resource is not present.
  """
  @spec lookup_resource(t(), Wick.Path.id(), Wick.Path.id()) :: Resource.t() | nil
  def lookup_resource(%__MODULE__{} = registry, object_id, resource_id) do
    case lookup(registry, object_id) do
      nil -> nil
      definition -> Definition.find_resource(definition, resource_id)
    end
  end

  @doc "List all registered Object IDs in ascending numeric order."
  @spec object_ids(t()) :: [Wick.Path.id()]
  def object_ids(%__MODULE__{objects: objects}) do
    objects |> Map.keys() |> Enum.sort()
  end

  @doc "Number of Objects registered."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{objects: objects}), do: map_size(objects)

  @doc """
  Build a registry by reading every `*.xml` file in a directory and parsing it as a DDF
  document.

  Fails fast on the first parse error; returns the offending file path in the error meta.

  For the Objects Wick ships, use `standard/0` instead — it is parsed at compile time and
  costs nothing at runtime. This function is for *your* DDF: vendor Objects, or a newer
  version of a standard one.

  ## Examples

      iex> {:ok, registry} = Wick.Object.Registry.load_from_dir(
      ...>   Application.app_dir(:wick, "priv/ddf")
      ...> )
      iex> Wick.Object.Registry.size(registry) == Wick.Object.Registry.size(
      ...>   Wick.Object.Registry.standard()
      ...> )
      true
  """
  @spec load_from_dir(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load_from_dir(dir) when is_binary(dir) do
    with {:ok, files} <- list_xml_files(dir) do
      load_files(files)
    end
  end

  defp list_xml_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        files =
          names
          |> Enum.filter(&String.ends_with?(&1, ".xml"))
          |> Enum.sort()
          |> Enum.map(&Path.join(dir, &1))

        {:ok, files}

      {:error, reason} ->
        {:error,
         Error.new(
           :directory_unreadable,
           "could not list DDF directory: #{:file.format_error(reason)}",
           dir: dir,
           reason: reason
         )}
    end
  end

  defp load_files(files) do
    Enum.reduce_while(files, {:ok, new()}, fn file, {:ok, registry} ->
      case load_one(file) do
        {:ok, definition} -> {:cont, {:ok, register(registry, definition)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp load_one(file) do
    with {:ok, xml} <- read_file(file),
         {:ok, definition} <- Ddf.parse(xml) do
      {:ok, definition}
    else
      {:error, %Error{} = err} ->
        {:error, %{err | meta: Map.put(err.meta, :file, file)}}
    end
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, xml} ->
        {:ok, xml}

      {:error, reason} ->
        {:error,
         Error.new(:file_unreadable, "could not read DDF file: #{:file.format_error(reason)}",
           reason: reason
         )}
    end
  end
end

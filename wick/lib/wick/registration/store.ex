defmodule Wick.Registration.Store do
  @moduledoc """
  In-memory store for LwM2M registrations.

  Plain data plus pure functions — no process, no global state. Caller is responsible
  for serialising access (e.g. by holding the store inside a GenServer's state).

  Each registration is keyed by a server-assigned location ID. Lookup-by-endpoint-name
  is supported because LwM2M allows at most one active registration per endpoint name
  (a fresh Register from a known endpoint replaces the old record).

  Storage is intentionally minimal: just enough for the registration interface tests.
  Production deployments swap this out for a persistent store backed by Postgres or
  similar — see ADR (TBD) for the boundary between library and platform.
  """

  alias Wick.Registration.Record

  @type t :: %__MODULE__{
          # location_id -> Record.t()
          by_id: %{optional(String.t()) => Record.t()},
          # endpoint_name -> location_id
          by_endpoint: %{optional(String.t()) => String.t()},
          counter: non_neg_integer()
        }

  defstruct by_id: %{}, by_endpoint: %{}, counter: 0

  @doc "Build a fresh empty store."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Insert a new registration, replacing any existing one for the same endpoint name.

  Returns `{location_id, store}`. The location ID is allocated by the store and is the
  one written into the `Location-Path` of the `2.01 Created` response.
  """
  @spec put_new(t(), Record.t()) :: {String.t(), t()}
  def put_new(%__MODULE__{} = store, %Record{} = record) do
    store = drop_existing_for_endpoint(store, record.endpoint_name)
    {id, store} = next_id(store)
    record = %{record | location_id: id}

    store = %{
      store
      | by_id: Map.put(store.by_id, id, record),
        by_endpoint: Map.put(store.by_endpoint, record.endpoint_name, id)
    }

    {id, store}
  end

  @doc "Fetch a registration by its location ID."
  @spec fetch(t(), String.t()) :: {:ok, Record.t()} | :error
  def fetch(%__MODULE__{by_id: by_id}, id), do: Map.fetch(by_id, id)

  @doc "List every active registration."
  @spec list(t()) :: [Record.t()]
  def list(%__MODULE__{by_id: by_id}), do: Map.values(by_id)

  @doc """
  Update an existing registration. The patch map is merged into the existing record;
  the `endpoint_name`, `location_id`, and `created_at` fields are immutable and cannot
  be patched.

  Returns `{:ok, updated_record, store}` on success or `:error` if the location is
  unknown.
  """
  @spec update(t(), String.t(), map()) :: {:ok, Record.t(), t()} | :error
  def update(%__MODULE__{} = store, id, patch) when is_map(patch) do
    case Map.fetch(store.by_id, id) do
      :error ->
        :error

      {:ok, record} ->
        patch = Map.drop(patch, [:endpoint_name, :location_id, :created_at])
        updated = struct!(record, patch)
        store = %{store | by_id: Map.put(store.by_id, id, updated)}
        {:ok, updated, store}
    end
  end

  @doc "Remove a registration by location ID. No-op if unknown."
  @spec delete(t(), String.t()) :: t()
  def delete(%__MODULE__{} = store, id) do
    case Map.pop(store.by_id, id) do
      {nil, _} ->
        store

      {record, by_id} ->
        by_endpoint = Map.delete(store.by_endpoint, record.endpoint_name)
        %{store | by_id: by_id, by_endpoint: by_endpoint}
    end
  end

  defp drop_existing_for_endpoint(store, endpoint_name) do
    case Map.fetch(store.by_endpoint, endpoint_name) do
      :error -> store
      {:ok, id} -> delete(store, id)
    end
  end

  defp next_id(%__MODULE__{counter: counter} = store) do
    # 8 hex chars derived from a counter, prefixed with a constant marker. Short and
    # unique within a store; not a security token — clients reveal it in URLs.
    id = "r" <> Integer.to_string(counter, 16)
    {id, %{store | counter: counter + 1}}
  end
end

defmodule Wick.Observation.Store do
  @moduledoc """
  In-memory store for Observe relations.

  Plain data plus pure functions — no process, no global state. The caller serialises
  access, typically by holding the store inside a GenServer's state. Same shape and same
  trade-offs as `Wick.Registration.Store`.

  Relations are keyed by an opaque `handle` supplied by the caller — whatever the transport
  uses to correlate a notification back to its request. With `WickCoap.Endpoint` that is
  the handle returned by `WickCoap.Endpoint.observe/4`; elsewhere a `{peer, token}` tuple
  works equally well. The store does not interpret it.

  A secondary index by `registration_id` exists because the common bulk operation is
  "the device deregistered or its lifetime expired — drop everything it was observing".

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3303/0/5700")
      iex> observation = Wick.Observation.new("r0", [path], now: 0)
      iex> store = Wick.Observation.Store.new() |> Wick.Observation.Store.put(:h1, observation)
      iex> {:ok, found} = Wick.Observation.Store.fetch(store, :h1)
      iex> found.registration_id
      "r0"
      iex> store |> Wick.Observation.Store.delete_by_registration("r0") |> Wick.Observation.Store.size()
      0
  """

  alias Wick.Observation
  alias Wick.Path

  @typedoc "An opaque correlation handle, supplied by the transport layer."
  @type handle :: term()

  @type t :: %__MODULE__{
          by_handle: %{optional(handle()) => Observation.t()},
          by_registration: %{optional(String.t()) => [handle()]}
        }

  defstruct by_handle: %{}, by_registration: %{}

  @doc "Build a fresh empty store."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Store an observation under `handle`, replacing any relation already held there.

  Replacing is the right behaviour rather than an error: a device that re-Observes the same
  path with the same token is refreshing the relation, not creating a second one.
  """
  @spec put(t(), handle(), Observation.t()) :: t()
  def put(%__MODULE__{} = store, handle, %Observation{} = observation) do
    store = delete(store, handle)

    handles = Map.get(store.by_registration, observation.registration_id, [])

    %{
      store
      | by_handle: Map.put(store.by_handle, handle, observation),
        by_registration:
          Map.put(store.by_registration, observation.registration_id, handles ++ [handle])
    }
  end

  @doc "Fetch an observation by handle."
  @spec fetch(t(), handle()) :: {:ok, Observation.t()} | :error
  def fetch(%__MODULE__{by_handle: by_handle}, handle), do: Map.fetch(by_handle, handle)

  @doc "List every relation held, in no particular order."
  @spec list(t()) :: [Observation.t()]
  def list(%__MODULE__{by_handle: by_handle}), do: Map.values(by_handle)

  @doc "Number of relations held."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{by_handle: by_handle}), do: map_size(by_handle)

  @doc """
  List the handles a registration is observing under, in insertion order.
  """
  @spec handles_for_registration(t(), String.t()) :: [handle()]
  def handles_for_registration(%__MODULE__{} = store, registration_id) do
    Map.get(store.by_registration, registration_id, [])
  end

  @doc """
  Replace the observation at `handle` with the result of `fun`. No-op if the handle is
  unknown, so a notification for a relation that has just been cancelled is harmless.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0/9")
      iex> store = Wick.Observation.Store.put(
      ...>   Wick.Observation.Store.new(), :h1, Wick.Observation.new("r0", [path], now: 0)
      ...> )
      iex> store = Wick.Observation.Store.update(store, :h1, &%{&1 | last_value: 42})
      iex> {:ok, obs} = Wick.Observation.Store.fetch(store, :h1)
      iex> obs.last_value
      42
  """
  @spec update(t(), handle(), (Observation.t() -> Observation.t())) :: t()
  def update(%__MODULE__{} = store, handle, fun) when is_function(fun, 1) do
    case Map.fetch(store.by_handle, handle) do
      :error ->
        store

      {:ok, observation} ->
        %{store | by_handle: Map.put(store.by_handle, handle, fun.(observation))}
    end
  end

  @doc "Remove a relation by handle. No-op if unknown."
  @spec delete(t(), handle()) :: t()
  def delete(%__MODULE__{} = store, handle) do
    case Map.pop(store.by_handle, handle) do
      {nil, _by_handle} ->
        store

      {observation, by_handle} ->
        %{
          store
          | by_handle: by_handle,
            by_registration: drop_handle(store.by_registration, observation.registration_id, handle)
        }
    end
  end

  @doc """
  Remove every relation belonging to a registration. Used when a device deregisters or its
  lifetime expires — the relations die with the registration per LwM2M 1.2 §6.2.
  """
  @spec delete_by_registration(t(), String.t()) :: t()
  def delete_by_registration(%__MODULE__{} = store, registration_id) do
    store
    |> handles_for_registration(registration_id)
    |> Enum.reduce(store, &delete(&2, &1))
  end

  @doc """
  Find the handles whose relation covers `path`, across every registration or within one.

  Matching is exact. A relation on `/3303/0` does **not** match a notification about
  `/3303/0/5700`; LwM2M notifies at the observed level, so the caller that wants
  hierarchical matching should walk the parent paths itself.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3303/0/5700")
      iex> store = Wick.Observation.Store.put(
      ...>   Wick.Observation.Store.new(), :h1, Wick.Observation.new("r0", [path], now: 0)
      ...> )
      iex> Wick.Observation.Store.handles_for_path(store, path)
      [:h1]
      iex> {:ok, other} = Wick.Path.parse("/3303/0")
      iex> Wick.Observation.Store.handles_for_path(store, other)
      []
  """
  @spec handles_for_path(t(), Path.t(), keyword()) :: [handle()]
  def handles_for_path(%__MODULE__{} = store, %Path{} = path, opts \\ []) do
    registration_id = Keyword.get(opts, :registration_id)

    store.by_handle
    |> Enum.filter(fn {_handle, observation} ->
      path in observation.paths and
        (is_nil(registration_id) or observation.registration_id == registration_id)
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp drop_handle(by_registration, registration_id, handle) do
    case Map.fetch(by_registration, registration_id) do
      :error ->
        by_registration

      {:ok, handles} ->
        case List.delete(handles, handle) do
          [] -> Map.delete(by_registration, registration_id)
          remaining -> Map.put(by_registration, registration_id, remaining)
        end
    end
  end
end

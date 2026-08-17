defmodule Wick.Registration.Server do
  @moduledoc """
  Pure server-side logic for the LwM2M Registration interface.

  `handle/3` takes a transport-agnostic request description (method, path segments,
  query, payload, peer address, current time) plus the in-memory `Store` and returns
  `{response, updated_store}`. The response is itself a small data record — the
  caller (typically a `WickCoap.Handler` adapter) converts that into a CoAP message.

  Keeping this pure means we can unit-test every branch without spinning up a UDP
  socket, and the same logic works behind any transport binding (CoAP/UDP, CoAP/TCP,
  CoAP/WebSocket, etc.).

  ## Response shape

  Each response carries a CoAP code atom (e.g. `:created`, `:changed`, `:bad_request`),
  optional `location_path` (for Register), and an optional human-readable diagnostic.
  """

  alias Wick.CoreLink
  alias Wick.Registration.Record
  alias Wick.Registration.Store

  defmodule Response do
    @moduledoc false

    @type t :: %__MODULE__{
            code: atom(),
            location_path: [String.t()] | nil,
            diagnostic: String.t() | nil
          }

    @enforce_keys [:code]
    defstruct [:code, :location_path, :diagnostic]
  end

  @type method :: :post | :put | :delete | :get

  defmodule Request do
    @moduledoc false

    @type t :: %__MODULE__{
            method: Wick.Registration.Server.method(),
            path: [String.t()],
            query: [{String.t(), String.t()}],
            payload: String.t(),
            peer: term() | nil,
            now: integer()
          }
    @enforce_keys [:method, :path, :query, :payload, :peer, :now]
    defstruct [:method, :path, :query, :payload, :peer, :now]
  end

  @doc """
  Dispatch a parsed inbound request against the store.

  The request is matched on `(method, path)`:

  * `POST /rd`            → Register
  * `POST /rd/<id>`       → Update
  * `DELETE /rd/<id>`     → Deregister

  Anything else returns `4.04 Not Found`.
  """
  @spec handle(Request.t(), Store.t()) :: {Response.t(), Store.t()}
  def handle(%Request{method: :post, path: ["rd"]} = req, store),
    do: handle_register(req, store)

  def handle(%Request{method: :post, path: ["rd", location]} = req, store),
    do: handle_update(req, store, location)

  def handle(%Request{method: :delete, path: ["rd", location]}, store),
    do: handle_deregister(store, location)

  def handle(%Request{}, store) do
    {%Response{code: :not_found}, store}
  end

  defp handle_register(%Request{query: query, payload: payload, peer: peer, now: now}, store) do
    with {:ok, endpoint_name} <- require_param(query, "ep"),
         {:ok, objects} <- decode_objects(payload),
         {:ok, lifetime} <- positive_integer(query, "lt", 86_400) do
      record = %Record{
        endpoint_name: endpoint_name,
        lifetime: lifetime,
        lwm2m_version: param(query, "lwm2m", "1.2"),
        binding: param(query, "b"),
        queue_mode: flag?(query, "Q"),
        sms_number: param(query, "sms"),
        profile_id: param(query, "pid"),
        objects: objects,
        peer: peer,
        created_at: now,
        updated_at: now
      }

      {id, store} = Store.put_new(store, record)
      {%Response{code: :created, location_path: ["rd", id]}, store}
    else
      {:error, reason} -> {%Response{code: :bad_request, diagnostic: reason}, store}
    end
  end

  defp handle_update(%{query: query, payload: payload, peer: peer, now: now}, store, location) do
    case Store.fetch(store, location) do
      :error ->
        {%Response{code: :not_found}, store}

      {:ok, _record} ->
        with {:ok, objects} <- maybe_decode_objects(payload),
             {:ok, lifetime} <- maybe_positive(query, "lt") do
          patch =
            %{updated_at: now, peer: peer}
            |> patch_put(:lifetime, lifetime)
            |> patch_put(:binding, param(query, "b"))
            |> patch_put(:sms_number, param(query, "sms"))
            |> patch_put_objects(objects)

          case Store.update(store, location, patch) do
            {:ok, _record, store} -> {%Response{code: :changed}, store}
            :error -> {%Response{code: :not_found}, store}
          end
        else
          {:error, reason} -> {%Response{code: :bad_request, diagnostic: reason}, store}
        end
    end
  end

  defp handle_deregister(store, location) do
    case Store.fetch(store, location) do
      :error -> {%Response{code: :not_found}, store}
      {:ok, _} -> {%Response{code: :deleted}, Store.delete(store, location)}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp require_param(query, key) do
    case param(query, key) do
      nil -> {:error, "missing query parameter: " <> key}
      value -> {:ok, value}
    end
  end

  defp param(query, key, default \\ nil) do
    case List.keyfind(query, key, 0) do
      {^key, value} -> value
      _ -> default
    end
  end

  defp flag?(query, key), do: List.keyfind(query, key, 0) != nil

  defp positive_integer(query, key, default) do
    case param(query, key) do
      nil ->
        {:ok, default}

      raw ->
        case Integer.parse(to_string(raw)) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "invalid #{key}: #{inspect(raw)}"}
        end
    end
  end

  defp maybe_positive(query, key) do
    case param(query, key) do
      nil -> {:ok, nil}
      _ -> positive_integer(query, key, 0)
    end
  end

  defp decode_objects(""), do: {:error, "missing registration payload"}

  defp decode_objects(payload) do
    case CoreLink.decode(payload) do
      {:ok, links} -> {:ok, links}
      {:error, %Wick.Error{message: msg}} -> {:error, "malformed link-format: " <> msg}
    end
  end

  defp maybe_decode_objects(""), do: {:ok, nil}

  defp maybe_decode_objects(payload) do
    case CoreLink.decode(payload) do
      {:ok, links} -> {:ok, links}
      {:error, %Wick.Error{message: msg}} -> {:error, "malformed link-format: " <> msg}
    end
  end

  defp patch_put(patch, _key, nil), do: patch
  defp patch_put(patch, key, value), do: Map.put(patch, key, value)

  defp patch_put_objects(patch, nil), do: patch
  defp patch_put_objects(patch, objects), do: Map.put(patch, :objects, objects)
end

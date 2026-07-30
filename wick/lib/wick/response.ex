defmodule Wick.Response do
  @moduledoc """
  A response to any `Wick.Request`.

  A single struct covers both success and error responses; the `:status` atom (see
  `Wick.Status`) distinguishes them. This is the inverse design of separate
  `SuccessResponse`/`ErrorResponse` types — chosen because every response carries the
  same fields (status, optional payload, optional content-format, optional location)
  and a tagged-status union is the natural Elixir shape.

  ## Fields

  * `:status` — `t:Wick.Status.t/0`. Required.
  * `:content_format` — CoAP Content-Format integer for the payload, or `nil` if no
    payload. Required iff `:payload` is set.
  * `:payload` — encoded response body, or `nil`. Used for Read responses (the value),
    Discover responses (CoRE Link Format string), and error responses that carry a
    diagnostic message.
  * `:location_path` — for Create responses, the `Wick.Path` of the newly created
    Object Instance. `nil` otherwise.

  ## Common shapes

      # Read success
      %Wick.Response{status: :content, content_format: 112, payload: <<...>>}

      # Write success
      %Wick.Response{status: :changed}

      # Create success
      %Wick.Response{status: :created, location_path: %Wick.Path{object_id: 3, object_instance_id: 0}}

      # Not Found
      %Wick.Response{status: :not_found}

      # Bad Request with diagnostic text
      %Wick.Response{status: :bad_request, payload: "missing required field"}

  ## Constructors

  Use the named builders for common cases — they enforce field invariants:

      iex> Wick.Response.content(112, <<0x80>>)
      %Wick.Response{status: :content, content_format: 112, payload: <<0x80>>, location_path: nil}

      iex> Wick.Response.changed()
      %Wick.Response{status: :changed, content_format: nil, payload: nil, location_path: nil}

      iex> Wick.Response.deleted()
      %Wick.Response{status: :deleted, content_format: nil, payload: nil, location_path: nil}

      iex> path = %Wick.Path{object_id: 3, object_instance_id: 0}
      iex> Wick.Response.created(path)
      %Wick.Response{status: :created, content_format: nil, payload: nil, location_path: %Wick.Path{object_id: 3, object_instance_id: 0, resource_id: nil, resource_instance_id: nil}}

      iex> Wick.Response.error(:not_found)
      %Wick.Response{status: :not_found, content_format: nil, payload: nil, location_path: nil}
  """

  alias Wick.Path
  alias Wick.Status
  alias Wick.Wire

  @typedoc "An LwM2M response."
  @type t :: %__MODULE__{
          status: Status.t(),
          content_format: non_neg_integer() | nil,
          payload: binary() | nil,
          location_path: Path.t() | nil
        }

  @enforce_keys [:status]
  defstruct [:status, :content_format, :payload, :location_path]

  @doc """
  Build a `:content` response carrying a payload (for Read / Discover).

  ## Examples

      iex> Wick.Response.content(112, <<0x80>>).status
      :content
  """
  @spec content(non_neg_integer(), binary()) :: t()
  def content(content_format, payload)
      when is_integer(content_format) and content_format >= 0 and is_binary(payload) do
    %__MODULE__{status: :content, content_format: content_format, payload: payload}
  end

  @doc "Build a `:changed` response (Write or Execute success)."
  @spec changed() :: t()
  def changed, do: %__MODULE__{status: :changed}

  @doc "Build a `:deleted` response (Delete success)."
  @spec deleted() :: t()
  def deleted, do: %__MODULE__{status: :deleted}

  @doc """
  Build a `:created` response carrying the location of the new Object Instance.
  """
  @spec created(Path.t()) :: t()
  def created(%Path{} = location_path) do
    %__MODULE__{status: :created, location_path: location_path}
  end

  @doc """
  Build an error response.

  Optionally attach a human-readable `payload` (UTF-8) for diagnostics. Status must be in
  the 4.xx or 5.xx CoAP class.

  ## Examples

      iex> Wick.Response.error(:not_found).status
      :not_found

      iex> Wick.Response.error(:bad_request, "missing required field").payload
      "missing required field"
  """
  @spec error(Status.t(), binary() | nil) :: t()
  def error(status, payload \\ nil)
      when is_atom(status) and (is_nil(payload) or is_binary(payload)) do
    unless Status.error?(status) do
      raise ArgumentError, "expected an error status, got: #{inspect(status)}"
    end

    %__MODULE__{status: status, payload: payload}
  end

  @doc "True iff the response is in the 2.xx success class."
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{status: status}), do: Status.success?(status)

  @doc "True iff the response is in the 4.xx or 5.xx error classes."
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{status: status}), do: Status.error?(status)

  # ── Wire conversion ────────────────────────────────────────────────────────

  @doc """
  Convert a response to its transport-agnostic `Wick.Wire.Response` form.

  `observe_seq` is threaded through for Notify responses and for the initial response to
  an Observe; pass `nil` (the default) for every other response.

  ## Examples

      iex> Wick.Response.to_wire(Wick.Response.content(112, <<0x80>>))
      %Wick.Wire.Response{status: :content, content_format: 112, payload: <<0x80>>}

      iex> path = %Wick.Path{object_id: 3, object_instance_id: 0}
      iex> Wick.Response.to_wire(Wick.Response.created(path)).location_path
      ["3", "0"]

      iex> Wick.Response.to_wire(Wick.Response.changed())
      %Wick.Wire.Response{status: :changed, payload: "", location_path: []}

      iex> Wick.Response.to_wire(Wick.Response.content(112, <<0x80>>), 7).observe_seq
      7
  """
  @spec to_wire(t(), non_neg_integer() | nil) :: Wire.Response.t()
  def to_wire(%__MODULE__{} = response, observe_seq \\ nil) do
    %Wire.Response{
      status: response.status,
      payload: response.payload || "",
      content_format: response.content_format,
      location_path: location_segments(response.location_path),
      observe_seq: observe_seq
    }
  end

  @doc """
  Recover a response from its `Wick.Wire.Response` form — the inverse of `to_wire/2`.

  An empty payload becomes `nil` rather than `""`, matching what the constructors in this
  module produce, so a response that made the round trip compares equal to the one you
  built.

  A `location_path` is narrowed to a `Wick.Path`. Registration's `["rd", "<id>"]` shape is
  not a valid LwM2M path, so it is left out of the struct rather than erroring — use
  `Wick.Wire.Response`'s raw `location_path` for registration responses.

  ## Examples

      iex> wire = %Wick.Wire.Response{status: :content, content_format: 112, payload: <<0x80>>}
      iex> Wick.Response.from_wire(wire)
      %Wick.Response{status: :content, content_format: 112, payload: <<0x80>>}

      iex> wire = %Wick.Wire.Response{status: :created, location_path: ["3", "0"]}
      iex> Wick.Response.from_wire(wire).location_path
      %Wick.Path{object_id: 3, object_instance_id: 0, resource_id: nil, resource_instance_id: nil}

      iex> wire = %Wick.Wire.Response{status: :created, location_path: ["rd", "r0"]}
      iex> Wick.Response.from_wire(wire).location_path
      nil
  """
  @spec from_wire(Wire.Response.t()) :: t()
  def from_wire(%Wire.Response{} = wire) do
    %__MODULE__{
      status: wire.status,
      content_format: wire.content_format,
      payload: if(wire.payload in [nil, ""], do: nil, else: wire.payload),
      location_path: parse_location(wire.location_path)
    }
  end

  defp location_segments(nil), do: []
  defp location_segments(%Path{} = path), do: Path.to_segments(path)

  defp parse_location([]), do: nil

  defp parse_location(segments) do
    case Path.from_segments(segments) do
      {:ok, path} -> path
      {:error, _not_an_lwm2m_path} -> nil
    end
  end
end

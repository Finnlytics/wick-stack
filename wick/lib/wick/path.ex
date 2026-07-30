defmodule Wick.Path do
  @moduledoc """
  An LwM2M URI path.

  Paths address resources within the Object Model. The shape is:

      /{object_id}[/{object_instance_id}[/{resource_id}[/{resource_instance_id}]]]

  Each component is a non-negative integer in the range `0..65535` per
  [OMA LwM2M 1.2 §6.3](https://www.openmobilealliance.org/release/LightweightM2M/V1_2_1-20221209-A/OMA-TS-LightweightM2M_Core-V1_2_1-20221209-A.pdf).

  Trailing components are optional and represented as `nil`.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0/9")
      iex> path.object_id
      3
      iex> path.resource_id
      9

      iex> Wick.Path.format(%Wick.Path{object_id: 3, object_instance_id: 0, resource_id: 9})
      "/3/0/9"
  """

  alias Wick.Error

  @max_id 65_535

  @typedoc "A non-negative LwM2M ID (object, instance, resource, or resource-instance)."
  @type id :: 0..unquote(@max_id)

  @typedoc "An LwM2M path."
  @type t :: %__MODULE__{
          object_id: id(),
          object_instance_id: id() | nil,
          resource_id: id() | nil,
          resource_instance_id: id() | nil
        }

  @enforce_keys [:object_id]
  defstruct [:object_id, :object_instance_id, :resource_id, :resource_instance_id]

  @doc """
  Parse a string LwM2M path into a `t:t/0`.

  Accepts an optional leading `/`. All components must be integers in `0..#{@max_id}`.

  ## Examples

      iex> {:ok, p} = Wick.Path.parse("/3/0/9")
      iex> p
      %Wick.Path{object_id: 3, object_instance_id: 0, resource_id: 9, resource_instance_id: nil}

      iex> Wick.Path.parse("3/0")
      {:ok, %Wick.Path{object_id: 3, object_instance_id: 0, resource_id: nil, resource_instance_id: nil}}

      iex> {:ok, p} = Wick.Path.parse("/65535")
      iex> p.object_id
      65535

      iex> {:error, err} = Wick.Path.parse("/abc")
      iex> err.code
      :invalid_path

      iex> {:error, err} = Wick.Path.parse("/3/0/9/2/extra")
      iex> err.code
      :invalid_path

      iex> {:error, err} = Wick.Path.parse("/65536")
      iex> err.code
      :invalid_path

      iex> {:error, err} = Wick.Path.parse("")
      iex> err.code
      :invalid_path
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def parse(string) when is_binary(string) do
    string
    |> String.trim_leading("/")
    |> case do
      "" ->
        invalid("path must contain at least an object_id", input: string)

      trimmed ->
        trimmed
        |> String.split("/", trim: false)
        |> parse_components(string)
    end
  end

  @doc """
  Format a path as a string with a leading `/`.

  ## Examples

      iex> Wick.Path.format(%Wick.Path{object_id: 3, object_instance_id: 0, resource_id: 9})
      "/3/0/9"

      iex> Wick.Path.format(%Wick.Path{object_id: 3})
      "/3"

      iex> Wick.Path.format(%Wick.Path{
      ...>   object_id: 3, object_instance_id: 0, resource_id: 9, resource_instance_id: 2
      ...> })
      "/3/0/9/2"
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = path) do
    path
    |> to_segments()
    |> Enum.map_join("", fn segment -> "/" <> segment end)
  end

  @doc """
  Split a path into its component strings — the form a CoAP Uri-Path option list wants.

  ## Examples

      iex> Wick.Path.to_segments(%Wick.Path{object_id: 3, object_instance_id: 0, resource_id: 9})
      ["3", "0", "9"]

      iex> Wick.Path.to_segments(%Wick.Path{object_id: 3})
      ["3"]
  """
  @spec to_segments(t()) :: [String.t()]
  def to_segments(%__MODULE__{} = path) do
    [path.object_id, path.object_instance_id, path.resource_id, path.resource_instance_id]
    |> Enum.take_while(&(&1 != nil))
    |> Enum.map(&Integer.to_string/1)
  end

  @doc """
  Build a path from a list of component strings — the inverse of `to_segments/1`, and the
  form an inbound CoAP Uri-Path arrives in.

  ## Examples

      iex> Wick.Path.from_segments(["3", "0", "9"])
      {:ok, %Wick.Path{object_id: 3, object_instance_id: 0, resource_id: 9, resource_instance_id: nil}}

      iex> {:error, err} = Wick.Path.from_segments([])
      iex> err.code
      :invalid_path

      iex> {:error, err} = Wick.Path.from_segments(["3", "bs"])
      iex> err.code
      :invalid_path
  """
  @spec from_segments([String.t()]) :: {:ok, t()} | {:error, Error.t()}
  def from_segments([]), do: invalid("path must contain at least an object_id")

  def from_segments(segments) when is_list(segments) do
    parse_components(segments, Enum.join(segments, "/"))
  end

  # --- private ---

  defp parse_components(parts, _input) when length(parts) > 4 do
    invalid("path may have at most 4 components")
  end

  defp parse_components(parts, _input) do
    case Enum.reduce_while(parts, [], &parse_id/2) do
      {:error, err} -> {:error, err}
      ids -> {:ok, build(Enum.reverse(ids))}
    end
  end

  defp parse_id(component, acc) do
    case Integer.parse(component) do
      {n, ""} when n in 0..@max_id ->
        {:cont, [n | acc]}

      _ ->
        {:halt, {:error, Error.new(:invalid_path, "invalid path component: #{inspect(component)}")}}
    end
  end

  defp build([object_id]) do
    %__MODULE__{object_id: object_id}
  end

  defp build([object_id, instance_id]) do
    %__MODULE__{object_id: object_id, object_instance_id: instance_id}
  end

  defp build([object_id, instance_id, resource_id]) do
    %__MODULE__{
      object_id: object_id,
      object_instance_id: instance_id,
      resource_id: resource_id
    }
  end

  defp build([object_id, instance_id, resource_id, resource_instance_id]) do
    %__MODULE__{
      object_id: object_id,
      object_instance_id: instance_id,
      resource_id: resource_id,
      resource_instance_id: resource_instance_id
    }
  end

  defp invalid(message, meta \\ []) do
    {:error, Error.new(:invalid_path, message, meta)}
  end
end

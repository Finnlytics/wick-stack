defmodule Wick.Senml.Pack do
  @moduledoc """
  An ordered sequence of `Wick.Senml.Record`s.

  Direct port of Leshan's [`SenMLPack`](https://github.com/eclipse-leshan/leshan/blob/leshan-1.5.0/leshan-core/src/main/java/org/eclipse/leshan/senml/SenMLPack.java).
  A pack is the unit of encoding/decoding for SenML wire formats — every codec round-trips
  packs.

  Order is preserved. Base-prefix fields (`base_name`, `base_time`) on a record apply to that
  record and to subsequent records in the same pack until overridden, per
  [RFC 8428 §4.5.1 / §4.5.4](https://www.rfc-editor.org/rfc/rfc8428#section-4.5).

  ## Examples

      iex> r1 = %Wick.Senml.Record{base_name: "/3/0/", name: "9", number_value: 87}
      iex> r2 = %Wick.Senml.Record{name: "0", string_value: "Open Mobile Alliance"}
      iex> pack = Wick.Senml.Pack.new([r1, r2])
      iex> length(pack.records)
      2
      iex> hd(pack.records).base_name
      "/3/0/"
  """

  alias Wick.Senml.Record

  @typedoc "A SenML pack — an ordered list of records."
  @type t :: %__MODULE__{records: [Record.t()]}

  @enforce_keys [:records]
  defstruct records: []

  @doc """
  Build a pack from a list of records.

  ## Examples

      iex> Wick.Senml.Pack.new([])
      %Wick.Senml.Pack{records: []}

      iex> r = %Wick.Senml.Record{name: "/3/0/9", number_value: 87}
      iex> %Wick.Senml.Pack{records: [^r]} = Wick.Senml.Pack.new([r])
  """
  @spec new([Record.t()]) :: t()
  def new(records) when is_list(records) do
    %__MODULE__{records: records}
  end

  @doc """
  Build a pack from a list of `Wick.Path` values, producing one record per path with the
  `:name` set and no value field. Used to construct Read-Composite request bodies.

  Encode the resulting pack with `:allow_no_value` set, e.g.:

      Wick.Codec.SenmlCbor.encode(pack, allow_no_value: true)

  ## Examples

      iex> {:ok, p1} = Wick.Path.parse("/3/0/9")
      iex> {:ok, p2} = Wick.Path.parse("/3303/0/5700")
      iex> pack = Wick.Senml.Pack.from_paths([p1, p2])
      iex> Enum.map(pack.records, & &1.name)
      ["/3/0/9", "/3303/0/5700"]
      iex> Enum.all?(pack.records, &(Wick.Senml.Record.value_type(&1) == :none))
      true
  """
  @spec from_paths([Wick.Path.t()]) :: t()
  def from_paths(paths) when is_list(paths) do
    new(Enum.map(paths, fn %Wick.Path{} = path -> %Record{name: Wick.Path.format(path)} end))
  end

  @doc """
  Resolve every record's effective name and time by applying the base-prefix fields, per
  [RFC 8428 §4.5](https://www.rfc-editor.org/rfc/rfc8428#section-4.5).

  Returns `{effective_name, effective_time, record}` tuples in pack order. A `base_name` /
  `base_time` set on a record applies to that record **and every record after it** until
  another record overrides it. A record with no `time` and no `base_time` in scope resolves
  to `nil` rather than `0`, so callers can tell "no timestamp" from "at the base time".

  ## Examples

      iex> pack = Wick.Senml.Pack.new([
      ...>   %Wick.Senml.Record{base_name: "/3/0/", name: "9", number_value: 87},
      ...>   %Wick.Senml.Record{name: "0", string_value: "OMA"}
      ...> ])
      iex> Enum.map(Wick.Senml.Pack.resolve(pack), fn {name, _time, _record} -> name end)
      ["/3/0/9", "/3/0/0"]

      iex> pack = Wick.Senml.Pack.new([
      ...>   %Wick.Senml.Record{base_time: 1_000, name: "/1/0/1", time: 5, number_value: 1},
      ...>   %Wick.Senml.Record{name: "/1/0/2", number_value: 2}
      ...> ])
      iex> Enum.map(Wick.Senml.Pack.resolve(pack), fn {_name, time, _record} -> time end)
      [1005, 1000]
  """
  @spec resolve(t()) :: [{String.t(), number() | nil, Record.t()}]
  def resolve(%__MODULE__{records: records}) do
    {resolved, _base} =
      Enum.map_reduce(records, {"", nil}, fn %Record{} = record, {base_name, base_time} ->
        base_name = record.base_name || base_name
        base_time = record.base_time || base_time

        {{base_name <> (record.name || ""), add_time(base_time, record.time), record},
         {base_name, base_time}}
      end)

    resolved
  end

  @doc """
  Interpret a pack as a list of `Wick.Path` values — the inverse of `from_paths/1`.

  This is how a Composite request body is read back: the paths are the records' resolved
  names. Values, if any, are ignored; use `resolve/1` when you need them.

  Returns `{:error, %Wick.Error{code: :invalid_path}}` if any record's resolved name is not
  a valid LwM2M path, and `{:error, %Wick.Error{code: :missing_name}}` for a record with no
  name at all.

  ## Examples

      iex> {:ok, p} = Wick.Path.parse("/3/0/9")
      iex> {:ok, [^p]} = p |> List.wrap() |> Wick.Senml.Pack.from_paths() |> Wick.Senml.Pack.to_paths()

      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{base_name: "/3/0/", name: "9"}])
      iex> {:ok, [path]} = Wick.Senml.Pack.to_paths(pack)
      iex> Wick.Path.format(path)
      "/3/0/9"

      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{name: "/nope"}])
      iex> {:error, err} = Wick.Senml.Pack.to_paths(pack)
      iex> err.code
      :invalid_path

      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{number_value: 1}])
      iex> {:error, err} = Wick.Senml.Pack.to_paths(pack)
      iex> err.code
      :missing_name
  """
  @spec to_paths(t()) :: {:ok, [Wick.Path.t()]} | {:error, Wick.Error.t()}
  def to_paths(%__MODULE__{} = pack) do
    pack
    |> resolve()
    |> Enum.reduce_while({:ok, []}, fn {name, _time, _record}, {:ok, acc} ->
      case path_from_name(name) do
        {:ok, path} -> {:cont, {:ok, [path | acc]}}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      {:error, err} -> {:error, err}
    end
  end

  defp path_from_name(""), do: {:error, Wick.Error.new(:missing_name, "record has no name")}
  defp path_from_name(name), do: Wick.Path.parse(name)

  defp add_time(nil, nil), do: nil
  defp add_time(base_time, nil), do: base_time
  defp add_time(nil, time), do: time
  defp add_time(base_time, time), do: base_time + time
end

defmodule Wick.Codec.Tlv do
  @moduledoc """
  The LwM2M TLV codec — `application/vnd.oma.lwm2m+tlv`, Content-Format 11542.

  TLV is the only content format **mandatory** in LwM2M 1.0, so it is what most of the
  deployed installed base speaks. This module maps between TLV bytes and a
  `Wick.Senml.Pack`, the same intermediate every other Wick codec produces, so a consumer
  swaps content formats without changing anything downstream:

      {:ok, pack} = Wick.Codec.Tlv.decode(payload, path: path, model: registry)
      {:ok, tree} = Wick.Object.Tree.apply_pack(tree, pack, model: registry)

  ## The request path is part of the format

  Unlike SenML, TLV carries no names. A payload is understood only relative to the path that
  was requested — the same three bytes are `/3/0/9` on a Read of `/3/0` and `/5/2/9` on a
  Read of `/5/2`. Both `encode/2` and `decode/2` therefore need `:path`, and the structure
  that comes out depends on its depth (LwM2M 1.2 §6.4.3):

  | `:path` | Top-level entries |
  |---|---|
  | `/3` (Object) | one `:object_instance` per Instance |
  | `/3/0` (Object Instance) | Resources directly — the Instance ID is already in the path |
  | `/3/0/9` (Resource) | one `:resource`, or one `:multiple_resource` |
  | `/3/0/6/0` (Resource Instance) | one `:resource_instance` |

  ## Values need the Object model

  A TLV value is bare bytes. Four of them could be an Integer, a Float or a Time, and only
  the Object definition says which — so both directions take a `:model`, anything
  `Wick.Model` accepts.

  Without one this module still works, because a missing model must never be fatal:

  * **Encoding** falls back to the SenML record's own shape — an integer encodes as an
    Integer, a float as a Float. Correct whenever the value's Elixir type already matches
    its declared LwM2M type, which is the common case when the pack came from a
    `Wick.Object.Tree`.
  * **Decoding** falls back to `:opaque`, since guessing between Integer and Float from
    length alone would silently corrupt values. The bytes survive; the caller can re-decode
    once it knows the type.

  Pass a `:model`. The fallbacks exist so a vendor Object with no DDF degrades instead of
  failing, not because they are good enough.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0")
      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{name: "/3/0/9", number_value: 87}])
      iex> {:ok, encoded} = Wick.Codec.Tlv.encode(pack, path: path)
      iex> IO.iodata_to_binary(encoded) |> Base.encode16()
      "C10957"

      iex> {:ok, path} = Wick.Path.parse("/3/0")
      iex> {:ok, pack} = Wick.Codec.Tlv.decode(Base.decode16!("C10957"), path: path)
      iex> Enum.map(pack.records, &{&1.name, &1.opaque_value})
      [{"/3/0/9", <<87>>}]
  """

  @behaviour Wick.Codec

  alias Wick.Codec
  alias Wick.Error
  alias Wick.Model
  alias Wick.Path
  alias Wick.Senml.Pack
  alias Wick.Senml.Record
  alias Wick.Tlv

  @content_format 11_542

  @impl Codec
  @doc """
  The CoAP Content-Format integer for TLV.

  ## Examples

      iex> Wick.Codec.Tlv.content_format()
      11542
  """
  @spec content_format() :: non_neg_integer()
  def content_format, do: @content_format

  # ── Encode ──────────────────────────────────────────────────────────────────

  @doc """
  Encode a `Wick.Senml.Pack` to TLV bytes.

  ## Options

  * `:path` — the request target. Required: it decides whether the payload is wrapped in
    Object Instance entries, and every record name is taken relative to it.
  * `:model` — anything `Wick.Model` accepts. Optional; see the module documentation for
    what happens without one.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0")
      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{name: "/3/0/0", string_value: "ACME"}])
      iex> {:ok, encoded} = Wick.Codec.Tlv.encode(pack, path: path)
      iex> IO.iodata_to_binary(encoded) |> Base.encode16()
      "C40041434D45"
  """
  @impl Codec
  @spec encode(Pack.t(), keyword()) :: {:ok, iodata()} | {:error, Error.t()}
  def encode(%Pack{} = pack, opts \\ []) do
    with {:ok, path} <- require_path(opts),
         {:ok, entries} <- resolve_records(pack, path) do
      build(entries, path, Keyword.get(opts, :model))
    end
  end

  # A pack carries absolute names; TLV carries positions. Turn each record into the path it
  # names so the tree below can be assembled from IDs.
  defp resolve_records(%Pack{} = pack, %Path{}) do
    pack
    |> Pack.resolve()
    |> Enum.reduce_while({:ok, []}, fn {name, _time, record}, {:ok, acc} ->
      case Path.parse(name) do
        {:ok, path} -> {:cont, {:ok, [{path, record} | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, error} -> {:error, error}
    end
  end

  defp build(entries, %Path{resource_id: nil, object_instance_id: nil} = path, model) do
    # Object level: one Object Instance entry per Instance present.
    entries
    |> group_by(& &1.object_instance_id)
    |> map_ok(fn {instance_id, instance_entries} ->
      with {:ok, children} <- resource_entries(instance_entries, path, model) do
        {:ok, %Tlv{type: :object_instance, id: instance_id, children: children}}
      end
    end)
    |> emit()
  end

  defp build(entries, %Path{resource_id: nil} = path, model) do
    # Object Instance level: Resources directly, since the Instance ID is in the request path.
    entries
    |> resource_entries(path, model)
    |> emit()
  end

  defp build(entries, %Path{resource_instance_id: nil} = path, model) do
    # Resource level: one entry, single or multiple.
    entries
    |> resource_entries(path, model)
    |> emit()
  end

  defp build(entries, %Path{}, model) do
    # Resource Instance level: exactly one Resource Instance entry.
    entries
    |> map_ok(fn {value_path, record} ->
      with {:ok, value} <- encode_value(record, value_path, model) do
        {:ok, %Tlv{type: :resource_instance, id: value_path.resource_instance_id, value: value}}
      end
    end)
    |> emit()
  end

  # A Resource is `:multiple_resource` exactly when the paths under it name Instances. That is
  # readable from the paths themselves, so it needs no model — which matters, because
  # multi-instance Resources are where a wrong guess corrupts the structure rather than one
  # value.
  defp resource_entries(entries, %Path{} = base, model) do
    entries
    |> group_by(& &1.resource_id)
    |> map_ok(fn
      {resource_id, [{%Path{resource_instance_id: nil} = value_path, record}]} ->
        with {:ok, value} <- encode_value(record, value_path, model) do
          {:ok, %Tlv{type: :resource, id: resource_id, value: value}}
        end

      {resource_id, instances} ->
        with {:ok, children} <- resource_instance_entries(instances, base, model) do
          {:ok, %Tlv{type: :multiple_resource, id: resource_id, children: children}}
        end
    end)
  end

  defp resource_instance_entries(entries, %Path{}, model) do
    map_ok(entries, fn {value_path, record} ->
      with {:ok, value} <- encode_value(record, value_path, model) do
        {:ok,
         %Tlv{type: :resource_instance, id: value_path.resource_instance_id || 0, value: value}}
      end
    end)
  end

  defp encode_value(%Record{} = record, %Path{} = path, model) do
    encode_typed(Model.resource_type(model, path) || inferred_type(record), record, path)
  end

  # Without a declared type, take the record's own shape. Right whenever the Elixir type
  # already matches the LwM2M one, which holds for anything that came out of a
  # `Wick.Object.Tree`.
  defp inferred_type(%Record{} = record) do
    case Record.value_type(record) do
      :number -> if is_float(record.number_value), do: :float, else: :integer
      :string -> :string
      :boolean -> :boolean
      :opaque -> :opaque
      :objlnk -> :objlnk
      :none -> :none
    end
  end

  defp encode_typed(type, %Record{} = record, %Path{} = path) do
    encode_as(type, Record.value(record), path)
  end

  # An absent value is zero bytes, whatever the Resource is declared to hold — that is how an
  # Execute Resource and an unset Optional one both appear.
  defp encode_as(_type, nil, _path), do: {:ok, <<>>}
  defp encode_as(:none, _value, _path), do: {:ok, <<>>}

  defp encode_as(type, value, _path)
       when type in [:string, :core_link, :opaque] and is_binary(value),
       do: {:ok, value}

  defp encode_as(:boolean, value, _path) when is_boolean(value),
    do: {:ok, Tlv.encode_boolean(value)}

  # Time is epoch seconds and Unsigned Integer is a non-negative Integer, so all three share
  # the shortest-signed-width encoding. See `Wick.Tlv.encode_integer/1`.
  defp encode_as(type, value, _path)
       when type in [:integer, :unsigned_integer, :time] and is_integer(value),
       do: {:ok, Tlv.encode_integer(value)}

  defp encode_as(:float, value, _path) when is_number(value), do: {:ok, Tlv.encode_float(value)}
  defp encode_as(:objlnk, value, %Path{} = path), do: encode_objlnk(value, path)
  defp encode_as(type, value, %Path{} = path), do: {:error, unencodable(type, value, path)}

  # A Pack always carries an Objlnk as the string "3:0" — see `Wick.Senml.Record`. The tuple
  # form of `t:Wick.Value.objlnk/0` only exists inside a `Wick.Object.Tree`, which converts on
  # its way into a record, so it cannot reach here.
  defp encode_objlnk(value, %Path{} = path) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [object_id, instance_id] ->
        with {object_id, ""} <- Integer.parse(object_id),
             {instance_id, ""} <- Integer.parse(instance_id) do
          {:ok, Tlv.encode_objlnk({object_id, instance_id})}
        else
          _malformed -> {:error, unencodable(:objlnk, value, path)}
        end

      _malformed ->
        {:error, unencodable(:objlnk, value, path)}
    end
  end

  defp encode_objlnk(value, %Path{} = path), do: {:error, unencodable(:objlnk, value, path)}

  defp unencodable(type, value, %Path{} = path) do
    Error.new(
      :unencodable_value,
      "#{Path.format(path)}: cannot encode #{inspect(value)} as #{inspect(type)}",
      path: Path.format(path),
      type: type
    )
  end

  defp emit({:ok, entries}), do: {:ok, Tlv.encode(entries)}
  defp emit({:error, error}), do: {:error, error}

  # ── Decode ──────────────────────────────────────────────────────────────────

  @doc """
  Decode TLV bytes into a `Wick.Senml.Pack` with absolute record names.

  ## Options

  * `:path` — the request target the payload is relative to. Required.
  * `:model` — anything `Wick.Model` accepts. Optional; without it every value decodes as
    `:opaque`, because the length of a TLV value does not reveal its type.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3/0")
      iex> {:ok, pack} = Wick.Codec.Tlv.decode(Base.decode16!("C10957"), path: path)
      iex> Enum.map(pack.records, & &1.name)
      ["/3/0/9"]
  """
  @impl Codec
  @spec decode(binary(), keyword()) :: {:ok, Pack.t()} | {:error, Error.t()}
  def decode(binary, opts \\ []) when is_binary(binary) do
    with {:ok, path} <- require_path(opts),
         {:ok, entries} <- Tlv.decode(binary) do
      model = Keyword.get(opts, :model)

      entries
      |> map_ok(&expand(&1, path, model))
      |> case do
        {:ok, records} -> {:ok, records |> List.flatten() |> Pack.new()}
        {:error, error} -> {:error, error}
      end
    end
  end

  # Walk the entry tree, deepening the path by one level at each step. The entry's *type* says
  # which level its ID belongs to, so a payload is self-locating once the base path is known.
  defp expand(%Tlv{type: :object_instance, id: id, children: children}, %Path{} = base, model) do
    child_base = %{base | object_instance_id: id}
    map_ok(children || [], &expand(&1, child_base, model))
  end

  defp expand(%Tlv{type: :multiple_resource, id: id, children: children}, %Path{} = base, model) do
    child_base = %{base | resource_id: id}
    map_ok(children || [], &expand(&1, child_base, model))
  end

  defp expand(%Tlv{type: :resource, id: id, value: value}, %Path{} = base, model) do
    path = %{base | resource_id: id}
    to_record(value, path, model)
  end

  defp expand(%Tlv{type: :resource_instance, id: id, value: value}, %Path{} = base, model) do
    # A Resource Instance sits under a Resource. When the request targeted the Resource
    # itself, `base` already names it; when it targeted a single Instance, the ID is ours.
    path =
      case base do
        %Path{resource_id: nil} -> %{base | resource_id: id}
        %Path{} -> %{base | resource_instance_id: id}
      end

    to_record(value, path, model)
  end

  defp to_record(value, %Path{} = path, model) do
    with {:ok, record} <- decode_value(value, Model.resource_type(model, path)) do
      {:ok, %{record | name: Path.format(path)}}
    end
  end

  # No declared type means the bytes are all we know. Opaque preserves them exactly; guessing
  # between Integer and Float on length alone would return a plausible wrong number, which is
  # worse than an honest byte string.
  defp decode_value(value, nil), do: {:ok, %Record{opaque_value: value}}
  defp decode_value(value, :opaque), do: {:ok, %Record{opaque_value: value}}
  defp decode_value(value, :string), do: {:ok, %Record{string_value: value}}
  defp decode_value(value, :core_link), do: {:ok, %Record{string_value: value}}
  defp decode_value(<<>>, :none), do: {:ok, %Record{}}

  defp decode_value(value, type) when type in [:integer, :unsigned_integer, :time] do
    with {:ok, number} <- Tlv.decode_integer(value), do: {:ok, %Record{number_value: number}}
  end

  defp decode_value(value, :float) do
    with {:ok, number} <- Tlv.decode_float(value), do: {:ok, %Record{number_value: number}}
  end

  defp decode_value(value, :boolean) do
    with {:ok, boolean} <- Tlv.decode_boolean(value), do: {:ok, %Record{boolean_value: boolean}}
  end

  defp decode_value(value, :objlnk) do
    with {:ok, {object_id, instance_id}} <- Tlv.decode_objlnk(value) do
      {:ok, %Record{object_link_value: "#{object_id}:#{instance_id}"}}
    end
  end

  defp decode_value(value, _type), do: {:ok, %Record{opaque_value: value}}

  # ── Shared ──────────────────────────────────────────────────────────────────

  defp require_path(opts) do
    case Keyword.get(opts, :path) do
      %Path{} = path ->
        {:ok, path}

      nil ->
        {:error,
         Error.new(
           :missing_path,
           "TLV carries no names, so the request path is required: pass `path: %Wick.Path{}`"
         )}

      other ->
        {:error, Error.new(:missing_path, "expected a %Wick.Path{}, got: #{inspect(other)}")}
    end
  end

  # Group `{path, record}` pairs by one of the path's IDs, preserving ascending ID order so
  # the output is deterministic and diffable against another implementation's bytes.
  defp group_by(entries, key_fun) do
    entries
    |> Enum.group_by(fn {path, _record} -> key_fun.(path) end)
    |> Enum.sort_by(fn {id, _entries} -> id end)
  end

  defp map_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, error} -> {:error, error}
    end
  end
end

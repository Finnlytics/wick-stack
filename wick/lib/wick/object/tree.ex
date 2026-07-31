defmodule Wick.Object.Tree do
  @moduledoc """
  A client's Object tree — the actual Resource *values* a device holds, as pure data.

  `Wick.Object.Registry` holds Object *definitions* (what a `/3303` looks like). This holds
  Object *instances and their values* (what `/3303/0/5700` currently reads). A device needs
  both: the definition to validate against, the tree to answer a Read.

  No process, no clock, no I/O — the same contract as `Wick.Registration.Store`. A device
  wraps this in whatever process owns its state and rebinds on every mutation.

  ## Values

  Values are stored as `{type, value}` tuples using `Wick.Value`'s type tags — the same
  shape `Wick.Codec.PlainText.encode/2` accepts. Tagging is not redundant: `42` could be
  an Integer or a Float on the wire, and `<<1, 2>>` could be a String or Opaque. Storing the
  tag means encoding never has to guess.

      {:integer, 42}
      {:float, 22.5}
      {:string, "Open Mobile Alliance"}
      {:boolean, true}
      {:opaque, <<0xDE, 0xAD>>}
      {:time, 1_700_000_000}
      {:objlnk, {1, 0}}

  ## Structure

  Only Resource-level entries are stored. Object Instances exist implicitly (an Instance
  "exists" once `create_instance/3` records it) so that an Instance with every Resource unset
  is still discoverable — which matters, because Create of an empty Instance is legal.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3303/0/5700")
      iex> tree =
      ...>   Wick.Object.Tree.new()
      ...>   |> Wick.Object.Tree.create_instance(3303, 0)
      ...>   |> Wick.Object.Tree.put(path, {:float, 22.5})
      iex> Wick.Object.Tree.fetch(tree, path)
      {:ok, {:float, 22.5}}
      iex> Wick.Object.Tree.links(tree) |> Enum.map(& &1.target)
      ["/3303/0"]
  """

  alias Wick.Attributes
  alias Wick.CoreLink
  alias Wick.Error
  alias Wick.Path
  alias Wick.Senml.Pack
  alias Wick.Senml.Record

  @typedoc "A tagged Resource value."
  @type value :: {Wick.Value.type(), term()}

  @typedoc "An internal key: the path's four components, with `nil` for absent levels."
  @type key :: {Path.id(), Path.id() | nil, Path.id() | nil, Path.id() | nil}

  # `instances` is a set represented as a map rather than a `MapSet`: `MapSet.t/1` is an
  # opaque type, and embedding it here would leak that opacity into every `t()` in the
  # module's specs, which Dialyzer flags as `contract_with_opaque`.
  @type t :: %__MODULE__{
          values: %{optional(key()) => value()},
          instances: %{optional({Path.id(), Path.id()}) => true},
          attributes: %{optional(key()) => Attributes.t()}
        }

  defstruct values: %{}, instances: %{}, attributes: %{}

  @doc "Build an empty tree."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Build a tree from a nested map of `object_id => instance_id => resource_id => value`.

  Every Instance mentioned is created. This is the ergonomic way to declare a device's
  starting state.

  ## Examples

      iex> tree = Wick.Object.Tree.from_map(%{
      ...>   3 => %{0 => %{0 => {:string, "ACME"}, 9 => {:integer, 87}}},
      ...>   3303 => %{0 => %{5700 => {:float, 22.5}}}
      ...> })
      iex> Wick.Object.Tree.links(tree) |> Enum.map(& &1.target)
      ["/3/0", "/3303/0"]
      iex> {:ok, path} = Wick.Path.parse("/3/0/9")
      iex> Wick.Object.Tree.fetch(tree, path)
      {:ok, {:integer, 87}}
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    Enum.reduce(map, new(), fn {object_id, instances}, tree ->
      Enum.reduce(instances, tree, fn {instance_id, resources}, tree ->
        tree = create_instance(tree, object_id, instance_id)

        Enum.reduce(resources, tree, fn {resource_id, value}, tree ->
          put_key(tree, {object_id, instance_id, resource_id, nil}, value)
        end)
      end)
    end)
  end

  # ── Instances ──────────────────────────────────────────────────────────────

  @doc "Record that an Object Instance exists. Idempotent."
  @spec create_instance(t(), Path.id(), Path.id()) :: t()
  def create_instance(%__MODULE__{} = tree, object_id, instance_id) do
    %{tree | instances: Map.put(tree.instances, {object_id, instance_id}, true)}
  end

  @doc "True when the Object Instance exists."
  @spec instance?(t(), Path.id(), Path.id()) :: boolean()
  def instance?(%__MODULE__{} = tree, object_id, instance_id) do
    Map.has_key?(tree.instances, {object_id, instance_id})
  end

  @doc """
  Delete an Object Instance and every Resource under it.

  ## Examples

      iex> tree = Wick.Object.Tree.from_map(%{3303 => %{0 => %{5700 => {:float, 1.0}}}})
      iex> tree = Wick.Object.Tree.delete_instance(tree, 3303, 0)
      iex> {Wick.Object.Tree.instance?(tree, 3303, 0), Wick.Object.Tree.links(tree)}
      {false, []}
  """
  @spec delete_instance(t(), Path.id(), Path.id()) :: t()
  def delete_instance(%__MODULE__{} = tree, object_id, instance_id) do
    values =
      Map.reject(tree.values, fn {{oid, iid, _rid, _riid}, _value} ->
        oid == object_id and iid == instance_id
      end)

    attributes =
      Map.reject(tree.attributes, fn {{oid, iid, _rid, _riid}, _attrs} ->
        oid == object_id and iid == instance_id
      end)

    %{
      tree
      | values: values,
        attributes: attributes,
        instances: Map.delete(tree.instances, {object_id, instance_id})
    }
  end

  @doc """
  Instance IDs present for an Object, ascending.

  ## Examples

      iex> tree = Wick.Object.Tree.from_map(%{1 => %{2 => %{}, 0 => %{}}})
      iex> Wick.Object.Tree.instance_ids(tree, 1)
      [0, 2]
  """
  @spec instance_ids(t(), Path.id()) :: [Path.id()]
  def instance_ids(%__MODULE__{} = tree, object_id) do
    for({{oid, instance_id}, true} <- tree.instances, oid == object_id, do: instance_id)
    |> Enum.sort()
  end

  @doc """
  The lowest unused Instance ID for an Object — what a Create with no explicit ID gets.

  ## Examples

      iex> tree = Wick.Object.Tree.from_map(%{1 => %{0 => %{}, 1 => %{}, 3 => %{}}})
      iex> Wick.Object.Tree.next_instance_id(tree, 1)
      2
      iex> Wick.Object.Tree.next_instance_id(tree, 99)
      0
  """
  @spec next_instance_id(t(), Path.id()) :: Path.id()
  def next_instance_id(%__MODULE__{} = tree, object_id) do
    taken = MapSet.new(instance_ids(tree, object_id))
    Enum.find(0..65_535, &(not MapSet.member?(taken, &1)))
  end

  # ── Values ─────────────────────────────────────────────────────────────────

  @doc """
  Set the value at a Resource or Resource Instance path. Creates the Object Instance
  implicitly, so a Write to a fresh path does not need a separate `create_instance/3`.

  Raises `ArgumentError` for a path that does not reach Resource level — there is nothing
  to store at an Object or Object Instance path.
  """
  @spec put(t(), Path.t(), value()) :: t()
  def put(%__MODULE__{}, %Path{resource_id: nil} = path, _value) do
    raise ArgumentError, "cannot store a value at #{Path.format(path)}: not a Resource path"
  end

  def put(%__MODULE__{} = tree, %Path{} = path, value) do
    tree
    |> create_instance(path.object_id, path.object_instance_id)
    |> put_key(to_key(path), value)
  end

  @doc "Fetch the value at a Resource path. `:error` when unset."
  @spec fetch(t(), Path.t()) :: {:ok, value()} | :error
  def fetch(%__MODULE__{} = tree, %Path{} = path), do: Map.fetch(tree.values, to_key(path))

  @doc "Delete the value at a Resource path. No-op when unset."
  @spec delete(t(), Path.t()) :: t()
  def delete(%__MODULE__{} = tree, %Path{} = path) do
    %{tree | values: Map.delete(tree.values, to_key(path))}
  end

  @doc """
  Every `{Wick.Path, value}` pair at or under `path`, in ascending path order.

  This is what a Read resolves to: a Resource path yields at most one pair, an Object
  Instance path yields its Resources, an Object path yields every Instance's Resources.

  ## Examples

      iex> tree = Wick.Object.Tree.from_map(%{
      ...>   3 => %{0 => %{9 => {:integer, 87}, 0 => {:string, "ACME"}}}
      ...> })
      iex> {:ok, path} = Wick.Path.parse("/3/0")
      iex> Wick.Object.Tree.subtree(tree, path) |> Enum.map(fn {p, _v} -> Wick.Path.format(p) end)
      ["/3/0/0", "/3/0/9"]
  """
  @spec subtree(t(), Path.t()) :: [{Path.t(), value()}]
  def subtree(%__MODULE__{} = tree, %Path{} = path) do
    prefix = to_key(path)

    tree.values
    |> Enum.filter(fn {key, _value} -> under?(key, prefix) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {from_key(key), value} end)
  end

  @doc """
  True when anything exists at `path` — a set Resource, or an Object Instance, or an Object
  with at least one Instance. This is the `4.04 Not Found` test.

  ## Examples

      iex> tree = Wick.Object.Tree.from_map(%{3 => %{0 => %{9 => {:integer, 87}}}})
      iex> {:ok, unset} = Wick.Path.parse("/3/0/1")
      iex> {:ok, instance} = Wick.Path.parse("/3/0")
      iex> {:ok, missing} = Wick.Path.parse("/9")
      iex> {Wick.Object.Tree.exists?(tree, instance), Wick.Object.Tree.exists?(tree, unset),
      ...>  Wick.Object.Tree.exists?(tree, missing)}
      {true, false, false}
  """
  @spec exists?(t(), Path.t()) :: boolean()
  def exists?(%__MODULE__{} = tree, %Path{resource_id: nil, object_instance_id: nil} = path) do
    instance_ids(tree, path.object_id) != []
  end

  def exists?(%__MODULE__{} = tree, %Path{resource_id: nil} = path) do
    instance?(tree, path.object_id, path.object_instance_id)
  end

  def exists?(%__MODULE__{} = tree, %Path{} = path) do
    Map.has_key?(tree.values, to_key(path))
  end

  # ── Attributes ─────────────────────────────────────────────────────────────

  @doc """
  The attributes in force at `path`. An unset path returns an empty `Wick.Attributes`, so
  callers never have to nil-check.
  """
  @spec attributes(t(), Path.t()) :: Attributes.t()
  def attributes(%__MODULE__{} = tree, %Path{} = path) do
    Map.get(tree.attributes, to_key(path), %Attributes{})
  end

  @doc """
  Fold `incoming` onto the attributes at `path`, honouring `:clear` — what a client does
  on receiving Write-Attributes.

  ## Examples

      iex> {:ok, path} = Wick.Path.parse("/3303/0/5700")
      iex> tree = Wick.Object.Tree.put_attributes(
      ...>   Wick.Object.Tree.new(), path, %Wick.Attributes{pmin: 10, pmax: 60}
      ...> )
      iex> tree = Wick.Object.Tree.put_attributes(tree, path, %Wick.Attributes{pmax: :clear})
      iex> Wick.Object.Tree.attributes(tree, path)
      %Wick.Attributes{pmin: 10}
  """
  @spec put_attributes(t(), Path.t(), Attributes.t()) :: t()
  def put_attributes(%__MODULE__{} = tree, %Path{} = path, %Attributes{} = incoming) do
    merged = Attributes.merge(attributes(tree, path), incoming)
    %{tree | attributes: Map.put(tree.attributes, to_key(path), merged)}
  end

  # ── CoRE Links ─────────────────────────────────────────────────────────────

  @doc """
  Every Object Instance as a CoRE Link — the payload for a Register or an Update.

  ## Examples

      iex> tree = Wick.Object.Tree.from_map(%{1 => %{0 => %{}}, 3 => %{0 => %{}}})
      iex> Wick.Object.Tree.links(tree) |> Enum.map(& &1.target)
      ["/1/0", "/3/0"]
  """
  @spec links(t()) :: [CoreLink.Link.t()]
  def links(%__MODULE__{} = tree) do
    tree.instances
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn {object_id, instance_id} ->
      %CoreLink.Link{target: "/#{object_id}/#{instance_id}"}
    end)
  end

  @doc """
  The CoRE Links a Discover on `path` should return: the target itself, then everything
  under it, each carrying the attributes in force at that level (LwM2M 1.2 §6.4.9).

  ## Examples

      iex> tree = Wick.Object.Tree.from_map(%{3303 => %{0 => %{5700 => {:float, 1.0}}}})
      iex> {:ok, path} = Wick.Path.parse("/3303/0")
      iex> Wick.Object.Tree.discover(tree, path) |> Enum.map(& &1.target)
      ["/3303/0", "/3303/0/5700"]
  """
  @spec discover(t(), Path.t()) :: [CoreLink.Link.t()]
  def discover(%__MODULE__{} = tree, %Path{} = path) do
    descendants =
      tree
      |> subtree(path)
      |> Enum.map(fn {resource_path, _value} -> resource_path end)

    [path | descendants]
    |> Enum.uniq()
    |> Enum.map(fn target ->
      %CoreLink.Link{
        target: Path.format(target),
        params: Attributes.to_link_params(attributes(tree, target))
      }
    end)
  end

  # ── SenML ──────────────────────────────────────────────────────────────────

  @doc """
  Read `path` as a `Wick.Senml.Pack`, one record per Resource, names absolute.

  Used for a Read whose target spans more than one Resource, and for building Notify and
  Send payloads.

  ## Examples

      iex> tree = Wick.Object.Tree.from_map(%{3303 => %{0 => %{5700 => {:float, 22.5}}}})
      iex> {:ok, path} = Wick.Path.parse("/3303/0")
      iex> pack = Wick.Object.Tree.to_pack(tree, [path])
      iex> Enum.map(pack.records, &{&1.name, &1.number_value})
      [{"/3303/0/5700", 22.5}]
  """
  @spec to_pack(t(), [Path.t()]) :: Pack.t()
  def to_pack(%__MODULE__{} = tree, paths) when is_list(paths) do
    paths
    |> Enum.flat_map(&subtree(tree, &1))
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {path, value} -> to_record(Path.format(path), value) end)
    |> Pack.new()
  end

  @doc """
  Apply a `Wick.Senml.Pack` to the tree — what a Write or Write-Composite does.

  Record names are resolved against their base name, then interpreted as paths. When `base`
  is given, a name is **relative to it unless it starts with `/`** — a Write on `/3/0` sends
  records named `9`, meaning `/3/0/9`. Without a leading slash there is no other way to tell
  the two apart, since `9` is itself a syntactically valid absolute path.

  An **empty** name resolves to `base` itself. That is how a Write targeting a single Resource
  is encoded ([RFC 8428 §4.5.1](https://www.rfc-editor.org/rfc/rfc8428#section-4.5.1)): the
  request URI carries the path and the record carries only the value.

  Returns `{:error, %Wick.Error{code: :invalid_path}}` if a record's name does not parse, or
  `:not_a_resource_path` if it resolves to an Object or Object Instance — there is nothing to
  store at those levels.

  ## Recovering the LwM2M type

  SenML is only partially self-describing: it distinguishes numbers from strings from
  booleans from opaque, but not an Integer from an Unsigned Integer from a Time, nor a String
  from a CoRE Link. Without help, this function stores the closest tag it can infer from the
  wire shape.

  Pass a `:model` — a `Wick.Object.Registry`, or anything else `Wick.Model` accepts — and each
  value is stored under the type its Object definition declares:

      iex> definition = %Wick.Object.Definition{
      ...>   object_id: 3, name: "Device", multiple_instances: :single, mandatory: :mandatory,
      ...>   resources: [
      ...>     %Wick.Object.Resource{
      ...>       resource_id: 13, name: "Current Time", type: :time,
      ...>       operations: [:read], multiple_instances: :single, mandatory: :optional
      ...>     }
      ...>   ]
      ...> }
      iex> registry = Wick.Object.Registry.from_definitions([definition])
      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{name: "/3/0/13", number_value: 1_700_000_000}])
      iex> {:ok, tree} = Wick.Object.Tree.apply_pack(Wick.Object.Tree.new(), pack, model: registry)
      iex> {:ok, path} = Wick.Path.parse("/3/0/13")
      iex> Wick.Object.Tree.fetch(tree, path)
      {:ok, {:time, 1_700_000_000}}

  A value whose wire shape cannot satisfy the declared type — a string sent to an Integer
  Resource — is a protocol error, and returns
  `{:error, %Wick.Error{code: :type_mismatch}}`. That is what lets a device answer a bad Write
  with `4.00 Bad Request` instead of silently storing the wrong thing. With no `:model` there
  is no declared type, so no mismatch is possible and this function behaves exactly as it did
  before.

  ## Options

  * `:base` — the request path. A record name is relative to it unless it starts with `/`;
    an empty name resolves to the base itself. Defaults to `nil`.
  * `:model` — anything `Wick.Model` accepts. Defaults to `nil`.

  ## Examples

      iex> pack = Wick.Senml.Pack.new([%Wick.Senml.Record{name: "/3303/0/5700", number_value: 30.0}])
      iex> {:ok, tree} = Wick.Object.Tree.apply_pack(Wick.Object.Tree.new(), pack)
      iex> {:ok, path} = Wick.Path.parse("/3303/0/5700")
      iex> Wick.Object.Tree.fetch(tree, path)
      {:ok, {:float, 30.0}}
  """
  @spec apply_pack(t(), Pack.t(), Path.t() | nil | keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def apply_pack(tree, pack, base_or_opts \\ [])

  # `apply_pack(tree, pack, base)` predates the options list and is how every call site in
  # the demos reads. Kept as a head rather than deprecated: passing the request path
  # positionally is the overwhelmingly common case, and `base: path` reads worse.
  def apply_pack(%__MODULE__{} = tree, %Pack{} = pack, %Path{} = base) do
    apply_pack(tree, pack, base: base)
  end

  def apply_pack(%__MODULE__{} = tree, %Pack{} = pack, nil) do
    apply_pack(tree, pack, [])
  end

  def apply_pack(%__MODULE__{} = tree, %Pack{} = pack, opts) when is_list(opts) do
    base = Keyword.get(opts, :base)
    model = Keyword.get(opts, :model)

    pack
    |> Pack.resolve()
    |> Enum.reduce_while({:ok, tree}, fn {name, _time, record}, {:ok, acc} ->
      with {:ok, path} <- resolve_write_path(name, base),
           {:ok, value} <- from_record(record, Wick.Model.resource_type(model, path), path) do
        {:cont, {:ok, put(acc, path, value)}}
      else
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp put_key(%__MODULE__{} = tree, key, value) do
    %{tree | values: Map.put(tree.values, key, value)}
  end

  defp to_key(%Path{} = path) do
    {path.object_id, path.object_instance_id, path.resource_id, path.resource_instance_id}
  end

  defp from_key({object_id, instance_id, resource_id, resource_instance_id}) do
    %Path{
      object_id: object_id,
      object_instance_id: instance_id,
      resource_id: resource_id,
      resource_instance_id: resource_instance_id
    }
  end

  # A key is under a prefix when every non-nil component of the prefix matches. A nil in the
  # prefix means "any", which is how a shorter path covers everything beneath it.
  defp under?(key, prefix) do
    [Tuple.to_list(key), Tuple.to_list(prefix)]
    |> Enum.zip()
    |> Enum.all?(fn
      {_component, nil} -> true
      {component, expected} -> component == expected
    end)
  end

  defp resolve_write_path(name, base) do
    with {:ok, path} <- parse_write_name(name, base), do: require_resource_path(path)
  end

  defp parse_write_name(name, nil), do: Path.parse(name)
  defp parse_write_name("", %Path{} = base), do: {:ok, base}
  defp parse_write_name("/" <> _rest = name, _base), do: Path.parse(name)

  defp parse_write_name(name, %Path{} = base) do
    Path.parse(Path.format(base) <> "/" <> name)
  end

  defp require_resource_path(%Path{resource_id: nil} = path) do
    {:error,
     Error.new(
       :not_a_resource_path,
       "cannot store a value at #{Path.format(path)}: not a Resource path",
       path: Path.format(path)
     )}
  end

  defp require_resource_path(%Path{} = path), do: {:ok, path}

  defp to_record(name, {:string, value}), do: %Record{name: name, string_value: value}
  defp to_record(name, {:core_link, value}), do: %Record{name: name, string_value: value}
  defp to_record(name, {:boolean, value}), do: %Record{name: name, boolean_value: value}
  defp to_record(name, {:opaque, value}), do: %Record{name: name, opaque_value: value}
  defp to_record(name, {:integer, value}), do: %Record{name: name, number_value: value}
  defp to_record(name, {:unsigned_integer, value}), do: %Record{name: name, number_value: value}
  defp to_record(name, {:float, value}), do: %Record{name: name, number_value: value}

  # Time is seconds since the Unix epoch, not a `DateTime` — see `Wick.Value`. Catching the
  # struct here costs one clause and turns what was a `FunctionClauseError` raised deep in
  # `Wick.Codec.SenmlJson.encode_number/1` into something that names the actual mistake.
  defp to_record(name, {:time, %DateTime{} = value}) do
    raise ArgumentError,
          "#{name}: LwM2M Time is an integer count of seconds since the Unix epoch, got " <>
            "#{inspect(value)}. Convert with DateTime.to_unix/1."
  end

  defp to_record(name, {:time, value}), do: %Record{name: name, number_value: value}

  defp to_record(name, {:objlnk, {object_id, instance_id}}) do
    %Record{name: name, object_link_value: "#{object_id}:#{instance_id}"}
  end

  defp to_record(name, {:none, _value}), do: %Record{name: name}

  # With no declared type, recover the closest tag from the wire shape. SenML cannot tell an
  # Integer from an Unsigned Integer from a Time, nor a String from a CoRE Link, so this is a
  # narrowing — see `apply_pack/3` and pass a `:model` to avoid it.
  defp from_record(%Record{} = record, nil, _path) do
    tagged =
      case Record.value_type(record) do
        :number -> number_tag(record.number_value)
        :boolean -> {:boolean, record.boolean_value}
        :string -> {:string, record.string_value}
        :opaque -> {:opaque, record.opaque_value}
        :objlnk -> {:objlnk, parse_objlnk(record.object_link_value)}
        :none -> {:none, nil}
      end

    {:ok, tagged}
  end

  defp from_record(%Record{} = record, declared, path) do
    case coerce(declared, Record.value_type(record), record) do
      {:ok, value} -> {:ok, {declared, value}}
      :error -> {:error, type_mismatch(declared, record, path)}
    end
  end

  # Coercing a SenML value to its declared LwM2M type. The pairs that are *not* here are the
  # point: a string arriving for an Integer Resource has no sensible reading, and silently
  # storing it is how a device ends up serving garbage it will never notice.
  defp coerce(:string, :string, record), do: {:ok, record.string_value}
  defp coerce(:core_link, :string, record), do: {:ok, record.string_value}
  defp coerce(:opaque, :opaque, record), do: {:ok, record.opaque_value}
  defp coerce(:boolean, :boolean, record), do: {:ok, record.boolean_value}
  defp coerce(:objlnk, :objlnk, record), do: {:ok, parse_objlnk(record.object_link_value)}
  defp coerce(:none, :none, _record), do: {:ok, nil}

  defp coerce(:integer, :number, %Record{number_value: v}) when is_integer(v), do: {:ok, v}

  defp coerce(:unsigned_integer, :number, %Record{number_value: v})
       when is_integer(v) and v >= 0,
       do: {:ok, v}

  defp coerce(:time, :number, %Record{number_value: v}) when is_integer(v), do: {:ok, v}

  # A Float Resource may legitimately arrive as a whole number — SenML emits `22` rather than
  # `22.0` when the value happens to be integral, and both JSON and CBOR preserve that
  # distinction on the wire. Widening is the only coercion that runs in this direction.
  defp coerce(:float, :number, %Record{number_value: v}) when is_float(v), do: {:ok, v}
  defp coerce(:float, :number, %Record{number_value: v}) when is_integer(v), do: {:ok, v * 1.0}

  defp coerce(_declared, _actual, _record), do: :error

  defp type_mismatch(declared, %Record{} = record, %Path{} = path) do
    Error.new(
      :type_mismatch,
      "#{Path.format(path)} is declared #{inspect(declared)} but the value is " <>
        "#{inspect(Record.value_type(record))} (#{inspect(Record.value(record))})",
      path: Path.format(path),
      declared: declared,
      actual: Record.value_type(record)
    )
  end

  defp number_tag(value) when is_integer(value), do: {:integer, value}
  defp number_tag(value) when is_float(value), do: {:float, value}

  defp parse_objlnk(raw) do
    case String.split(raw, ":", parts: 2) do
      [object_id, instance_id] -> {String.to_integer(object_id), String.to_integer(instance_id)}
      _malformed -> {0, 0}
    end
  end
end

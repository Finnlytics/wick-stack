defmodule Wick.Value do
  @moduledoc """
  LwM2M Resource value types.

  LwM2M defines a closed set of Resource value types per
  [OMA LwM2M 1.2 §7.4](https://www.openmobilealliance.org/release/LightweightM2M/V1_2_1-20221209-A/OMA-TS-LightweightM2M_Core-V1_2_1-20221209-A.pdf):

  | LwM2M type | Elixir representation |
  | --- | --- |
  | String | `binary()` (UTF-8) |
  | Integer | `integer()` |
  | Unsigned Integer | `non_neg_integer()` |
  | Float | `float()` |
  | Boolean | `boolean()` |
  | Opaque | `binary()` (raw bytes) |
  | Time | `integer()` — seconds since the Unix epoch |
  | Objlnk | `{Wick.Path.id(), Wick.Path.id()}` (object_id, instance_id) |
  | Core Link | `binary()` (the raw CoRE Link Format string) |
  | None | `nil` (Execute resources have no value) |

  ## Time is an integer, not a `DateTime`

  Every LwM2M wire format carries Time as an integer count of seconds since the Unix epoch —
  SenML puts it in `v`, Plain Text renders it as digits, TLV as a signed integer. Wick keeps
  that representation all the way through, so the codecs stay total functions over wire
  types and never depend on an Object model being present to encode.

  Converting to `DateTime` is a one-liner at your own boundary, and is the caller's choice
  because the useful target type varies (`DateTime`, `NaiveDateTime`, a unix timestamp in a
  database column):

      {:ok, {:time, seconds}} = Wick.Object.Tree.fetch(tree, path)
      DateTime.from_unix!(seconds)

  This module is intentionally a type-only API at this stage. Codec modules use these types
  directly when constructing/encoding records.
  """

  @typedoc "Tag identifying the value's LwM2M data type."
  @type type ::
          :string
          | :integer
          | :unsigned_integer
          | :float
          | :boolean
          | :opaque
          | :time
          | :objlnk
          | :core_link
          | :none

  @typedoc "An ObjectLink (`Objlnk`) value: `{object_id, instance_id}`."
  @type objlnk :: {Wick.Path.id(), Wick.Path.id()}

  @typedoc "An LwM2M Resource value."
  @type t ::
          binary()
          | integer()
          | float()
          | boolean()
          | objlnk()
          | nil

  @typedoc """
  A Resource value carrying its LwM2M type — how values are stored in a `Wick.Object.Tree`
  and what the codecs encode from.
  """
  @type tagged :: {type(), t()}

  @doc """
  Every LwM2M Resource type, in the order they appear in OMA LwM2M 1.2 §7.4.

  The single source of truth for the type vocabulary: `Wick.Object.Resource` and
  `Wick.Object.Ddf` resolve DDF `<Type>` elements into this set, so the model layer and the
  value layer cannot drift apart.

  ## Examples

      iex> :time in Wick.Value.types()
      true

      iex> length(Wick.Value.types())
      10
  """
  @spec types() :: [type()]
  def types do
    [
      :string,
      :integer,
      :unsigned_integer,
      :float,
      :boolean,
      :opaque,
      :time,
      :objlnk,
      :core_link,
      :none
    ]
  end
end

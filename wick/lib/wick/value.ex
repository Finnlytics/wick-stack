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
  | Time | `DateTime.t()` |
  | Objlnk | `{Wick.Path.id(), Wick.Path.id()}` (object_id, instance_id) |
  | Core Link | `binary()` (the raw CoRE Link Format string) |
  | None | `nil` (Execute resources have no value) |

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
          | DateTime.t()
          | objlnk()
          | nil
end

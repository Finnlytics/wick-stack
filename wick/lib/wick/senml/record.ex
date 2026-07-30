defmodule Wick.Senml.Record do
  @moduledoc """
  A single SenML record.

  Direct port of Leshan's [`SenMLRecord`](https://github.com/eclipse-leshan/leshan/blob/leshan-1.5.0/leshan-core/src/main/java/org/eclipse/leshan/senml/SenMLRecord.java).
  Each record describes one measurement and may carry optional base-prefix fields
  (`base_name`, `base_time`) that apply to subsequent records in the same `Wick.Senml.Pack`
  until overridden.

  ## Wire-format labels

  Each field has a stable label/integer used by SenML wire formats:

  | Elixir field         | SenML label | CBOR label | RFC 8428 §  |
  |----------------------|-------------|------------|-------------|
  | `:base_name`         | `bn`        | `-2`       | 4.5.1       |
  | `:base_time`         | `bt`        | `-3`       | 4.5.4       |
  | `:name`              | `n`         |  `0`       | 4.5.2       |
  | `:time`              | `t`         |  `6`       | 4.5.5       |
  | `:number_value`      | `v`         |  `2`       | 4.5.6       |
  | `:string_value`      | `vs`        |  `3`       | 4.5.7       |
  | `:boolean_value`     | `vb`        |  `4`       | 4.5.8       |
  | `:opaque_value`      | `vd`        |  `8`       | 4.5.10      |
  | `:object_link_value` | `vlo`       | `"vlo"`    | LwM2M ext   |

  ## Validation

  Exactly one of the value fields (`:number_value`, `:string_value`, `:boolean_value`,
  `:opaque_value`, `:object_link_value`) is normally expected. This struct does **not**
  enforce that — validation happens at encode time in `Wick.Codec.SenmlCbor` and friends,
  mirroring Leshan's `allowNoValue` pattern. Read-Composite payloads, for example, contain
  records with no value field.

  ## Examples

      iex> r = %Wick.Senml.Record{name: "/3/0/9", number_value: 87}
      iex> Wick.Senml.Record.value_type(r)
      :number
      iex> Wick.Senml.Record.value(r)
      87

      iex> Wick.Senml.Record.value_type(%Wick.Senml.Record{name: "/3/0/9"})
      :none

  ## See also

  * [RFC 8428 §4 — Sensor Measurement Lists (SenML)](https://www.rfc-editor.org/rfc/rfc8428#section-4)
  * Leshan: [`SenMLRecord.java`](https://github.com/eclipse-leshan/leshan/blob/leshan-1.5.0/leshan-core/src/main/java/org/eclipse/leshan/senml/SenMLRecord.java)
  """

  @typedoc "Tag identifying which value field carries the record's measurement."
  @type value_type :: :string | :number | :boolean | :opaque | :objlnk | :none

  @typedoc "An LwM2M ObjectLink value (formatted per LwM2M as `\"object:instance\"`)."
  @type object_link :: String.t()

  @typedoc "The value held by a record, of whichever value-type is set."
  @type value :: integer() | float() | String.t() | binary() | boolean() | nil

  @typedoc "A SenML record."
  @type t :: %__MODULE__{
          base_name: String.t() | nil,
          base_time: integer() | float() | nil,
          name: String.t() | nil,
          time: integer() | float() | nil,
          number_value: integer() | float() | nil,
          string_value: String.t() | nil,
          boolean_value: boolean() | nil,
          opaque_value: binary() | nil,
          object_link_value: object_link() | nil
        }

  defstruct [
    :base_name,
    :base_time,
    :name,
    :time,
    :number_value,
    :string_value,
    :boolean_value,
    :opaque_value,
    :object_link_value
  ]

  @doc """
  Returns which value field is set on the record.

  Mirrors Leshan's [`SenMLRecord.getType()`](https://github.com/eclipse-leshan/leshan/blob/leshan-1.5.0/leshan-core/src/main/java/org/eclipse/leshan/senml/SenMLRecord.java#L59)
  exactly. Returns `:none` if no value is set (Leshan returns `null`).

  Precedence when multiple value fields happen to be set: `boolean > number > objlnk >
  string > opaque`. This is Leshan's order — kept identical for behaviour-equivalence on
  malformed/edge inputs.

  ## Examples

      iex> Wick.Senml.Record.value_type(%Wick.Senml.Record{number_value: 87})
      :number

      iex> Wick.Senml.Record.value_type(%Wick.Senml.Record{boolean_value: true})
      :boolean

      iex> Wick.Senml.Record.value_type(%Wick.Senml.Record{string_value: "hello"})
      :string

      iex> Wick.Senml.Record.value_type(%Wick.Senml.Record{opaque_value: <<1, 2>>})
      :opaque

      iex> Wick.Senml.Record.value_type(%Wick.Senml.Record{object_link_value: "1:0"})
      :objlnk

      iex> Wick.Senml.Record.value_type(%Wick.Senml.Record{name: "/3/0/9"})
      :none

      iex> Wick.Senml.Record.value_type(%Wick.Senml.Record{boolean_value: true, number_value: 5})
      :boolean
  """
  @spec value_type(t()) :: value_type()
  def value_type(%__MODULE__{} = record) do
    cond do
      record.boolean_value != nil -> :boolean
      record.number_value != nil -> :number
      record.object_link_value != nil -> :objlnk
      record.string_value != nil -> :string
      record.opaque_value != nil -> :opaque
      true -> :none
    end
  end

  @doc """
  Returns the value held by the record, irrespective of which field carries it.

  Mirrors Leshan's [`getResourceValue()`](https://github.com/eclipse-leshan/leshan/blob/leshan-1.5.0/leshan-core/src/main/java/org/eclipse/leshan/senml/SenMLRecord.java#L114).
  Returns `nil` if no value is set. Precedence matches `value_type/1`.

  ## Examples

      iex> Wick.Senml.Record.value(%Wick.Senml.Record{number_value: 87})
      87

      iex> Wick.Senml.Record.value(%Wick.Senml.Record{string_value: "hello"})
      "hello"

      iex> Wick.Senml.Record.value(%Wick.Senml.Record{name: "/3/0/9"})
      nil
  """
  @spec value(t()) :: value()
  def value(%__MODULE__{} = record) do
    case value_type(record) do
      :boolean -> record.boolean_value
      :number -> record.number_value
      :objlnk -> record.object_link_value
      :string -> record.string_value
      :opaque -> record.opaque_value
      :none -> nil
    end
  end
end

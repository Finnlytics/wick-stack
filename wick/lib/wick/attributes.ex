defmodule Wick.Attributes do
  @moduledoc """
  LwM2M Attributes — the `<` NOTIFICATION `>` and `<` PROPERTY `>` class attributes that
  tune when a client emits a Notification (OMA TS LwM2M Core 1.2, §5.1).

  Attributes travel two ways:

  * **Write-Attributes** (§6.4.12) — the server sets them with a `PUT` whose Uri-Query
    carries `pmin=10&pmax=60&gt=25`. `to_query/1` and `from_query/1` cover this.
  * **Discover** (§6.4.9) — the client reports the attributes currently in force as CoRE
    Link Format parameters on each link. `to_link_params/1` and `from_link_params/1`
    cover this.

  ## Attributes

  | Attribute | Field      | Class        | Applies to        | Meaning |
  |-----------|------------|--------------|-------------------|---------|
  | `dim`     | `:dim`     | property     | Multi-Resource    | Number of Resource Instances (read-only, client-reported) |
  | `ssid`    | `:ssid`    | property     | Object Instance   | Short Server ID (read-only, client-reported) |
  | `uri`     | `:uri`     | property     | Object Instance   | Server URI (read-only, client-reported) |
  | `ver`     | `:ver`     | property     | Object            | Object version (read-only, client-reported) |
  | `pmin`    | `:pmin`    | notification | any               | Minimum seconds between two Notifications |
  | `pmax`    | `:pmax`    | notification | any               | Maximum seconds without a Notification |
  | `gt`      | `:gt`      | notification | numeric Resource  | Notify when the value crosses above this threshold |
  | `lt`      | `:lt`      | notification | numeric Resource  | Notify when the value crosses below this threshold |
  | `st`      | `:st`      | notification | numeric Resource  | Notify when the value changes by at least this step |
  | `epmin`   | `:epmin`   | notification | any               | Minimum seconds between two evaluations (1.2+) |
  | `epmax`   | `:epmax`   | notification | any               | Maximum seconds between two evaluations (1.2+) |

  Every field is `nil` when unset. A `nil` is materially different from a zero: `pmin=0`
  means "no minimum period", while `pmin: nil` means "the server never set pmin, use the
  client default".

  ## Clearing an attribute

  Write-Attributes clears an attribute by sending the bare parameter name with no value —
  `?pmin` rather than `?pmin=10`. `from_query/1` decodes that to `:clear`, which is
  distinct from both `nil` (absent) and a number:

      iex> {:ok, attrs} = Wick.Attributes.from_query([{"pmin", nil}, {"pmax", "60"}])
      iex> {attrs.pmin, attrs.pmax}
      {:clear, 60}

  `merge/2` folds a decoded set onto an existing one, honouring `:clear`.

  ## Evaluating

  `should_notify?/3` implements the §5.1.2 decision for a numeric Resource. It is a pure
  function of the attributes, the candidate observation state, and the elapsed time — the
  caller owns the state and the clock, per Wick's no-processes charter.

  ## Examples

      iex> attrs = %Wick.Attributes{pmin: 10, pmax: 60, gt: 25.0}
      iex> Wick.Attributes.to_query(attrs)
      [{"pmin", 10}, {"pmax", 60}, {"gt", 25.0}]
  """

  alias Wick.Error

  @typedoc """
  An attribute value as decoded from the wire: a number, or `:clear` for the bare
  parameter form that removes the attribute.
  """
  @type value :: number() | :clear | nil

  @typedoc """
  An observation as it stands, for `should_notify?/3`.

  * `:last_value` — the value carried by the previous Notification, or `nil` if none.
  * `:since_last_ms` — milliseconds since the previous Notification, `nil` if none.
  """
  @type observation_state :: %{
          optional(:last_value) => term(),
          optional(:since_last_ms) => non_neg_integer() | nil
        }

  @typedoc "A set of LwM2M attributes. Every field is optional."
  @type t :: %__MODULE__{
          dim: non_neg_integer() | nil,
          ssid: non_neg_integer() | nil,
          uri: String.t() | nil,
          ver: String.t() | nil,
          pmin: value(),
          pmax: value(),
          gt: value(),
          lt: value(),
          st: value(),
          epmin: value(),
          epmax: value()
        }

  defstruct [:dim, :ssid, :uri, :ver, :pmin, :pmax, :gt, :lt, :st, :epmin, :epmax]

  # Wire name, struct field, and value shape. Order is the order attributes appear on the
  # wire — LwM2M does not mandate one, but a stable order makes tests and logs readable.
  @table [
    {"dim", :dim, :integer},
    {"ssid", :ssid, :integer},
    {"uri", :uri, :string},
    {"ver", :ver, :string},
    {"pmin", :pmin, :integer},
    {"pmax", :pmax, :integer},
    {"epmin", :epmin, :integer},
    {"epmax", :epmax, :integer},
    {"gt", :gt, :number},
    {"lt", :lt, :number},
    {"st", :st, :number}
  ]

  @notification_fields [:pmin, :pmax, :epmin, :epmax, :gt, :lt, :st]
  @property_fields [:dim, :ssid, :uri, :ver]

  @doc "The fields in the NOTIFICATION attribute class — the ones a server may write."
  @spec notification_fields() :: [atom()]
  def notification_fields, do: @notification_fields

  @doc "The fields in the PROPERTY attribute class — read-only, reported by the client."
  @spec property_fields() :: [atom()]
  def property_fields, do: @property_fields

  @doc """
  True when no attribute is set.

  ## Examples

      iex> Wick.Attributes.empty?(%Wick.Attributes{})
      true

      iex> Wick.Attributes.empty?(%Wick.Attributes{pmin: 0})
      false
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = attrs) do
    Enum.all?(@table, fn {_name, field, _shape} -> Map.fetch!(attrs, field) == nil end)
  end

  # ── Uri-Query form (Write-Attributes) ──────────────────────────────────────

  @doc """
  Encode an attribute set as `t:Wick.Wire.query/0` pairs for a Write-Attributes request.

  A `:clear` value emits the bare parameter name, which instructs the client to remove
  the attribute. `nil` fields are omitted.

  ## Examples

      iex> Wick.Attributes.to_query(%Wick.Attributes{pmin: 10, pmax: 60})
      [{"pmin", 10}, {"pmax", 60}]

      iex> Wick.Attributes.to_query(%Wick.Attributes{pmin: :clear})
      [{"pmin", nil}]

      iex> Wick.Attributes.to_query(%Wick.Attributes{})
      []
  """
  @spec to_query(t()) :: Wick.Wire.query()
  def to_query(%__MODULE__{} = attrs) do
    for {name, field, _shape} <- @table, value = Map.fetch!(attrs, field), value != nil do
      case value do
        :clear -> {name, nil}
        other -> {name, other}
      end
    end
  end

  @doc """
  Decode `t:Wick.Wire.query/0` pairs into an attribute set.

  Unrecognised parameters are ignored — a Write-Attributes URI may legitimately carry
  other query parameters. A recognised parameter whose value does not parse as the right
  shape is an error.

  ## Examples

      iex> {:ok, attrs} = Wick.Attributes.from_query([{"pmin", "10"}, {"gt", "22.5"}])
      iex> {attrs.pmin, attrs.gt}
      {10, 22.5}

      iex> {:ok, attrs} = Wick.Attributes.from_query([{"unknown", "x"}])
      iex> Wick.Attributes.empty?(attrs)
      true

      iex> {:error, err} = Wick.Attributes.from_query([{"pmin", "soon"}])
      iex> err.code
      :invalid_attribute
  """
  @spec from_query(Wick.Wire.query()) :: {:ok, t()} | {:error, Error.t()}
  def from_query(query) when is_list(query) do
    Enum.reduce_while(query, {:ok, %__MODULE__{}}, fn pair, {:ok, acc} ->
      case put_pair(acc, pair) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
  end

  # ── CoRE Link Format form (Discover) ───────────────────────────────────────

  @doc """
  Encode an attribute set as CoRE Link Format parameters, the form a Discover response
  carries on each link.

  Values become strings because `Wick.CoreLink` params are string-valued. `:clear` has no
  meaning in a Discover response and is dropped.

  ## Examples

      iex> Wick.Attributes.to_link_params(%Wick.Attributes{pmin: 10, gt: 22.5, dim: 3})
      %{"dim" => "3", "pmin" => "10", "gt" => "22.5"}
  """
  @spec to_link_params(t()) :: %{optional(String.t()) => String.t()}
  def to_link_params(%__MODULE__{} = attrs) do
    for {name, field, _shape} <- @table,
        value = Map.fetch!(attrs, field),
        value != nil and value != :clear,
        into: %{} do
      {name, stringify(value)}
    end
  end

  @doc """
  Decode CoRE Link Format parameters into an attribute set. The inverse of
  `to_link_params/1`.

  Link params that are not attributes (`rt`, `obs`, `ct`, …) are ignored.

  ## Examples

      iex> {:ok, attrs} = Wick.Attributes.from_link_params(%{"pmin" => "10", "obs" => ""})
      iex> attrs.pmin
      10
  """
  @spec from_link_params(%{optional(String.t()) => String.t()}) :: {:ok, t()} | {:error, Error.t()}
  def from_link_params(params) when is_map(params) do
    params
    |> Enum.sort_by(&elem(&1, 0))
    |> from_query()
  end

  # ── Folding ────────────────────────────────────────────────────────────────

  @doc """
  Fold `incoming` onto `current`, honouring `:clear`.

  A `nil` field in `incoming` leaves `current` untouched; a `:clear` removes it; anything
  else replaces it. This is what a client does when it receives Write-Attributes.

  ## Examples

      iex> current = %Wick.Attributes{pmin: 10, pmax: 60}
      iex> Wick.Attributes.merge(current, %Wick.Attributes{pmax: :clear, gt: 25})
      %Wick.Attributes{pmin: 10, pmax: nil, gt: 25}
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = current, %__MODULE__{} = incoming) do
    Enum.reduce(@table, current, fn {_name, field, _shape}, acc ->
      case Map.fetch!(incoming, field) do
        nil -> acc
        :clear -> Map.put(acc, field, nil)
        value -> Map.put(acc, field, value)
      end
    end)
  end

  # ── Evaluation ─────────────────────────────────────────────────────────────

  @doc """
  Decide whether a numeric Resource change warrants a Notification (§5.1.2).

  Pure: the caller supplies everything that varies. `state` is a map describing the
  observation as it stands:

  * `:last_value` — the value carried by the previous Notification, or `nil` if none has
    been sent yet.
  * `:since_last_ms` — milliseconds since the previous Notification, or `nil` if none has
    been sent yet.

  `value` is the current value. Returns `true` when a Notification should be sent.

  The rules, in the order they are applied:

  1. **No prior Notification** → always notify (the initial value after Observe).
  2. **`pmin` not yet elapsed** → never notify, whatever else is true. `pmin` is a hard
     floor on notification rate.
  3. **`pmax` elapsed** → notify, even if the value has not changed.
  4. **`st` (step)** → notify when `abs(value - last_value) >= st`.
  5. **`gt` / `lt` (thresholds)** → notify when the value *crosses* the threshold. A value
     that stays on the same side of a threshold does not re-trigger.
  6. **None of the above, but the value changed** → notify, unless `st`, `gt`, or `lt`
     is set. Setting any band attribute means "only tell me about these changes".

  ## Examples

      iex> attrs = %Wick.Attributes{pmin: 10}
      iex> Wick.Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 5_000}, 30)
      false

      iex> attrs = %Wick.Attributes{pmin: 10}
      iex> Wick.Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 15_000}, 30)
      true

      iex> attrs = %Wick.Attributes{pmax: 60}
      iex> Wick.Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 61_000}, 20)
      true

      iex> attrs = %Wick.Attributes{st: 5}
      iex> Wick.Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 1_000}, 22)
      false
      iex> Wick.Attributes.should_notify?(attrs, %{last_value: 20, since_last_ms: 1_000}, 26)
      true

      iex> Wick.Attributes.should_notify?(%Wick.Attributes{}, %{last_value: nil, since_last_ms: nil}, 1)
      true
  """
  @spec should_notify?(t(), observation_state(), term()) :: boolean()
  def should_notify?(%__MODULE__{} = attrs, state, value) do
    last_value = Map.get(state, :last_value)
    since_last_ms = Map.get(state, :since_last_ms)

    cond do
      is_nil(since_last_ms) -> true
      pmin_blocked?(attrs, since_last_ms) -> false
      pmax_elapsed?(attrs, since_last_ms) -> true
      true -> band_triggered?(attrs, last_value, value)
    end
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp pmin_blocked?(%__MODULE__{pmin: pmin}, since_last_ms) when is_number(pmin) do
    since_last_ms < pmin * 1_000
  end

  defp pmin_blocked?(%__MODULE__{}, _since_last_ms), do: false

  defp pmax_elapsed?(%__MODULE__{pmax: pmax}, since_last_ms) when is_number(pmax) do
    since_last_ms >= pmax * 1_000
  end

  defp pmax_elapsed?(%__MODULE__{}, _since_last_ms), do: false

  # With no band attributes set, any change notifies. With any band set, only that band
  # notifies — the server has asked to hear about a specific kind of change.
  defp band_triggered?(%__MODULE__{st: nil, gt: nil, lt: nil}, last_value, value) do
    last_value != value
  end

  defp band_triggered?(%__MODULE__{} = attrs, last_value, value) do
    step_triggered?(attrs.st, last_value, value) or
      crossed?(attrs.gt, last_value, value) or
      crossed?(attrs.lt, last_value, value)
  end

  defp step_triggered?(st, last_value, value)
       when is_number(st) and is_number(last_value) and is_number(value) do
    abs(value - last_value) >= st
  end

  defp step_triggered?(_st, _last_value, _value), do: false

  # A threshold fires only when the value moves from one side of it to the other.
  defp crossed?(threshold, last_value, value)
       when is_number(threshold) and is_number(last_value) and is_number(value) do
    below_before? = last_value < threshold
    below_now? = value < threshold
    below_before? != below_now?
  end

  defp crossed?(_threshold, _last_value, _value), do: false

  defp put_pair(acc, {name, raw}) do
    case List.keyfind(@table, name, 0) do
      nil -> {:ok, acc}
      {^name, field, shape} -> put_field(acc, field, name, shape, raw)
    end
  end

  defp put_field(acc, field, _name, _shape, nil), do: {:ok, Map.put(acc, field, :clear)}

  defp put_field(acc, field, name, shape, raw) do
    case cast(shape, raw) do
      {:ok, value} -> {:ok, Map.put(acc, field, value)}
      :error -> {:error, invalid(name, shape, raw)}
    end
  end

  defp cast(_shape, value) when is_number(value), do: {:ok, value}
  defp cast(:string, value) when is_binary(value), do: {:ok, value}

  defp cast(:integer, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp cast(:number, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> cast_float(value)
    end
  end

  defp cast(_shape, _value), do: :error

  defp cast_float(value) do
    case Float.parse(value) do
      {f, ""} -> {:ok, f}
      _ -> :error
    end
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_float(value), do: Wick.Json.encode_float(value)

  defp invalid(name, shape, raw) do
    Error.new(
      :invalid_attribute,
      "attribute #{name} expects #{shape}, got: #{inspect(raw)}",
      attribute: name,
      value: raw
    )
  end
end

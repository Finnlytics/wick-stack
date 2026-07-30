defmodule Wick.Error do
  @moduledoc """
  Structured error returned from Wick public functions.

  All fallible Wick functions return either `{:ok, result}` or `{:error, %Wick.Error{}}`. The
  error struct's `:code` is a stable atom that callers can pattern-match on; `:message` is for
  humans and may change between versions.

  ## Codes

  Codes are namespaced by domain, e.g. `:malformed_cbor`, `:unknown_object_id`, `:invalid_path`.
  Concrete codes are documented on the function that returns them.

  ## Examples

      iex> err = %Wick.Error{code: :invalid_path, message: "object_id must be non-negative"}
      iex> err.code
      :invalid_path
  """

  @typedoc "Stable, pattern-matchable error code."
  @type code :: atom()

  @typedoc """
  Optional metadata describing the failure context.

  Keys are domain-specific; values must be safely `inspect`able.
  """
  @type meta :: %{optional(atom()) => term()}

  @typedoc "A Wick error."
  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          meta: meta()
        }

  @enforce_keys [:code, :message]
  defstruct code: nil, message: "", meta: %{}

  @doc """
  Build a new error.

  ## Examples

      iex> err = Wick.Error.new(:invalid_path, "object_id must be non-negative")
      iex> err.code
      :invalid_path
      iex> err.meta
      %{}

      iex> err = Wick.Error.new(:malformed_cbor, "unexpected end of input", offset: 12)
      iex> err.meta
      %{offset: 12}
  """
  @spec new(code(), String.t(), keyword()) :: t()
  def new(code, message, meta \\ []) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: message, meta: Map.new(meta)}
  end
end

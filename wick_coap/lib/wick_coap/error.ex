defmodule WickCoap.Error do
  @moduledoc """
  Structured error returned from WickCoap public functions.

  All fallible WickCoap functions return either `{:ok, result}` or `{:error, %WickCoap.Error{}}`.
  The error struct's `:code` is a stable atom that callers can pattern-match on; `:message`
  is for humans and may change between versions.
  """

  @typedoc "Stable, pattern-matchable error code."
  @type code :: atom()

  @typedoc "Optional metadata describing the failure context."
  @type meta :: %{optional(atom()) => term()}

  @typedoc "A WickCoap error."
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

      iex> err = WickCoap.Error.new(:malformed_message, "header truncated")
      iex> err.code
      :malformed_message
  """
  @spec new(code(), String.t(), keyword()) :: t()
  def new(code, message, meta \\ []) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: message, meta: Map.new(meta)}
  end
end

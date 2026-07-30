defmodule Wick.CoreLink do
  @moduledoc """
  CoRE Link Format encoder and decoder per [RFC 6690](https://www.rfc-editor.org/rfc/rfc6690).

  CoRE Link Format is the payload of CoAP's `/.well-known/core` resource and of the
  LwM2M Registration / Update messages (RFC 6690 §2 — `application/link-format`,
  Content-Format `40`). A document is a comma-separated list of *link-values*; each
  link-value is `<URI-Reference>` optionally followed by `;name=value` link-params.

  Example LwM2M registration body:

      </>;rt="oma.lwm2m";ct=11543,</1/0>,</3/0>,</5>

  The parser is forgiving with whitespace between tokens but strict about the angle-
  bracket-delimited target and quoted parameter values, which is what the RFC demands.
  Zero runtime dependencies — hand-written against the grammar.

  ## Types

  A link is a `%Wick.CoreLink.Link{target: "/path", params: %{"rt" => "oma.lwm2m"}}`.
  Parameter values are always strings on decode — quoted strings have their surrounding
  quotes stripped; bare tokens are kept verbatim. On encode, values that match the
  RFC 7230 `token` grammar are emitted bare; everything else is double-quoted with
  internal `"` and `\\` backslash-escaped.

  ## Examples

      iex> Wick.CoreLink.decode("</1/0>,</3>;rt=\\"oma.lwm2m\\"")
      {:ok, [
        %Wick.CoreLink.Link{target: "/1/0", params: %{}},
        %Wick.CoreLink.Link{target: "/3", params: %{"rt" => "oma.lwm2m"}}
      ]}

      iex> Wick.CoreLink.encode([
      ...>   %Wick.CoreLink.Link{target: "/1/0", params: %{}},
      ...>   %Wick.CoreLink.Link{target: "/3", params: %{"rt" => "oma.lwm2m"}}
      ...> ])
      "</1/0>,</3>;rt=\\"oma.lwm2m\\""
  """

  defmodule Link do
    @moduledoc """
    One link-value: a URI-reference target plus a map of link-parameters.

    The `params` map stores raw string values. Callers that expect numeric values
    (`dim`, `sz`, `ct`) are responsible for converting via `Integer.parse/1`.
    """

    @type t :: %__MODULE__{
            target: String.t(),
            params: %{optional(String.t()) => String.t()}
          }

    defstruct target: "", params: %{}
  end

  @doc "Content-Format value (40) for `application/link-format` (RFC 6690 §7.2)."
  @spec content_format() :: 40
  def content_format, do: 40

  # ── Encode ──────────────────────────────────────────────────────────────────

  @doc """
  Encode a list of `Link`s to the RFC 6690 wire form. Returns an iodata-converted
  binary; callers send it as the CoAP payload alongside Content-Format `40`.
  """
  @spec encode([Link.t()]) :: binary()
  def encode(links) when is_list(links) do
    links
    |> Enum.map(&encode_link/1)
    |> Enum.intersperse(",")
    |> IO.iodata_to_binary()
  end

  defp encode_link(%Link{target: target, params: params}) do
    [?<, target, ?>, encode_params(params)]
  end

  defp encode_params(params) when map_size(params) == 0, do: []

  defp encode_params(params) do
    # Sort by name so output is deterministic and tests can compare strings.
    params
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> [?;, k, ?=, encode_value(v)] end)
  end

  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_binary(value), do: [?", escape_quoted(value), ?"]
  defp encode_value(value), do: encode_value(to_string(value))

  # RFC 6690 `tchar` (same as RFC 7230): the narrow set used for *parameter names* and
  # the only chars that may appear in a bare token-form value if we wanted strict
  # compliance. On encode we always quote string values for interop with Leshan, so
  # this is only used by the decoder to extract `parmname`.
  defp tchar?(c)
       when c in ?A..?Z
       when c in ?a..?z
       when c in ?0..?9,
       do: true

  defp tchar?(c) when c in ~c"!#$%&'*+-.^_`|~", do: true
  defp tchar?(_), do: false

  # RFC 6690 `ptokenchar`: the wider set used for bare `ptoken` values. Adds `(`, `)`,
  # `/`, `:`, `<`, `=`, `>`, `?`, `@`, `[`, `]`, `{`, `}`. Used by the decoder to
  # accept bare values like integers (`ct=11543`) and tokens (`rt=oma.lwm2m`).
  defp ptokenchar?(c) when c in ~c"()/:<=>?@[]{}", do: true
  defp ptokenchar?(c), do: tchar?(c)

  defp escape_quoted(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.map(fn
      ?" -> ~c"\\\""
      ?\\ -> ~c"\\\\"
      c -> [c]
    end)
  end

  # ── Decode ──────────────────────────────────────────────────────────────────

  @doc """
  Decode an RFC 6690 wire-form document.

  Returns `{:ok, [Link.t()]}` on success, `{:error, %Wick.Error{}}` on malformed input.
  """
  @spec decode(binary()) :: {:ok, [Link.t()]} | {:error, Wick.Error.t()}
  def decode(input) when is_binary(input) do
    case parse_links(skip_ws(input), []) do
      {:ok, links} -> {:ok, Enum.reverse(links)}
      {:error, _} = err -> err
    end
  end

  defp parse_links("", acc), do: {:ok, acc}

  defp parse_links(input, acc) do
    case parse_link(input) do
      {:ok, link, rest} ->
        case skip_ws(rest) do
          "" ->
            {:ok, [link | acc]}

          "," <> more ->
            parse_links(skip_ws(more), [link | acc])

          other ->
            {:error,
             Wick.Error.new(
               :malformed_link_format,
               "expected ',' between link-values, saw #{inspect(byte_at(other))}"
             )}
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_link("<" <> rest) do
    case String.split(rest, ">", parts: 2) do
      [target, after_close] ->
        case parse_params(after_close, %{}) do
          {:error, _} = err -> err
          {params, leftover} -> {:ok, %Link{target: target, params: params}, leftover}
        end

      _ ->
        {:error, Wick.Error.new(:malformed_link_format, "unterminated target — missing '>'")}
    end
  end

  defp parse_link(other) do
    {:error,
     Wick.Error.new(
       :malformed_link_format,
       "expected '<' at start of link-value, saw #{inspect(byte_at(other))}"
     )}
  end

  defp parse_params(input, params) do
    case skip_ws(input) do
      ";" <> rest ->
        case parse_param(skip_ws(rest)) do
          {:ok, k, v, leftover} -> parse_params(leftover, Map.put(params, k, v))
          {:error, _} = err -> err
        end

      other ->
        {params, other}
    end
  end

  defp parse_param(input) do
    case extract_token(input) do
      {"", _} ->
        {:error, Wick.Error.new(:malformed_link_format, "expected param name")}

      {name, "=" <> rest} ->
        case parse_value(skip_ws(rest)) do
          {:ok, value, leftover} -> {:ok, name, value, leftover}
          {:error, _} = err -> err
        end

      {name, leftover} ->
        # Bare param (no `=value`) — RFC 6690 doesn't define one, but tolerate it as ""
        # for round-trip safety with documents in the wild.
        {:ok, name, "", leftover}
    end
  end

  defp parse_value("\"" <> rest) do
    case extract_quoted(rest, []) do
      {:ok, value, leftover} -> {:ok, value, leftover}
      {:error, _} = err -> err
    end
  end

  defp parse_value(input) do
    {value, leftover} = extract_ptoken(input)
    {:ok, value, leftover}
  end

  defp extract_token(input), do: extract_while(input, &tchar?/1, [])
  defp extract_ptoken(input), do: extract_while(input, &ptokenchar?/1, [])

  defp extract_while(<<c, rest::binary>>, pred, acc) do
    if pred.(c) do
      extract_while(rest, pred, [c | acc])
    else
      {List.to_string(Enum.reverse(acc)), <<c, rest::binary>>}
    end
  end

  defp extract_while("", _pred, acc), do: {List.to_string(Enum.reverse(acc)), ""}

  defp extract_quoted("\"" <> rest, acc), do: {:ok, List.to_string(Enum.reverse(acc)), rest}

  defp extract_quoted("\\" <> <<c, rest::binary>>, acc),
    do: extract_quoted(rest, [c | acc])

  defp extract_quoted(<<c, rest::binary>>, acc), do: extract_quoted(rest, [c | acc])

  defp extract_quoted("", _acc),
    do: {:error, Wick.Error.new(:malformed_link_format, "unterminated quoted-string")}

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t], do: skip_ws(rest)
  defp skip_ws(other), do: other

  defp byte_at(<<c, _::binary>>), do: <<c>>
  defp byte_at(""), do: :eof
end

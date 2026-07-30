defmodule Wick.MixProject do
  use Mix.Project

  @version "0.1.0-dev"

  # Both libraries live in one repository (ADR 0006), so the source URL is the repository and
  # `@source_root` is this package's directory within it. ExDoc needs the two separately:
  # without the directory prefix in `source_url_pattern`, every "source" link on hexdocs
  # resolves to a path that does not exist.
  @source_url "https://github.com/Finnlytics/wick-stack"
  @source_root "wick"

  def project do
    [
      app: :wick,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex package metadata. Wick is unpublished today; this is hex-shaped
      # so publishing later is a one-line config change.
      package: package(),
      description: description(),

      # Docs
      name: "Wick",
      source_url: @source_url,
      docs: docs(),

      # Test
      test_coverage: [tool: ExCoveralls],

      # Dialyzer
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:ex_unit, :mix],
        ignore_warnings: ".dialyzer_ignore.exs",
        flags: [:error_handling, :unknown, :unmatched_returns]
      ]
    ]
  end

  def application do
    [
      # `:xmerl` is OTP stdlib; loaded at runtime so DDF parsing works without a Hex dep.
      extra_applications: [:logger, :xmerl]
    ]
  end

  def cli do
    [
      preferred_envs: [
        check: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # No runtime dependencies. Wick is intentionally self-contained at runtime: every wire
      # format we ship is hand-written against the relevant RFC. Tooling below is dev/test only.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:jason, "~> 1.4", only: [:dev, :test]},
      # wick_coap is the sibling transport library. Test-only — the integration tests exercise
      # Wick and WickCoap end-to-end over real CoAP/UDP. Wick still has zero runtime deps, and
      # this dependency never reaches a consumer: `only: :test`, and the package `files` list
      # excludes `test/`.
      {:wick_coap, wick_coap_source()}
    ]
  end

  # A plain relative path. It used to fall back to fetching wick_coap from GitHub when the
  # sibling directory was absent, which was necessary when the two lived in separate
  # repositories — and was also the reason CI could never test a change spanning both, since it
  # resolved whatever `main` happened to be rather than the commit under test. One repository
  # (ADR 0006) makes the sibling guaranteed, so the fallback is gone rather than left as dead
  # code that would silently resolve a stale published copy.
  defp wick_coap_source, do: [path: "../wick_coap", only: :test]

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "credo --strict",
        "compile --warnings-as-errors",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp package do
    [
      maintainers: ["Finnlytics"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/#{@source_root}/CHANGELOG.md"
      },
      # `docs` is included so the ADRs travel with the package and `mix docs` works from a
      # fetched tarball rather than silently dropping every extra.
      files: ~w(lib priv docs mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp description do
    "LwM2M protocol primitives for Elixir: codecs, Object Model, paths, requests."
  end

  defp docs do
    [
      main: "readme",
      # The ADRs are the best explanation of *why* the library is shaped the way it is, and
      # leaving them out of the published docs made them invisible to anyone who had not cloned
      # the repository.
      extras:
        [
          "README.md",
          "CHANGELOG.md"
        ] ++ Path.wildcard("docs/decisions/0*.md"),
      groups_for_extras: [
        "Decision records": Path.wildcard("docs/decisions/0*.md")
      ],
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/main/#{@source_root}/%{path}#L%{line}",
      # Patterns rather than explicit lists: each LwM2M operation is its own nested struct
      # (`Wick.Request.Read`, `Wick.Bootstrap.Write`, …), and enumerating them meant a new
      # operation silently landed in an ungrouped pile. ExDoc matches a regex against the
      # module id, so the prefix does the work.
      groups_for_modules: [
        Interfaces: [~r/^Wick\.(Bootstrap|Registration|Request|Response|Uplink)($|\.)/],
        "Information Reporting": [Wick.Attributes, ~r/^Wick\.Observation($|\.)/],
        Transport: [~r/^Wick\.Wire($|\.)/, Wick.Status],
        Codecs: [~r/^Wick\.(Codec|Senml|CoreLink)($|\.)/],
        "Object Model": [~r/^Wick\.Object($|\.)/],
        Types: [Wick.Path, Wick.Value, Wick.Error]
        # No group for Wick.Cbor / Wick.Json: both are `@moduledoc false` internals, so ExDoc
        # never surfaces them and a group here would be dead config.
      ]
    ]
  end
end

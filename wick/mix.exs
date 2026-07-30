defmodule Wick.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/finnlytics/wick"

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
      # wick_coap is the sibling transport library. Test-only — the registration
      # integration test exercises Wick + WickCoap end-to-end. Wick still has zero
      # runtime deps in production. Uses a local path dep when checked out alongside
      # wick_coap (local dev); falls back to the GitHub source in CI.
      {:wick_coap, wick_coap_source()}
    ]
  end

  defp wick_coap_source do
    if File.exists?("../wick_coap/mix.exs") do
      [path: "../wick_coap", only: :test]
    else
      [github: "Finnlytics/wick_coap", branch: "main", only: :test]
    end
  end

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
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp description do
    "LwM2M protocol primitives for Elixir: codecs, Object Model, paths, requests."
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Codecs: [
          Wick.Codec,
          Wick.Codec.SenmlCbor
        ],
        "Object Model": [
          Wick.Object.Definition,
          Wick.Object.Resource,
          Wick.Object.Registry
        ],
        Types: [
          Wick.Path,
          Wick.Value,
          Wick.Error
        ]
      ]
    ]
  end
end

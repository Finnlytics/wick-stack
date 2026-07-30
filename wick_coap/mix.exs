defmodule WickCoap.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/finnlytics/wick_coap"

  def project do
    [
      app: :wick_coap,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      description: description(),
      name: "WickCoap",
      source_url: @source_url,
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
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
      extra_applications: [:logger, :ssl]
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
      # Zero runtime dependencies — every wire format we ship is hand-written against the
      # relevant RFC. See Wick ADR 0001 for the rationale; the same reasoning carries over:
      # https://github.com/Finnlytics/wick/blob/main/docs/decisions/0001-zero-runtime-dependencies.md
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
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
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp description do
    "CoAP (RFC 7252) wire format and runtime for Elixir."
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      source_ref: "v#{@version}"
    ]
  end
end

defmodule WickDemoServer.MixProject do
  use Mix.Project

  @version "0.1.0-dev"

  def project do
    [
      app: :wick_demo_server,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {WickDemoServer.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:wick, path: "../../wick"},
      {:wick_coap, path: "../../wick_coap"},
      # The web UI. These are *demo application* dependencies — Wick and WickCoap remain
      # dependency-free (ADR 0001), and this app is deliberately where the compromises live.
      # Bandit + Plug rather than Phoenix: there is no view layer to speak of (the UI is one
      # self-contained page) and no need for a Node toolchain, which keeps `iex -S mix` the
      # only thing you have to run.
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end

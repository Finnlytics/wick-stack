defmodule WickDemoClient.MixProject do
  use Mix.Project

  @version "0.1.0-dev"

  def project do
    [
      app: :wick_demo_client,
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
      mod: {WickDemoClient.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:wick, path: "../../wick"},
      {:wick_coap, path: "../../wick_coap"},
      # Smoke test boots the demo server inside the same VM to exercise a real round-trip.
      {:wick_demo_server, path: "../wick_demo_server", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end

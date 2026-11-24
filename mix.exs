defmodule Ww.MixProject do
  use Mix.Project

  def project do
    [
      app: :ww,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      deps: deps()
    ]
  end

  # `./ww` (a committed wrapper) runs the CLI through this release: `MIX_ENV=prod mix release`.
  defp releases do
    [ww: [include_executables_for: [:unix]]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      included_applications: [:mnesia],
      mod: {Ww.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.15"},
      {:jason, "~> 1.4"},
      {:websock, "~> 0.5"},
      {:websock_adapter, "~> 0.7"},
      {:mint_web_socket, "~> 1.0", only: :test}
    ]
  end
end

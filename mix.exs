defmodule Rinha.MixProject do
  use Mix.Project

  def project do
    [
      app: :rinha,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      releases: releases(),
      deps: deps()
    ]
  end

  defp releases do
    [
      rinha: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Rinha.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      # Nx + EXLA are only needed at build time for `priv/build_references.exs`.
      # They are excluded from the prod release so the runtime image stays
      # small (no XLA runtime, no BLAS, no CUDA bindings).
      {:nx, "~> 0.7", only: [:dev, :test]},
      {:exla, "~> 0.7", only: [:dev, :test]},
      {:tidewave, "~> 0.4", only: :dev}
    ]
  end
end

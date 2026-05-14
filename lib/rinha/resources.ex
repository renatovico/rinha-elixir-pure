defmodule Rinha.Resources do
  @moduledoc """
  Loads static reference data (MCC risk table, normalization config) from disk
  at application boot and stores them in `:persistent_term` for hot-path
  access with zero per-request lookup overhead.

  Lookup keys:

    * `{:rinha, :mcc_risk}`     => `%{String.t() => float()}`
    * `{:rinha, :normalization}` => `%{atom() => float()}`

  The normalization config is keyed by atom for fast field access on the
  hot path. Field names mirror `priv/resources/normalization.json`.
  """

  require Logger

  @mcc_risk_key {:rinha, :mcc_risk}
  @normalization_key {:rinha, :normalization}

  @doc "Load both resource files into :persistent_term. Idempotent."
  def load!(opts \\ []) do
    base =
      Keyword.get(opts, :path) ||
        Application.get_env(:rinha, :resources_path) ||
        System.get_env("RESOURCES_PATH") ||
        Path.join(:code.priv_dir(:rinha), "resources")

    Logger.info("Loading resources from #{base}...")

    mcc_risk =
      base
      |> Path.join("mcc_risk.json")
      |> File.read!()
      |> Jason.decode!()

    normalization =
      base
      |> Path.join("normalization.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.new(fn {k, v} -> {String.to_atom(k), v / 1} end)

    :persistent_term.put(@mcc_risk_key, mcc_risk)
    :persistent_term.put(@normalization_key, normalization)

    Logger.info(
      "Resources loaded (#{map_size(mcc_risk)} MCC entries, #{map_size(normalization)} norm fields)"
    )

    :ok
  end

  @doc "Return the MCC risk map. Raises if `load!/1` has not run."
  @spec mcc_risk() :: %{String.t() => float()}
  def mcc_risk, do: :persistent_term.get(@mcc_risk_key)

  @doc "Return the normalization config map (atom-keyed)."
  @spec normalization() :: %{atom() => float()}
  def normalization, do: :persistent_term.get(@normalization_key)
end

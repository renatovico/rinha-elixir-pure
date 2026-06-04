defmodule Rinha.XGBoostStore do
  @moduledoc """
  Loads and caches the EXGBoost model from disk.
  """

  require Logger

  @persistent_key {:rinha, :xg_boost_store}

  @spec build(keyword()) :: :ok
  def build(opts \\ []) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:rinha, :xgboost_path) ||
        System.get_env("XGBOOST_PATH") ||
        Path.join(:code.priv_dir(:rinha), "model.json")

    Logger.info("Loading XGBoost model from #{path}...")

    model = EXGBoost.read_model(path)
    :persistent_term.put(@persistent_key, model)

    Logger.info("XGBoost model ready")
    :ok
  end

  @spec get() :: EXGBoost.Booster.t()
  def get do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        :ok = build()
        :persistent_term.get(@persistent_key)

      model ->
        model
    end
  end
end

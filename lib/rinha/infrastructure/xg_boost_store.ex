defmodule Rinha.XGBoostStore do
  @moduledoc """
  Loads the exported XGBoost tree ensemble from a compact binary file.
  """

  require Logger

  @persistent_key {:rinha, :xg_boost_store}

  @spec build(keyword()) :: :ok
  def build(opts \\ []) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:rinha, :xgboost_path) ||
        System.get_env("XGBOOST_PATH") ||
        Path.join(:code.priv_dir(:rinha), "xgboost.bin")

    Logger.info("Loading XGBoost tree ensemble from #{path}...")

    payload = path |> File.read!() |> parse!(path)
    :persistent_term.put(@persistent_key, payload)

    Logger.info("XGBoost ready: #{payload.tree_count} trees")
    :ok
  end

  @spec get() :: map()
  def get do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        :ok = build()
        :persistent_term.get(@persistent_key)

      store ->
        store
    end
  end

  defp parse!(
         <<"RFF2", version::little-32, 2::unsigned-8, base_margin::little-float-64,
           tree_count::little-32, rest::binary>>,
         _path
       ) do
    {trees, <<>>} = parse_trees(rest, tree_count, [])

    %{
      version: version,
      base_margin: base_margin,
      tree_count: tree_count,
      trees: trees
    }
  end

  defp parse!(_, path), do: raise("Invalid XGBoost model format at #{path}")

  defp parse_trees(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp parse_trees(<<node_count::little-32, rest::binary>>, count, acc) do
    bytes = node_count * 25
    <<nodes_bin::binary-size(bytes), remaining::binary>> = rest
    parse_trees(remaining, count - 1, [{node_count, nodes_bin} | acc])
  end
end

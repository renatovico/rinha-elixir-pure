defmodule Rinha.RandomForestStore do
  @moduledoc """
  Loads pure-Elixir tree ensemble weights from a compact binary file.
  """

  require Logger

  @persistent_key {:rinha, :random_forest_store}

  @spec build(keyword()) :: :ok
  def build(opts \\ []) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:rinha, :random_forest_path) ||
        System.get_env("RANDOM_FOREST_PATH") ||
        Path.join(:code.priv_dir(:rinha), "random_forest.bin")

    Logger.info("Loading tree ensemble from #{path}...")

    payload = path |> File.read!() |> parse!(path)
    :persistent_term.put(@persistent_key, payload)

    Logger.info("Tree ensemble ready: #{payload.kind}, #{payload.tree_count} trees")
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

  defp parse!(<<"RFF1", version::little-32, tree_count::little-32, rest::binary>>, _path) do
    {trees, <<>>} = parse_trees(rest, tree_count, [])

    %{
      version: version,
      kind: :random_forest,
      base_margin: 0.0,
      tree_count: tree_count,
      trees: trees
    }
  end

  defp parse!(
         <<"RFF2", version::little-32, kind::unsigned-8, base_margin::little-float-32,
           tree_count::little-32, rest::binary>>,
         _path
       ) do
    {trees, <<>>} = parse_trees(rest, tree_count, [])

    %{
      version: version,
      kind: decode_kind(kind),
      base_margin: base_margin,
      tree_count: tree_count,
      trees: trees
    }
  end

  defp parse!(_, path), do: raise("Invalid random forest format at #{path}")

  defp decode_kind(1), do: :random_forest
  defp decode_kind(2), do: :boosted_logistic
  defp decode_kind(other), do: raise("Invalid tree ensemble kind #{inspect(other)}")

  defp parse_trees(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp parse_trees(<<node_count::little-32, rest::binary>>, count, acc) do
    bytes = node_count * 17
    <<nodes_bin::binary-size(bytes), remaining::binary>> = rest
    parse_trees(remaining, count - 1, [{node_count, nodes_bin} | acc])
  end
end

defmodule Rinha.Domain.Models.XGBoost do
  @moduledoc """
  Runtime scorer for the XGBoost-trained tree ensemble.

  The native EXGBoost dependency is used only during preprocessing/training.
  Runtime scoring evaluates the exported trees from `priv/random_forest.bin` in
  pure Elixir to keep the production release dependency-free.
  """

  @scale 8192.0

  @spec score([integer()]) :: 0..5
  def score(vector) when is_list(vector) and length(vector) == 16 do
    vector |> probability() |> prob_to_score()
  end

  def score(other), do: raise("XGBoost expects a 16-int query, got #{inspect(other)}")

  @spec probability([integer()]) :: float()
  def probability(vector) when is_list(vector) and length(vector) == 16 do
    store = Rinha.RandomForestStore.get()
    input = Enum.map(vector, fn v -> v / @scale end) |> List.to_tuple()

    predict_probability(store, input)
  end

  def probability(other), do: raise("XGBoost expects a 16-int query, got #{inspect(other)}")

  defp predict_probability(%{kind: :random_forest} = store, input) do
    store.trees
    |> Enum.reduce(0.0, fn tree, acc -> acc + eval_tree(tree, input, 0) end)
    |> Kernel./(store.tree_count)
  end

  defp predict_probability(%{kind: :boosted_logistic} = store, input) do
    margin =
      Enum.reduce(store.trees, store.base_margin, fn tree, acc ->
        acc + eval_tree(tree, input, 0)
      end)

    sigmoid(margin)
  end

  defp eval_tree(tree, input, idx) do
    {feature, threshold, left, right, value} = node_at(tree, idx)

    if feature < 0 do
      value
    else
      next = if elem(input, feature) <= threshold, do: left, else: right
      eval_tree(tree, input, next)
    end
  end

  defp node_at({_node_count, nodes}, idx) do
    offset = idx * 17

    <<_::binary-size(offset), feature::signed-little-8, threshold::little-float-32,
      left::little-32, right::little-32, value::little-float-32, _::binary>> = nodes

    {feature, threshold, left, right, value}
  end

  defp sigmoid(x), do: 1.0 / (1.0 + :math.exp(-x))

  defp prob_to_score(prob) when prob < 0.1, do: 0
  defp prob_to_score(prob) when prob < 0.3, do: 1
  defp prob_to_score(prob) when prob < 0.5, do: 2
  defp prob_to_score(prob) when prob < 0.7, do: 3
  defp prob_to_score(prob) when prob < 0.9, do: 4
  defp prob_to_score(_prob), do: 5
end

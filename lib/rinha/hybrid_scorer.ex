defmodule Rinha.HybridScorer do
  @moduledoc """
  Hybrid fraud scorer that combines neural inference and vector search.

  Flow:

    1. Use `Rinha.NeuralScorer` to get a fast prior (0..5)
    2. Pick IVF probe budget from that prior
    3. Run vector search with `Rinha.IvfScanner.score/2`
    4. Cache final score through Bloom + ETS

  Final decision remains vector-search based; neural is used to adapt search.
  """

  @doc "Score a transformed vector and return fraud count in 0..5."
  @spec score([integer()]) :: 0..5
  def score(vector) when is_list(vector) do
    case Rinha.BloomFilter.lookup(:hybrid, vector) do
      {:hit, n} ->
        n

      :miss ->
        prior = Rinha.NeuralScorer.score(vector)
        probes = probes_for(prior)
        n = Rinha.IvfScanner.score(vector, probes)
        :ok = Rinha.BloomFilter.put(:hybrid, vector, n)
        n
    end
  end

  def score(other), do: raise("HybridScorer expects a 16-int query, got #{inspect(other)}")

  defp probes_for(n) when n in [0, 1, 4, 5], do: 2
  defp probes_for(_n), do: 3
end

defmodule Rinha.Domain.Models.Hybrid do
  @moduledoc """
  Domain hybrid model that combines neural prior with IVF scan.
  """

  @spec score([integer()]) :: 0..5
  def score(vector) when is_list(vector) do
    case Rinha.Domain.Cache.lookup(:hybrid, vector) do
      {:hit, n} ->
        n

      :miss ->
        prior = Rinha.Domain.Models.Neural.score(vector)
        probes = probes_for(prior)
        n = Rinha.Domain.Models.IVF.score(vector, probes)
        :ok = Rinha.Domain.Cache.put(:hybrid, vector, n)
        n
    end
  end

  def score(other), do: raise("Hybrid expects a 16-int query, got #{inspect(other)}")

  defp probes_for(n) when n in [0, 1, 4, 5], do: 2
  defp probes_for(_n), do: 3
end

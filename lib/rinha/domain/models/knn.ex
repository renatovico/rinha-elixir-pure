defmodule Rinha.Domain.Models.KNN do
  @moduledoc """
  Domain KNN model over the indexed reference base.

  This is the default scoring model: it probes a configurable number of
  IVF buckets directly, without neural priors or hybrid orchestration.
  """

  @default_probes 16

  @spec score([integer()]) :: 0..5
  def score(vector) when is_list(vector) do
    probes = configured_probes()
    Rinha.IvfScanner.score(vector, probes)
  end

  def score(other), do: raise("KNN expects a 16-int query, got #{inspect(other)}")

  defp configured_probes do
    configured = Application.get_env(:rinha, :knn_probes, @default_probes)
    cap = Rinha.Domain.Index.k()
    configured |> max(1) |> min(cap)
  end
end

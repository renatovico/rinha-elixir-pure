defmodule Rinha.Domain.Models.KNN do
  @moduledoc """
  Domain KNN model over the indexed reference base.

  This is the default scoring model: it probes a configurable number of
  IVF buckets directly, without neural priors or hybrid orchestration.
  """

  @default_probes 12
  @default_dynamic true
  @default_dynamic_runq_mid 1
  @default_dynamic_runq_high 2
  @default_dynamic_floor 3

  @spec score([integer()]) :: 0..5
  def score(vector) when is_list(vector) do
    probes = effective_probes()
    Rinha.IvfScanner.score(vector, probes)
  end

  def score(other), do: raise("KNN expects a 16-int query, got #{inspect(other)}")

  defp configured_probes do
    configured = Application.get_env(:rinha, :knn_probes, @default_probes)
    cap = Rinha.Domain.Index.k()
    configured |> max(1) |> min(cap)
  end

  defp effective_probes do
    probes = configured_probes()

    if dynamic_enabled?() do
      dynamic_probes(probes)
    else
      probes
    end
  end

  defp dynamic_enabled? do
    Application.get_env(:rinha, :knn_dynamic_probes, @default_dynamic)
  end

  defp dynamic_probes(base) do
    runq = :erlang.statistics(:run_queue)
    floor = dynamic_floor(base)
    runq_mid = Application.get_env(:rinha, :knn_dynamic_runq_mid, @default_dynamic_runq_mid)
    runq_high = Application.get_env(:rinha, :knn_dynamic_runq_high, @default_dynamic_runq_high)

    cond do
      runq >= runq_high -> floor
      runq >= runq_mid -> max(floor, div(base + floor, 2))
      true -> base
    end
  end

  defp dynamic_floor(base) do
    configured = Application.get_env(:rinha, :knn_dynamic_probes_min, @default_dynamic_floor)
    configured |> max(1) |> min(base)
  end
end

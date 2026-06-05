defmodule Rinha.Domain.Fraud do
  @moduledoc """
  Core fraud-scoring domain service.
  """

  @behaviour Rinha.Domain.Ports.ScoringPipeline

  @spec score_payload(map()) :: %{vector: [integer()], neighbors: 0..5, response: String.t()}
  def score_payload(payload) when is_map(payload) do
    {vector, neighbors} = run_pipeline(payload)

    response = response_for_neighbors(neighbors)

    %{vector: vector, neighbors: neighbors, response: response}
  end

  @spec response_for_payload(map()) :: String.t()
  def response_for_payload(payload) when is_map(payload) do
    {_vector, neighbors} = run_pipeline(payload)
    response_for_neighbors(neighbors)
  end

  @impl true
  def transform_payload(payload), do: Rinha.Domain.Vectorization.transform(payload)

  @impl true
  def score_vector(vector), do: Rinha.Domain.Models.Axon.score(vector)

  @impl true
  def response_for_neighbors(neighbors), do: Rinha.Domain.Decision.response_for(neighbors)

  defp run_pipeline(payload) do
    t0 = System.monotonic_time(:microsecond)
    vector = transform_payload(payload)
    t1 = System.monotonic_time(:microsecond)
    neighbors = score_vector(vector)
    t2 = System.monotonic_time(:microsecond)

    :telemetry.execute([:rinha, :fraud_score, :transform], %{us: t1 - t0}, %{})
    :telemetry.execute([:rinha, :fraud_score, :score], %{us: t2 - t1}, %{})
    :telemetry.execute([:rinha, :fraud_score, :total], %{us: t2 - t0}, %{})

    {vector, neighbors}
  end
end

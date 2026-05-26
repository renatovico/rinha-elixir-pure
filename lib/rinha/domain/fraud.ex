defmodule Rinha.Domain.Fraud do
  @moduledoc """
  Core fraud-scoring domain service.
  """

  @behaviour Rinha.Domain.Ports.ScoringPipeline

  @spec score_payload(map()) :: %{vector: [integer()], neighbors: 0..5, response: String.t()}
  def score_payload(payload) when is_map(payload) do
    vector = transform_payload(payload)
    neighbors = score_vector(vector)
    response = response_for_neighbors(neighbors)

    %{vector: vector, neighbors: neighbors, response: response}
  end

  @spec response_for_payload(map()) :: String.t()
  def response_for_payload(payload) when is_map(payload) do
    payload
    |> score_payload()
    |> Map.fetch!(:response)
  end

  @impl true
  def transform_payload(payload), do: Rinha.Domain.Vectorization.transform(payload)

  @impl true
  def score_vector(vector), do: Rinha.Domain.Models.Hybrid.score(vector)

  @impl true
  def response_for_neighbors(neighbors), do: Rinha.Domain.Decision.response_for(neighbors)
end

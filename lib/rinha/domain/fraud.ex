defmodule Rinha.Domain.Fraud do
  @moduledoc """
  Core fraud-scoring domain service.
  """

  @behaviour Rinha.Domain.Ports.ScoringPipeline

  @spec score_payload(map()) :: %{vector: [integer()], neighbors: 0..5, response: String.t()}
  def score_payload(payload) when is_map(payload) do
    vector = transform_payload(payload)
    raw_neighbors = score_vector(vector)
    neighbors = maybe_calibrate(vector, raw_neighbors)

    response = response_for_neighbors(neighbors)

    %{vector: vector, neighbors: neighbors, response: response}
  end

  @spec response_for_payload(map()) :: String.t()
  def response_for_payload(payload) when is_map(payload) do
    vector = transform_payload(payload)
    raw_neighbors = score_vector(vector)
    neighbors = maybe_calibrate(vector, raw_neighbors)
    response_for_neighbors(neighbors)
  end

  @impl true
  def transform_payload(payload), do: Rinha.Domain.Vectorization.transform(payload)

  @impl true
  def score_vector(vector) do
    case scoring_model() do
      :nn -> Rinha.Domain.Models.NeuralNet.score(vector)
      :knn -> Rinha.Domain.Models.KNN.score(vector)
      :random_forest -> Rinha.Domain.Models.RandomForest.score(vector)
    end
  end

  @impl true
  def response_for_neighbors(neighbors), do: Rinha.Domain.Decision.response_for(neighbors)

  # BorderlineCalibration is KNN-specific; skip for neural network
  defp maybe_calibrate(vector, neighbors) do
    case scoring_model() do
      :nn -> neighbors
      :knn -> Rinha.Domain.Models.BorderlineCalibration.adjust(vector, neighbors)
      :random_forest -> neighbors
    end
  end

  defp scoring_model do
    Application.get_env(:rinha, :scoring_model, :random_forest)
  end
end

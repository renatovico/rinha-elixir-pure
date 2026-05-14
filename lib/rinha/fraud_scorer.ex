defmodule Rinha.FraudScorer do
  @moduledoc """
  Pure-KNN fraud scoring.

  Hot path:

      vector = Rinha.VectorTransformerV2.transform(payload)
      n      = Rinha.KnnServer.score(vector)            # 0..5 fraud neighbors
      Map.fetch!(@responses, n)                       # precomputed JSON

  The 6 precomputed responses encode `fraud_score = n / 5.0` with
  `approved = score < 0.6`.
  """

  require Logger

  @responses %{
    0 => ~s({"approved":true,"fraud_score":0.0}),
    1 => ~s({"approved":true,"fraud_score":0.2}),
    2 => ~s({"approved":true,"fraud_score":0.4}),
    3 => ~s({"approved":false,"fraud_score":0.6}),
    4 => ~s({"approved":false,"fraud_score":0.8}),
    5 => ~s({"approved":false,"fraud_score":1.0})
  }

  @doc "Map a fraud-neighbor count (0..5) to its precomputed JSON response."
  @spec response_for(0..5) :: String.t()
  def response_for(n) when n in 0..5, do: Map.fetch!(@responses, n)

  @doc "All precomputed responses (handy for tests and the simulator)."
  def responses, do: @responses

  @doc "Score a payload and return the precomputed JSON response string."
  @spec score(map()) :: String.t()
  def score(payload) do
    t0 = System.monotonic_time(:microsecond)

    vector = Rinha.VectorTransformerV2.transform(payload)
    t1 = System.monotonic_time(:microsecond)

    n = Rinha.KnnServer.score(vector)
    t2 = System.monotonic_time(:microsecond)

    response = Map.fetch!(@responses, n)

    sample_log(t0, t1, t2, n)
    response
  end

  # 1-in-100 logging to keep prod logs sparse but observable.
  defp sample_log(t0, t1, t2, n) do
    counter = :atomics.add_get(:persistent_term.get(:prof_counter), 1, 1)

    if rem(counter, 100) == 0 do
      transform_us = t1 - t0
      knn_us = t2 - t1
      total_us = t2 - t0

      Logger.info(
        "[PROF] total=#{total_us}us transform=#{transform_us}us knn=#{knn_us}us n=#{n}"
      )
    end
  end
end

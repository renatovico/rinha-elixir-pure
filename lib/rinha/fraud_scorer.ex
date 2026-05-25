defmodule Rinha.FraudScorer do
  @moduledoc """
  Maps neural fraud counts (0..5) to precomputed JSON responses.

  The 6 precomputed responses encode `fraud_score = n / 5.0` with
  `approved = score < 0.6`.
  """

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

  @doc "All precomputed responses."
  def responses, do: @responses
end

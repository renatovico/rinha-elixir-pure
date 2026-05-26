defmodule Rinha.Domain.Decision do
  @moduledoc """
  Domain decision policy from fraud-neighbor count to API response.
  """

  @responses %{
    0 => ~s({"approved":true,"fraud_score":0.0}),
    1 => ~s({"approved":true,"fraud_score":0.2}),
    2 => ~s({"approved":true,"fraud_score":0.4}),
    3 => ~s({"approved":false,"fraud_score":0.6}),
    4 => ~s({"approved":false,"fraud_score":0.8}),
    5 => ~s({"approved":false,"fraud_score":1.0})
  }

  @spec response_for(0..5) :: String.t()
  def response_for(n) when n in 0..5, do: Map.fetch!(@responses, n)

  @spec responses() :: %{(0..5) => String.t()}
  def responses, do: @responses
end

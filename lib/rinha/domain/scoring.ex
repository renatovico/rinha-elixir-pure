defmodule Rinha.Domain.Scoring do
  @moduledoc """
  Domain-level scoring facade.

  Orchestrates payload transformation, Axon scoring, and response
  rendering so HTTP/adapters don't need to know pipeline internals.
  """

  @spec score_payload(map()) :: %{vector: [integer()], neighbors: 0..5, response: String.t()}
  def score_payload(payload) when is_map(payload), do: Rinha.Domain.Fraud.score_payload(payload)

  @spec score_payload_response(map()) :: String.t()
  def score_payload_response(payload) when is_map(payload),
    do: Rinha.Domain.Fraud.response_for_payload(payload)
end

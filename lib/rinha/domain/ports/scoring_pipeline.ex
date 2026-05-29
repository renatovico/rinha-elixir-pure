defmodule Rinha.Domain.Ports.ScoringPipeline do
  @moduledoc """
  Port for the core fraud-scoring pipeline.

  This allows adapters (HTTP, RPC, debug tooling) to depend on domain contracts
  instead of concrete implementation modules.
  """

  @callback transform_payload(map()) :: [integer()]
  @callback score_vector([integer()]) :: 0..5
  @callback response_for_neighbors(0..5) :: String.t()
end

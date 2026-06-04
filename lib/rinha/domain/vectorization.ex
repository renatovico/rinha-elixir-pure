defmodule Rinha.Domain.Vectorization do
  @moduledoc """
  Domain vectorization service.
  """

  @spec transform(map()) :: [integer()]
  def transform(payload), do: Rinha.VectorTransformerV2.transform(payload)
end

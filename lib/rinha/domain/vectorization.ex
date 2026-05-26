defmodule Rinha.Domain.Vectorization do
  @moduledoc """
  Domain vectorization service.
  """

  @spec transform(map()) :: [integer()]
  def transform(payload), do: Rinha.VectorTransformerV2.transform(payload)

  @spec stride() :: pos_integer()
  def stride, do: Rinha.VectorTransformerV2.stride()

  @spec scale() :: pos_integer()
  def scale, do: Rinha.VectorTransformerV2.scale()
end

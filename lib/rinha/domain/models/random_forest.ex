defmodule Rinha.Domain.Models.RandomForest do
  @moduledoc """
  Backwards-compatible alias for the XGBoost-trained tree ensemble scorer.
  """

  @spec score([integer()]) :: 0..5
  def score(vector), do: Rinha.Domain.Models.XGBoost.score(vector)

  @spec probability([integer()]) :: float()
  def probability(vector), do: Rinha.Domain.Models.XGBoost.probability(vector)
end

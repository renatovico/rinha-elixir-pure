defmodule Rinha.Domain.Models.Neural do
  @moduledoc """
  Domain access to the neural prior model.
  """

  @spec score([integer()]) :: 0..5
  def score(vector), do: Rinha.NeuralScorer.score(vector)
end

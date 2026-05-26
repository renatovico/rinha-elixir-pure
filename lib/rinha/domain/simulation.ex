defmodule Rinha.Domain.Simulation do
  @moduledoc """
  Domain wrapper for synthetic simulation and warmup generation.
  """

  @spec generate(keyword()) :: {:fraud | :legit, map()}
  def generate(opts \\ []), do: Rinha.FraudSimulator.generate(opts)

  @spec run(non_neg_integer(), keyword()) :: map()
  def run(count, opts \\ []), do: Rinha.FraudSimulator.run(count, opts)
end

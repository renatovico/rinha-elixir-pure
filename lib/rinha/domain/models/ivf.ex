defmodule Rinha.Domain.Models.IVF do
  @moduledoc """
  Domain access to IVF/KNN scan model.
  """

  @spec score([integer()], pos_integer()) :: 0..5
  def score(vector, probes), do: Rinha.IvfScanner.score(vector, probes)
end

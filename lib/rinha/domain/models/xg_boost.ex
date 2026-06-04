defmodule Rinha.Domain.Models.XGBoost do
  @moduledoc """
  Runtime scorer using EXGBoost with EXLA CPU backend.
  """

  @scale 8192.0

  @spec score([integer()]) :: 0..5
  def score(vector) when is_list(vector) and length(vector) == 16 do
    vector |> probability() |> prob_to_score()
  end

  def score(other), do: raise("XGBoost expects a 16-int query, got #{inspect(other)}")

  @spec probability([integer()]) :: float()
  def probability(vector) when is_list(vector) and length(vector) == 16 do
    model = Rinha.XGBoostStore.get()

    input =
      vector
      |> Enum.map(&(&1 / @scale))
      |> Nx.tensor(type: :f32)
      |> Nx.new_axis(0)

    EXGBoost.predict(model, input)
    |> Nx.to_flat_list()
    |> hd()
  end

  def probability(other), do: raise("XGBoost expects a 16-int query, got #{inspect(other)}")

  defp prob_to_score(prob) when prob < 0.1, do: 0
  defp prob_to_score(prob) when prob < 0.3, do: 1
  defp prob_to_score(prob) when prob < 0.5, do: 2
  defp prob_to_score(prob) when prob < 0.7, do: 3
  defp prob_to_score(prob) when prob < 0.9, do: 4
  defp prob_to_score(_prob), do: 5
end

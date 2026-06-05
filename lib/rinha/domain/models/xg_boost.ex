defmodule Rinha.Domain.Models.XGBoost do
  @moduledoc """
  Runtime scorer using EXGBoost with EXLA CPU backend.
  """

  @scale 8192.0
  @default_approve_threshold 0.5

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

  defp prob_to_score(prob) do
    approve_threshold =
      Application.get_env(:rinha, :xgb_approve_threshold, @default_approve_threshold)
      |> clamp_approve_threshold()

    cond do
      prob < approve_threshold -> 2
      prob < 0.7 -> 3
      prob < 0.9 -> 4
      true -> 5
    end
  end

  defp clamp_approve_threshold(value) when is_float(value), do: min(max(value, 0.31), 0.69)
  defp clamp_approve_threshold(value) when is_integer(value), do: value / 1 |> clamp_approve_threshold()
  defp clamp_approve_threshold(_), do: @default_approve_threshold
end

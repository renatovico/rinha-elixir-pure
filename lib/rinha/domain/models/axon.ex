defmodule Rinha.Domain.Models.Axon do
  @moduledoc """
  Runtime scorer based on an Axon binary classifier.
  """

  @scale 8192.0
  @default_approve_threshold 0.5
  @min_approve_threshold 0.31
  @max_approve_threshold 0.95
  @default_input_size 16
  @default_hidden_size_1 256
  @default_hidden_size_2 256

  @type config :: %{
          input_size: pos_integer(),
          hidden_size_1: pos_integer(),
          hidden_size_2: pos_integer(),
          approve_threshold: float()
        }

  @spec default_config() :: config()
  def default_config do
    %{
      input_size: @default_input_size,
      hidden_size_1: @default_hidden_size_1,
      hidden_size_2: @default_hidden_size_2,
      approve_threshold: @default_approve_threshold
    }
  end

  @spec model(map()) :: Axon.t()
  def model(config \\ %{}) do
    cfg = normalize_config(config)

    Axon.input("input", shape: {nil, cfg.input_size})
    |> Axon.dense(cfg.hidden_size_1, activation: :relu)
    |> Axon.dense(cfg.hidden_size_2, activation: :relu)
    |> Axon.dense(1, activation: :sigmoid)
  end

  @spec normalize_config(map()) :: config()
  def normalize_config(config) when is_map(config) do
    %{
      input_size: read_positive_int(config, :input_size, @default_input_size),
      hidden_size_1: read_positive_int(config, :hidden_size_1, @default_hidden_size_1),
      hidden_size_2: read_positive_int(config, :hidden_size_2, @default_hidden_size_2),
      approve_threshold: read_threshold(config, :approve_threshold, @default_approve_threshold)
    }
  end

  @spec score([integer()]) :: 0..5
  def score(vector) when is_list(vector) and length(vector) == 16 do
    store = Rinha.AxonStore.get()
    approve_threshold = resolve_approve_threshold(store)
    vector |> probability(store) |> prob_to_score(approve_threshold)
  end

  def score(other), do: raise("Axon expects a 16-int query, got #{inspect(other)}")

  @spec probability([integer()]) :: float()
  def probability(vector) when is_list(vector) and length(vector) == 16 do
    store = Rinha.AxonStore.get()
    probability(vector, store)
  end

  def probability(other), do: raise("Axon expects a 16-int query, got #{inspect(other)}")

  defp probability(vector, store) do
    input = vector_to_input(vector)

    store.predict_fn.(store.params, input)
    |> Nx.to_flat_list()
    |> hd()
  end

  defp vector_to_input(vector) do
    vector
    |> Enum.map(&(&1 / @scale))
    |> Nx.tensor(type: :f32)
    |> Nx.new_axis(0)
  end

  defp prob_to_score(prob, _approve_threshold) when prob < 0.1, do: 0
  defp prob_to_score(prob, _approve_threshold) when prob < 0.3, do: 1

  defp prob_to_score(prob, approve_threshold) do
    cond do
      prob < approve_threshold -> 2
      prob < 0.7 -> 3
      prob < 0.9 -> 4
      true -> 5
    end
  end

  defp resolve_approve_threshold(store) do
    env_value = Application.get_env(:rinha, :approve_threshold)
    model_value = get_in(store, [:config, :approve_threshold])

    case env_value do
      nil -> clamp_approve_threshold(model_value)
      value -> clamp_approve_threshold(value)
    end
  end

  defp clamp_approve_threshold(value) when is_float(value),
    do: min(max(value, @min_approve_threshold), @max_approve_threshold)

  defp clamp_approve_threshold(value) when is_integer(value),
    do: (value / 1) |> clamp_approve_threshold()

  defp clamp_approve_threshold(_), do: @default_approve_threshold

  defp read_positive_int(config, key, default) do
    value =
      Map.get(config, key) ||
        Map.get(config, Atom.to_string(key))

    case normalize_int(value) do
      int when is_integer(int) and int > 0 -> int
      int when is_integer(int) -> default
      _ -> default
    end
  end

  defp read_threshold(config, key, default) do
    value =
      Map.get(config, key) ||
        Map.get(config, Atom.to_string(key))

    case normalize_float(value) do
      nil -> default
      threshold -> clamp_approve_threshold(threshold)
    end
  end

  defp normalize_int(%Nx.Tensor{} = tensor), do: tensor |> Nx.to_number() |> trunc()
  defp normalize_int(value) when is_integer(value), do: value
  defp normalize_int(_), do: nil

  defp normalize_float(%Nx.Tensor{} = tensor), do: tensor |> Nx.to_number() |> normalize_float()
  defp normalize_float(value) when is_float(value), do: value
  defp normalize_float(value) when is_integer(value), do: value * 1.0

  defp normalize_float(value) when is_binary(value) do
    case Float.parse(value) do
      {v, ""} -> v
      _ -> nil
    end
  end

  defp normalize_float(_), do: nil
end

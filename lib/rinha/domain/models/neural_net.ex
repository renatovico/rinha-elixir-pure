defmodule Rinha.Domain.Models.NeuralNet do
  @moduledoc """
  Deep neural network fraud scoring model.

  Supports multiple architectures:
  - v1: Single hidden layer
  - v2: Two hidden layers
  - v3: N hidden layers (deep network)

  Input: 16-int vector from VectorTransformerV2 (int16 quantized, scale=8192)
  Output: fraud probability, mapped to 0..5 for API compatibility.
  """

  @scale 8192.0

  @spec score([integer()]) :: 0..5
  def score(vector) when is_list(vector) and length(vector) == 16 do
    store = Rinha.NeuralNetStore.get()

    # Dequantize int16 vector to float [0, 1] range
    input = Enum.map(vector, fn v -> v / @scale end)

    prob =
      case store.version do
        1 -> forward_v1(input, store)
        2 -> forward_v2(input, store)
        3 -> forward_v3(input, store)
      end

    prob_to_score(prob)
  end

  def score(other), do: raise("NeuralNet expects a 16-int query, got #{inspect(other)}")

  # v1: Single hidden layer
  defp forward_v1(input, store) do
    h = forward_layer(input, store.weights_1, store.bias_1, store.hidden_size, &relu/1)
    [logit] = forward_layer(h, store.weights_2, store.bias_2, store.output_size, & &1)
    sigmoid(logit)
  end

  # v2: Two hidden layers
  defp forward_v2(input, store) do
    h1 = forward_layer(input, store.weights_1, store.bias_1, store.h1, &relu/1)
    h2 = forward_layer(h1, store.weights_2, store.bias_2, store.h2, &relu/1)
    [logit] = forward_layer(h2, store.weights_3, store.bias_3, store.output_size, & &1)
    sigmoid(logit)
  end

  # v3: N hidden layers (deep network)
  defp forward_v3(input, store) do
    n_layers = store.n_layers

    # Forward through all layers
    output =
      Enum.reduce(0..(n_layers - 1), input, fn i, a ->
        layer = Enum.at(store.layers, i)
        is_last = i == n_layers - 1

        # ReLU for hidden layers, identity for output (apply sigmoid later)
        activation = if is_last, do: & &1, else: &relu/1
        forward_layer(a, layer.weights, layer.bias, layer.out_size, activation)
      end)

    [logit] = output
    sigmoid(logit)
  end

  defp forward_layer(input, weights, bias, output_size, activation) do
    input_size = length(input)
    input_tuple = List.to_tuple(input)

    for j <- 0..(output_size - 1) do
      sum =
        Enum.reduce(0..(input_size - 1), 0.0, fn i, acc ->
          w_idx = i * output_size + j
          w = Enum.at(weights, w_idx)
          x = elem(input_tuple, i)
          acc + w * x
        end)

      activation.(sum + Enum.at(bias, j))
    end
  end

  @compile {:inline, relu: 1, sigmoid: 1, prob_to_score: 1}

  defp relu(x) when x > 0, do: x
  defp relu(_), do: 0.0

  defp sigmoid(x), do: 1.0 / (1.0 + :math.exp(-x))

  # Map fraud probability [0, 1] to score [0, 5]
  defp prob_to_score(prob) when prob < 0.1, do: 0
  defp prob_to_score(prob) when prob < 0.3, do: 1
  defp prob_to_score(prob) when prob < 0.5, do: 2
  defp prob_to_score(prob) when prob < 0.7, do: 3
  defp prob_to_score(prob) when prob < 0.9, do: 4
  defp prob_to_score(_prob), do: 5
end

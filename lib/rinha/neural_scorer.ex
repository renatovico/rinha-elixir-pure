defmodule Rinha.NeuralScorer do
  @moduledoc """
  Pure mathematical feed-forward network used for fraud scoring.

  The model is intentionally tiny and fully deterministic:

    * input: 16 quantized lanes from `Rinha.VectorTransformerV2`
    * hidden: 4 ReLU neurons
    * output: 1 sigmoid neuron mapped to neighbour-count scale (0..5)

  To keep hot-path latency low and predictable, all parameters are
  compile-time constants and inference is implemented with straight
  arithmetic (no matrix library, no dynamic allocations).
  """

  @scale 8192.0

  @doc "Score a transformed 16-lane vector, returning fraud count in 0..5."
  @spec score([integer()]) :: 0..5
  def score([x0, x1, x2, _x3, _x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, _x14, _x15] = vector) do
    t0 = System.monotonic_time(:microsecond)

    case Rinha.BloomFilter.lookup(vector) do
      {:hit, n} ->
        emit_telemetry(t0, n, :hit)
        n

      :miss ->
        n =
          vector
          |> do_score(x0, x1, x2, x5, x6, x7, x8, x9, x10, x11, x12, x13)
          |> score_to_count()

        Rinha.BloomFilter.put(vector, n)
        emit_telemetry(t0, n, :miss)
        n
    end
  end

  def score(other), do: raise("NeuralScorer expects a 16-int query, got #{inspect(other)}")

  defp do_score(_vector, x0, x1, x2, x5, x6, x7, x8, x9, x10, x11, x12, x13) do
    a0 = to_unit(x0)
    a1 = to_unit(x1)
    a2 = to_unit(x2)
    a5 = to_unit(x5)
    a6 = to_unit(x6)
    a7 = to_unit(x7)
    a8 = to_unit(x8)
    a9 = to_unit(x9)
    a10 = to_unit(x10)
    a11 = to_unit(x11)
    a12 = to_unit(x12)
    a13 = to_unit(x13)

    h1 = relu(1.8 * a0 + 1.2 * a1 + 1.7 * a2 + 1.0 * a7 + 1.3 * a8 + 1.6 * a11 + 1.8 * a12 + 0.8 * (1.0 - a10) - 1.0)
    h2 = relu(1.4 * a5 + 1.1 * a6 + 0.9 * a9 - 0.7 * a10 - 0.8)
    h3 = relu(1.1 * a13 + 0.8 * a2 + 0.6 * a12 - 0.9)
    h4 = relu(1.0 * a11 + 1.0 * a12 + 0.8 * a0 - 0.9)

    sigmoid(1.2 * h1 + 0.7 * h2 + 0.6 * h3 + 0.8 * h4 - 1.8)
  end

  defp score_to_count(score) do
    scaled = round(score * 5.0)
    min(max(scaled, 0), 5)
  end

  defp to_unit(v), do: v / @scale

  @compile {:inline, relu: 1, sigmoid: 1}
  defp relu(x) when x > 0.0, do: x
  defp relu(_x), do: 0.0

  defp sigmoid(x), do: 1.0 / (1.0 + :math.exp(-x))

  defp emit_telemetry(t0, n, cache) do
    :telemetry.execute(
      [:rinha, :neural, :total],
      %{us: System.monotonic_time(:microsecond) - t0, n: n},
      %{cache: cache}
    )
  end
end

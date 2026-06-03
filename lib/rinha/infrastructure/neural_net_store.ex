defmodule Rinha.NeuralNetStore do
  @moduledoc """
  Loads neural network weights from binary file at boot.

  Supports multiple formats:
  - v1: Single hidden layer (NNFR magic)
  - v2: Two hidden layers (NNF2 magic)  
  - v3: N hidden layers (NNF3 magic)
  """

  require Logger

  @persistent_key {:rinha, :neural_net_store}

  @spec build(keyword()) :: :ok
  def build(opts \\ []) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:rinha, :nn_weights_path) ||
        System.get_env("NN_WEIGHTS_PATH") ||
        Path.join(:code.priv_dir(:rinha), "nn_weights.bin")

    Logger.info("Loading neural network weights from #{path}...")

    data = File.read!(path)
    payload = parse_weights!(data, path)

    :persistent_term.put(@persistent_key, payload)

    case payload.version do
      1 ->
        Logger.info("NN ready: v1, 1 hidden layer (#{payload.hidden_size})")

      2 ->
        Logger.info("NN ready: v2, 2 hidden layers (#{payload.h1}, #{payload.h2})")

      3 ->
        Logger.info(
          "NN ready: v3, #{payload.n_layers} layers, sizes: #{inspect(payload.layer_sizes)}"
        )
    end

    :ok
  end

  defp parse_weights!(
         <<"NNFR", version::little-32, input_size::little-32, hidden_size::little-32,
           output_size::little-32, rest::binary>>,
         _path
       ) do
    w1_bytes = input_size * hidden_size * 4
    b1_bytes = hidden_size * 4
    w2_bytes = hidden_size * output_size * 4
    b2_bytes = output_size * 4

    <<w1_bin::binary-size(w1_bytes), b1_bin::binary-size(b1_bytes), w2_bin::binary-size(w2_bytes),
      b2_bin::binary-size(b2_bytes), _::binary>> = rest

    %{
      version: version,
      input_size: input_size,
      hidden_size: hidden_size,
      output_size: output_size,
      weights_1: decode_floats(w1_bin),
      bias_1: decode_floats(b1_bin),
      weights_2: decode_floats(w2_bin),
      bias_2: decode_floats(b2_bin)
    }
  end

  defp parse_weights!(
         <<"NNF2", version::little-32, input_size::little-32, h1::little-32, h2::little-32,
           output_size::little-32, rest::binary>>,
         _path
       ) do
    w1_bytes = input_size * h1 * 4
    b1_bytes = h1 * 4
    w2_bytes = h1 * h2 * 4
    b2_bytes = h2 * 4
    w3_bytes = h2 * output_size * 4
    b3_bytes = output_size * 4

    <<w1_bin::binary-size(w1_bytes), b1_bin::binary-size(b1_bytes), w2_bin::binary-size(w2_bytes),
      b2_bin::binary-size(b2_bytes), w3_bin::binary-size(w3_bytes), b3_bin::binary-size(b3_bytes),
      _::binary>> = rest

    %{
      version: version,
      input_size: input_size,
      h1: h1,
      h2: h2,
      output_size: output_size,
      weights_1: decode_floats(w1_bin),
      bias_1: decode_floats(b1_bin),
      weights_2: decode_floats(w2_bin),
      bias_2: decode_floats(b2_bin),
      weights_3: decode_floats(w3_bin),
      bias_3: decode_floats(b3_bin)
    }
  end

  defp parse_weights!(<<"NNF3", version::little-32, n_layers::little-32, rest::binary>>, _path) do
    # Read layer sizes (n_layers + 1 sizes: input + all hidden + output)
    n_sizes = n_layers + 1
    sizes_bytes = n_sizes * 4
    <<sizes_bin::binary-size(sizes_bytes), weights_rest::binary>> = rest
    layer_sizes = decode_u32s(sizes_bin)

    # Read weights and biases for each layer
    {layers, _} =
      Enum.reduce(0..(n_layers - 1), {[], weights_rest}, fn i, {acc, bin} ->
        in_size = Enum.at(layer_sizes, i)
        out_size = Enum.at(layer_sizes, i + 1)

        w_bytes = in_size * out_size * 4
        b_bytes = out_size * 4

        <<w_bin::binary-size(w_bytes), b_bin::binary-size(b_bytes), remaining::binary>> = bin

        layer = %{
          weights: decode_floats(w_bin),
          bias: decode_floats(b_bin),
          in_size: in_size,
          out_size: out_size
        }

        {acc ++ [layer], remaining}
      end)

    %{
      version: version,
      n_layers: n_layers,
      layer_sizes: layer_sizes,
      layers: layers
    }
  end

  defp parse_weights!(_, path), do: raise("Invalid NN weights format at #{path}")

  defp decode_floats(bin), do: for(<<f::little-float-32 <- bin>>, do: f)
  defp decode_u32s(bin), do: for(<<n::little-32 <- bin>>, do: n)

  @spec get() :: map()
  def get do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        :ok = build()
        :persistent_term.get(@persistent_key)

      store ->
        store
    end
  end
end

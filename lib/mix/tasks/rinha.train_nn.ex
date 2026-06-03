defmodule Mix.Tasks.Rinha.TrainNn do
  @shortdoc "Train deep neural network on references dataset"
  @moduledoc """
  Trains a deep MLP (18 layers) for fraud detection.

  Architecture: Input(16) -> [Hidden layers with ReLU] -> Output(1, Sigmoid)

  Usage:
      MIX_ENV=preprocess mix rinha.train_nn

  Options:
      --epochs N      Number of training epochs (default: 100)
      --lr RATE       Learning rate (default: 0.001)
      --output PATH   Output weights file path
  """

  use Mix.Task
  require Logger

  @compile {:no_warn_undefined, EXLA.Backend}
  @compile {:no_warn_undefined, Nx}

  @input_size 16
  @output_size 1
  @input_scale 8192.0
  @default_lr 0.001
  @default_epochs 50
  @batch_size 2048

  # 4-layer architecture: fast training, good capacity
  @layer_sizes [64, 48, 32]

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:exla)
    Nx.global_default_backend(EXLA.Backend)

    {opts, _, _} =
      OptionParser.parse(args, strict: [epochs: :integer, lr: :float, output: :string])

    epochs = Keyword.get(opts, :epochs, @default_epochs)
    lr = Keyword.get(opts, :lr, @default_lr)
    output_path = Keyword.get(opts, :output, Path.join(priv_dir(), "nn_weights.bin"))

    n_layers = length(@layer_sizes) + 1
    Logger.info("Deep MLP Training (#{n_layers} layers, EXLA/GPU)")

    Logger.info(
      "Architecture: #{@input_size} -> #{Enum.join(@layer_sizes, " -> ")} -> #{@output_size}"
    )

    Logger.info("Config: epochs=#{epochs}, lr=#{lr}, batch=#{@batch_size}")

    Logger.info("Loading dataset...")
    {inputs, labels} = load_dataset()
    n = length(inputs)
    {fraud, legit} = count_labels(labels)
    Logger.info("Dataset: #{n} samples (#{fraud} fraud, #{legit} legit)")

    Logger.info("Converting to tensors...")
    x = Nx.tensor(inputs, type: :f32)
    y = Nx.tensor(labels, type: :f32) |> Nx.reshape({n, 1})

    Logger.info("Initializing #{n_layers} layers...")
    params = init_params()

    Logger.info("Training...")
    trained = train(params, x, y, epochs, lr)

    acc = evaluate(trained, x, y)
    Logger.info("Final accuracy: #{Float.round(acc * 100, 2)}%")

    Logger.info("Exporting to #{output_path}...")
    export_weights(trained, output_path)
    Logger.info("Done!")
  end

  defp priv_dir do
    case :code.priv_dir(:rinha) do
      {:error, :bad_name} -> Path.join([File.cwd!(), "priv"])
      path -> List.to_string(path)
    end
  end

  defp load_dataset do
    path = find_references_path()
    data = path |> File.read!() |> :zlib.gunzip() |> Jason.decode!()

    Enum.map(data, fn entry ->
      vec = entry["vector"]
      label = if entry["label"] == "fraud", do: 1.0, else: 0.0
      input = prepare_input(vec)
      {input, label}
    end)
    |> Enum.unzip()
  end

  defp prepare_input(v) when length(v) == 14 do
    Enum.map(v, &scale_input/1) ++ [0.0, 0.0]
  end

  defp prepare_input(v) when length(v) == 16 do
    Enum.map(v, &scale_input/1)
  end

  defp scale_input(x) when is_integer(x), do: x / @input_scale
  defp scale_input(x) when is_float(x), do: x

  defp count_labels(labels) do
    Enum.reduce(labels, {0, 0}, fn l, {f, g} -> if l == 1.0, do: {f + 1, g}, else: {f, g + 1} end)
  end

  defp find_references_path do
    priv = priv_dir()

    paths = [
      Path.join(priv, "resources/references.json.gz"),
      "resources/references.json.gz",
      System.get_env("REFERENCES_PATH")
    ]

    Enum.find(paths, fn p -> p && File.exists?(p) end) || raise "references.json.gz not found"
  end

  defp init_params do
    :rand.seed(:exsss, {42, 42, 42})

    # Build layer sizes: input -> hidden layers -> output
    all_sizes = [@input_size] ++ @layer_sizes ++ [@output_size]

    # Create weights and biases for each layer
    0..(length(all_sizes) - 2)
    |> Enum.map(fn i ->
      in_size = Enum.at(all_sizes, i)
      out_size = Enum.at(all_sizes, i + 1)
      # He initialization for ReLU
      scale = :math.sqrt(2.0 / in_size)
      w = rand_matrix(in_size, out_size, scale)
      b = Nx.broadcast(Nx.tensor(0.0, type: :f32), {out_size})
      {w, b}
    end)
  end

  defp rand_matrix(rows, cols, scale) do
    data = for _ <- 1..rows, _ <- 1..cols, do: :rand.normal() * scale
    Nx.tensor(data, type: :f32) |> Nx.reshape({rows, cols})
  end

  defp train(params, x, y, epochs, lr) do
    n = Nx.axis_size(x, 0)
    batches = div(n, @batch_size)

    Enum.reduce(0..(epochs - 1), params, fn epoch, p ->
      indices = Enum.shuffle(0..(n - 1))

      new_p =
        Enum.reduce(0..(batches - 1), p, fn bi, bp ->
          batch_idx = Enum.slice(indices, bi * @batch_size, @batch_size)
          xb = Nx.take(x, Nx.tensor(batch_idx))
          yb = Nx.take(y, Nx.tensor(batch_idx))
          train_step(bp, xb, yb, lr)
        end)

      if rem(epoch, 5) == 0 do
        loss = compute_loss(new_p, x, y)
        acc = evaluate(new_p, x, y)

        Logger.info(
          "Epoch #{epoch}: loss=#{Float.round(Nx.to_number(loss), 4)}, accuracy=#{Float.round(acc * 100, 2)}%"
        )
      end

      new_p
    end)
  end

  defp train_step(params, x, y, lr) do
    grads = gradients(params, x, y)

    Enum.zip(params, grads)
    |> Enum.map(fn {{w, b}, {dw, db}} ->
      {Nx.subtract(w, Nx.multiply(dw, lr)), Nx.subtract(b, Nx.multiply(db, lr))}
    end)
  end

  defp forward(params, x) do
    n_layers = length(params)

    # Forward through all layers, keeping activations for backprop
    {activations, _} =
      Enum.reduce(0..(n_layers - 1), {[x], x}, fn i, {acts, a} ->
        {w, b} = Enum.at(params, i)
        z = Nx.add(Nx.dot(a, w), b)

        # ReLU for hidden layers, Sigmoid for output
        a_new = if i < n_layers - 1, do: Nx.max(z, 0), else: Nx.sigmoid(z)

        {acts ++ [a_new], a_new}
      end)

    activations
  end

  defp compute_loss(params, x, y) do
    acts = forward(params, x)
    out = List.last(acts)
    eps = 1.0e-7

    loss =
      Nx.add(
        Nx.multiply(Nx.negate(y), Nx.log(Nx.add(out, eps))),
        Nx.multiply(Nx.negate(Nx.subtract(1, y)), Nx.log(Nx.add(Nx.subtract(1, out), eps)))
      )

    Nx.mean(loss)
  end

  defp evaluate(params, x, y) do
    acts = forward(params, x)
    out = List.last(acts)
    pred = Nx.greater_equal(out, 0.5)
    actual = Nx.greater_equal(y, 0.5)
    Nx.to_number(Nx.mean(Nx.equal(pred, actual)))
  end

  defp gradients(params, x, y) do
    bs = Nx.axis_size(x, 0)
    n_layers = length(params)

    # Forward pass - store all z and a values
    {z_list, a_list} =
      Enum.reduce(0..(n_layers - 1), {[], [x]}, fn i, {zs, as} ->
        {w, b} = Enum.at(params, i)
        a = List.last(as)
        z = Nx.add(Nx.dot(a, w), b)
        a_new = if i < n_layers - 1, do: Nx.max(z, 0), else: Nx.sigmoid(z)
        {zs ++ [z], as ++ [a_new]}
      end)

    # Backward pass
    out = List.last(a_list)

    # Start with output layer gradient
    {grads, _} =
      Enum.reduce((n_layers - 1)..0, {[], Nx.subtract(out, y)}, fn i, {gs, delta} ->
        {w, _b} = Enum.at(params, i)
        a_prev = Enum.at(a_list, i)

        dw = Nx.divide(Nx.dot(Nx.transpose(a_prev), delta), bs)
        db = Nx.mean(delta, axes: [0])

        # Compute delta for previous layer (if not at input)
        delta_prev =
          if i > 0 do
            z_prev = Enum.at(z_list, i - 1)
            da = Nx.dot(delta, Nx.transpose(w))
            Nx.multiply(da, Nx.greater(z_prev, 0))
          else
            nil
          end

        {[{dw, db} | gs], delta_prev}
      end)

    grads
  end

  defp export_weights(params, path) do
    # Version 3 format: N hidden layers
    magic = "NNF3"
    version = 3
    n_layers = length(params)

    # Header: magic, version, n_layers, then each layer size
    all_sizes = [@input_size] ++ @layer_sizes ++ [@output_size]

    header = <<magic::binary, version::little-32, n_layers::little-32>>
    sizes_bin = for s <- all_sizes, into: <<>>, do: <<s::little-32>>

    # Weights and biases for each layer
    weights_bin =
      Enum.reduce(params, <<>>, fn {w, b}, acc ->
        acc <> encode_floats(Nx.to_flat_list(w)) <> encode_floats(Nx.to_flat_list(b))
      end)

    data = header <> sizes_bin <> weights_bin
    File.write!(path, data)
    Logger.info("Exported #{byte_size(data)} bytes (v3 format, #{n_layers} layers)")
  end

  defp encode_floats(list), do: for(f <- list, into: <<>>, do: <<f::little-float-32>>)
end

defmodule Mix.Tasks.Rinha.TrainAxon do
  @shortdoc "Train Axon model and export runtime payload"
  @moduledoc """
  Trains an Axon binary classifier and exports a serialized payload consumed by runtime scoring.

      MIX_ENV=preprocess mix rinha.train_axon

  Options:
      --epochs N           Training epochs (default: 30)
      --batch-size N       Batch size (default: 8192)
      --learning-rate RATE Optimizer learning rate (default: 0.01)
      --hidden-size-1 N    First dense layer units (default: 256)
      --hidden-size-2 N    Second dense layer units (default: 256)
      --sample N           Train on first N rows from dataset source (default: 300000)
      --eval-sample N      Rows used for post-train accuracy check (default: 100000)
      --dataset PATH       Labeled k6 dataset JSON (repeatable, trains from entries[*])
      --output PATH        Output model path (default: priv/model.axon)
      --max-model-mb N     Fail if saved model exceeds N MB
  """

  use Mix.Task
  require Logger

  @compile {:no_warn_undefined, EXLA.Backend}
  @compile {:no_warn_undefined, Nx}

  @input_scale 8192.0
  @default_epochs 30
  @default_batch_size 8192
  @default_learning_rate 1.0e-2
  @default_hidden_size_1 256
  @default_hidden_size_2 256
  @default_sample 300_000
  @default_eval_sample 100_000

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:exla)
    {:ok, _} = Application.ensure_all_started(:axon)
    Nx.global_default_backend(Nx.BinaryBackend)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          epochs: :integer,
          batch_size: :integer,
          learning_rate: :float,
          hidden_size_1: :integer,
          hidden_size_2: :integer,
          sample: :integer,
          eval_sample: :integer,
          dataset: :string,
          output: :string,
          max_model_mb: :string
        ]
      )

    epochs = Keyword.get(opts, :epochs, @default_epochs)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    learning_rate = Keyword.get(opts, :learning_rate, @default_learning_rate)
    hidden_size_1 = Keyword.get(opts, :hidden_size_1, @default_hidden_size_1)
    hidden_size_2 = Keyword.get(opts, :hidden_size_2, @default_hidden_size_2)
    sample = Keyword.get(opts, :sample, @default_sample)
    eval_sample = Keyword.get(opts, :eval_sample, @default_eval_sample)
    dataset_paths = Keyword.get_values(opts, :dataset)
    output_path = Keyword.get(opts, :output, Path.join(priv_dir(), "model.axon"))
    max_model_bytes = parse_max_model_bytes(opts)

    if dataset_paths != [] do
      Rinha.Domain.ReferenceData.load!()
    end

    {inputs, labels} = load_dataset(sample, dataset_paths)
    n = length(labels)

    if n < 2 do
      raise("dataset needs at least 2 rows to split train/eval")
    end

    {fraud, legit} = count_labels(labels)

    eval_count = resolve_eval_count(eval_sample, n)
    train_count = n - eval_count
    {train_inputs, eval_inputs} = Enum.split(inputs, train_count)
    {train_labels, eval_labels} = Enum.split(labels, train_count)
    batch_size = min(batch_size, length(train_labels))

    config = %{
      input_size: 16,
      hidden_size_1: hidden_size_1,
      hidden_size_2: hidden_size_2
    }

    Logger.info(
      "Axon training: rows=#{n}, train=#{length(train_labels)}, eval=#{length(eval_labels)}, fraud=#{fraud}, legit=#{legit}"
    )

    Logger.info(
      "Axon config: epochs=#{epochs}, batch_size=#{batch_size}, learning_rate=#{learning_rate}, hidden1=#{hidden_size_1}, hidden2=#{hidden_size_2}"
    )

    x_train = Nx.tensor(train_inputs, type: :f32)
    y_train = Nx.tensor(train_labels, type: :f32) |> Nx.new_axis(-1)
    x_eval = Nx.tensor(eval_inputs, type: :f32)
    y_eval = Nx.tensor(eval_labels, type: :f32) |> Nx.new_axis(-1)

    train_data =
      Stream.zip(
        Nx.to_batched(x_train, batch_size),
        Nx.to_batched(y_train, batch_size)
      )

    model = Rinha.Domain.Models.Axon.model(config)
    optimizer = Polaris.Optimizers.adam(learning_rate: learning_rate)

    model_state =
      model
      |> Axon.Loop.trainer(:binary_cross_entropy, optimizer)
      |> Axon.Loop.run(train_data, Axon.ModelState.empty(), epochs: epochs, compiler: EXLA)

    accuracy = evaluate(model, model_state, x_eval, y_eval)

    Logger.info(
      "Accuracy on #{length(eval_labels)} eval rows: #{Float.round(accuracy * 100, 3)}%"
    )

    if accuracy < 0.99 do
      Logger.warning("Training accuracy is below 99%; tune epochs/hidden sizes")
    end

    save_payload!(output_path, config, model_state)
    enforce_model_size!(output_path, max_model_bytes)
    Logger.info("Model saved to #{output_path}")
  end

  defp evaluate(model, model_state, x_eval, y_eval) do
    {_init_fn, predict_fn} = Axon.build(model, mode: :inference)

    predicted =
      predict_fn.(model_state, x_eval)
      |> Nx.greater_equal(0.5)
      |> Nx.as_type(:f32)

    Nx.equal(predicted, y_eval)
    |> Nx.mean()
    |> Nx.to_number()
  end

  defp save_payload!(output_path, config, params) do
    output_path
    |> Path.dirname()
    |> File.mkdir_p!()

    payload = %{format_version: 1, config: config, params: params}
    File.write!(output_path, Nx.serialize(payload))
  end

  defp resolve_eval_count(eval_sample, total) do
    requested =
      if is_integer(eval_sample) and eval_sample > 0,
        do: eval_sample,
        else: @default_eval_sample

    max_eval = max(total - 1_000, 1)
    min(requested, max_eval)
  end

  defp load_dataset(sample, []) do
    data = find_references_path() |> File.read!() |> :zlib.gunzip() |> Jason.decode!()
    data = maybe_take_sample(data, sample)

    data
    |> Enum.map(fn entry ->
      input = entry["vector"] |> prepare_input()
      label = if entry["label"] == "fraud", do: 1.0, else: 0.0
      {input, label}
    end)
    |> Enum.unzip()
  end

  defp load_dataset(sample, dataset_paths) do
    data =
      dataset_paths
      |> Enum.flat_map(&load_labeled_payload_dataset!/1)
      |> maybe_take_sample(sample)

    data
    |> Enum.map(fn entry ->
      input = entry["request"] |> Rinha.Domain.Vectorization.transform() |> prepare_input()
      label = if entry["expected_approved"] == true, do: 0.0, else: 1.0
      {input, label}
    end)
    |> Enum.unzip()
  end

  defp load_labeled_payload_dataset!(path) do
    path = Path.expand(path)
    Logger.info("Loading labeled payload dataset from #{path}...")

    case path |> File.read!() |> Jason.decode!() do
      %{"entries" => entries} when is_list(entries) ->
        entries

      other ->
        raise(
          "Invalid labeled dataset at #{path}: expected %{\"entries\" => [...]} got #{inspect(other)}"
        )
    end
  end

  defp maybe_take_sample(data, sample) when is_integer(sample) and sample > 0,
    do: Enum.take(data, sample)

  defp maybe_take_sample(data, _sample), do: data

  defp find_references_path do
    priv = priv_dir()

    [
      Path.join(priv, "resources/references.json.gz"),
      "resources/references.json.gz",
      System.get_env("REFERENCES_PATH")
    ]
    |> Enum.find(fn p -> p && File.exists?(p) end) || raise "references.json.gz not found"
  end

  defp prepare_input(v) when length(v) == 14, do: Enum.map(v, &scale_input/1) ++ [0.0, 0.0]
  defp prepare_input(v) when length(v) == 16, do: Enum.map(v, &scale_input/1)
  defp scale_input(x) when is_integer(x), do: x / @input_scale
  defp scale_input(x) when is_float(x), do: x

  defp count_labels(labels) do
    Enum.reduce(labels, {0, 0}, fn
      1.0, {fraud, legit} -> {fraud + 1, legit}
      _, {fraud, legit} -> {fraud, legit + 1}
    end)
  end

  defp parse_max_model_bytes(opts) do
    case Keyword.get(opts, :max_model_mb) do
      nil ->
        nil

      value ->
        case Float.parse(value) do
          {mb, ""} when mb > 0.0 -> trunc(mb * 1024 * 1024)
          _ -> raise("--max-model-mb must be a positive number, got: #{inspect(value)}")
        end
    end
  end

  defp enforce_model_size!(_path, nil), do: :ok

  defp enforce_model_size!(path, max_bytes) do
    size = File.stat!(path).size

    if size > max_bytes do
      raise(
        "model exceeds size limit: #{size} bytes > #{max_bytes} bytes (#{Float.round(size / 1024 / 1024, 2)} MB)"
      )
    end

    :ok
  end

  defp priv_dir do
    case :code.priv_dir(:rinha) do
      {:error, :bad_name} -> Path.join([File.cwd!(), "priv"])
      path -> List.to_string(path)
    end
  end
end

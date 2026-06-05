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
      --seed N             Shuffle seed for train/eval split (default: 42)
      --sample N           Train on first N rows from dataset source (default: 300000)
      --eval-sample N      Rows used for post-train accuracy check (default: 100000)
      --dataset PATH       Labeled k6 dataset JSON (repeatable, trains from entries[*])
      --approve-threshold RATE
                           Optional fixed approval threshold (default: auto-tuned on eval split)
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
  @default_seed 42
  @default_sample 300_000
  @default_eval_sample 100_000
  @threshold_min 0.31
  @threshold_max 0.95
  @threshold_step 0.01

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
          seed: :integer,
          sample: :integer,
          eval_sample: :integer,
          dataset: :keep,
          approve_threshold: :float,
          output: :string,
          max_model_mb: :string
        ]
      )

    epochs = Keyword.get(opts, :epochs, @default_epochs)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    learning_rate = Keyword.get(opts, :learning_rate, @default_learning_rate)
    hidden_size_1 = Keyword.get(opts, :hidden_size_1, @default_hidden_size_1)
    hidden_size_2 = Keyword.get(opts, :hidden_size_2, @default_hidden_size_2)
    seed = Keyword.get(opts, :seed, @default_seed)
    sample = Keyword.get(opts, :sample, @default_sample)
    eval_sample = Keyword.get(opts, :eval_sample, @default_eval_sample)
    dataset_paths = Keyword.get_values(opts, :dataset)
    fixed_threshold = Keyword.get(opts, :approve_threshold)
    output_path = Keyword.get(opts, :output, Path.join(priv_dir(), "model.axon"))
    max_model_bytes = parse_max_model_bytes(opts)

    if dataset_paths != [] do
      Rinha.Domain.ReferenceData.load!()
    end

    {raw_inputs, raw_labels} = load_dataset(sample, dataset_paths)
    {inputs, labels} = shuffle_dataset(raw_inputs, raw_labels, seed)
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
      "Axon config: epochs=#{epochs}, batch_size=#{batch_size}, learning_rate=#{learning_rate}, hidden1=#{hidden_size_1}, hidden2=#{hidden_size_2}, seed=#{seed}"
    )

    x_train = Nx.tensor(train_inputs, type: :f32)
    y_train = Nx.tensor(train_labels, type: :f32) |> Nx.new_axis(-1)

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

    eval_probs = predict_probabilities(model, model_state, eval_inputs, batch_size)
    threshold_result = pick_threshold(eval_probs, eval_labels, fixed_threshold)
    approve_threshold = threshold_result.threshold
    accuracy = threshold_result.accuracy

    Logger.info(
      "Eval at threshold=#{Float.round(approve_threshold, 3)}: accuracy=#{Float.round(accuracy * 100, 3)}% fp=#{threshold_result.fp} fn=#{threshold_result.fn} failures=#{threshold_result.failures} (#{Float.round(threshold_result.failure_rate * 100, 2)}%) weighted_E=#{threshold_result.weighted_errors}"
    )

    if threshold_result.detection_cut? do
      Logger.warning(
        "Detection-score cutoff would still trigger on eval split (failure rate > 15%). Tune architecture/epochs/dataset."
      )
    end

    config = Map.put(config, :approve_threshold, approve_threshold)

    save_payload!(output_path, config, model_state)
    enforce_model_size!(output_path, max_model_bytes)
    Logger.info("Model saved to #{output_path}")
  end

  defp shuffle_dataset(inputs, labels, seed) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    {shuffled_inputs, shuffled_labels} =
      inputs
      |> Enum.zip(labels)
      |> Enum.shuffle()
      |> Enum.unzip()

    {shuffled_inputs, shuffled_labels}
  end

  defp predict_probabilities(model, model_state, eval_inputs, batch_size) do
    {_init_fn, predict_fn} = Axon.build(model, mode: :inference)
    compiled_predict = Nx.Defn.jit(predict_fn, compiler: EXLA)

    eval_inputs
    |> Enum.chunk_every(max(batch_size, 1))
    |> Enum.flat_map(fn batch ->
      batch
      |> Nx.tensor(type: :f32)
      |> then(&compiled_predict.(model_state, &1))
      |> Nx.to_flat_list()
    end)
  end

  defp pick_threshold(probabilities, labels, fixed_threshold) do
    if is_nil(fixed_threshold) do
      threshold_candidates()
      |> Enum.map(&evaluate_threshold(probabilities, labels, &1))
      |> Enum.max_by(fn stats ->
        {stats.detection_score, -stats.failure_rate, -stats.weighted_errors}
      end)
    else
      fixed_threshold
      |> normalize_threshold()
      |> then(&evaluate_threshold(probabilities, labels, &1))
    end
  end

  defp threshold_candidates do
    start = trunc(@threshold_min * 100)
    stop = trunc(@threshold_max * 100)
    step = trunc(@threshold_step * 100)

    for threshold <- start..stop//step do
      threshold / 100
    end
  end

  defp normalize_threshold(value) when is_float(value),
    do: min(max(value, @threshold_min), @threshold_max)

  defp normalize_threshold(value) when is_integer(value), do: (value / 1) |> normalize_threshold()
  defp normalize_threshold(_), do: 0.5

  defp evaluate_threshold(probabilities, labels, threshold) do
    {fp, fnn} =
      Enum.zip(probabilities, labels)
      |> Enum.reduce({0, 0}, fn {prob, label}, {fp, fnn} ->
        approved = prob < threshold

        cond do
          label == 1.0 and approved -> {fp, fnn + 1}
          label == 0.0 and not approved -> {fp + 1, fnn}
          true -> {fp, fnn}
        end
      end)

    n = length(labels)
    failures = fp + fnn
    weighted_errors = fp + 3 * fnn
    epsilon = weighted_errors / n
    failure_rate = failures / n
    detection_cut? = failure_rate > 0.15

    {detection_score, rate_component, absolute_penalty} =
      if detection_cut? do
        {-3000.0, nil, nil}
      else
        rate_component = 1000.0 * :math.log10(1 / max(epsilon, 0.001))
        absolute_penalty = -300.0 * :math.log10(1 + weighted_errors)
        {rate_component + absolute_penalty, rate_component, absolute_penalty}
      end

    %{
      threshold: threshold,
      fp: fp,
      fn: fnn,
      failures: failures,
      weighted_errors: weighted_errors,
      epsilon: epsilon,
      failure_rate: failure_rate,
      detection_cut?: detection_cut?,
      detection_score: detection_score,
      rate_component: rate_component,
      absolute_penalty: absolute_penalty,
      accuracy: (n - failures) / n
    }
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

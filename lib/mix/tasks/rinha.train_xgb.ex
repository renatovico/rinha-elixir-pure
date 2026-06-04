defmodule Mix.Tasks.Rinha.TrainXgb do
  @shortdoc "Train XGBoost and export pure-Elixir tree ensemble"
  @moduledoc """
  Trains a boosted tree model with the Elixir `exgboost` preprocess dependency,
  then exports a compact binary model that runtime scores in pure Elixir.

      MIX_ENV=preprocess mix rinha.train_xgb

  Options:
      --rounds N           Boosting rounds (default: 500)
      --depth N            Maximum tree depth (default: 8)
      --eta RATE           Learning rate (default: 0.08)
      --subsample RATE     Row subsample per tree (default: 1.0)
      --threads N          XGBoost CPU threads (default: schedulers online, max 8)
      --max-bin N          Histogram bins (default: 256)
      --sample N           Train on first N rows from the chosen dataset source
      --eval-sample N      Rows used for post-train accuracy check (default: 100000)
      --dataset PATH       Labeled k6 dataset JSON (repeatable, trains from entries[*])
      --in-memory          Force dense Nx tensor training, unsafe for full dataset
      --external-memory    Use XGBoost external cache for the temporary LIBSVM file
      --output PATH        Output model path (default: priv/xgboost.bin)
  """

  use Mix.Task
  require Logger

  @compile {:no_warn_undefined, EXGBoost}
  @compile {:no_warn_undefined, EXGBoost.Booster}
  @compile {:no_warn_undefined, EXGBoost.DMatrix}
  @compile {:no_warn_undefined, EXGBoost.Internal}
  @compile {:no_warn_undefined, EXGBoost.NIF}
  @compile {:no_warn_undefined, EXGBoost.Training}
  @compile {:no_warn_undefined, EXLA.Backend}
  @compile {:no_warn_undefined, Nx}

  @input_scale 8192.0
  @eval_batch_size 5_000
  @default_rounds 500
  @default_depth 8
  @default_eta 0.08
  @default_subsample 1.0
  @default_eval_sample 100_000

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:exgboost)
    Nx.global_default_backend(Nx.BinaryBackend)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          rounds: :integer,
          depth: :integer,
          eta: :float,
          subsample: :float,
          threads: :integer,
          max_bin: :integer,
          sample: :integer,
          eval_sample: :integer,
          dataset: :string,
          external_memory: :boolean,
          in_memory: :boolean,
          output: :string
        ]
      )

    rounds = Keyword.get(opts, :rounds, @default_rounds)
    depth = Keyword.get(opts, :depth, @default_depth)
    eta = Keyword.get(opts, :eta, @default_eta)
    subsample = Keyword.get(opts, :subsample, @default_subsample)
    threads = Keyword.get(opts, :threads, min(System.schedulers_online(), 8))
    max_bin = Keyword.get(opts, :max_bin, 256)
    sample = Keyword.get(opts, :sample)
    eval_sample = Keyword.get(opts, :eval_sample, @default_eval_sample)
    dataset_paths = Keyword.get_values(opts, :dataset)

    if dataset_paths != [] do
      Rinha.Domain.ReferenceData.load!()
    end

    file_backed? = file_backed?(opts, sample, dataset_paths)
    external_cache? = Keyword.get(opts, :external_memory, false)

    output_path = Keyword.get(opts, :output, Path.join(priv_dir(), "xgboost.bin"))

    Logger.info(
      "XGBoost training: rounds=#{rounds}, depth=#{depth}, eta=#{eta}, subsample=#{subsample}, threads=#{threads}, max_bin=#{max_bin}"
    )

    train_opts = train_opts(rounds, depth, eta, subsample, threads, max_bin)

    {booster, eval_inputs, eval_labels} =
      if file_backed? do
        train_file_backed(eval_sample, train_opts, external_cache?)
      else
        train_in_memory(sample, eval_sample, train_opts, dataset_paths)
      end

    acc = evaluate(booster, eval_inputs, eval_labels)

    Logger.info(
      "Accuracy on #{length(eval_labels)} sampled training rows: #{Float.round(acc * 100, 3)}%"
    )

    if acc < 0.99 do
      Logger.warning("Training accuracy is below 99%; try increasing --rounds or --depth")
    end

    export_booster(booster, output_path)
    Logger.info("Done!")
  end

  defp file_backed?(opts, sample, dataset_paths) do
    cond do
      dataset_paths != [] -> false
      Keyword.get(opts, :in_memory, false) -> false
      Keyword.get(opts, :external_memory, false) -> true
      is_integer(sample) -> false
      true -> true
    end
  end

  defp train_opts(rounds, depth, eta, subsample, threads, max_bin) do
    [
      objective: :binary_logistic,
      eval_metric: [:error, :logloss],
      num_boost_rounds: rounds,
      max_depth: depth,
      eta: eta,
      subsample: subsample,
      min_child_weight: 1.0,
      tree_method: :hist,
      max_bin: max_bin,
      predictor: :cpu_predictor,
      nthread: threads,
      verbose_eval: 25
    ]
  end

  defp train_in_memory(sample, eval_sample, train_opts, dataset_paths) do
    {inputs, labels} = load_dataset(sample, dataset_paths)
    n = length(labels)
    {fraud, legit} = count_labels(labels)
    Logger.info("Dataset: #{n} samples (#{fraud} fraud, #{legit} legit, mode=in-memory)")
    Logger.info("Converting dataset to Nx tensors...")

    x = Nx.tensor(inputs, type: :f32)
    y = Nx.tensor(labels, type: :f32)
    Logger.info("Training booster...")

    booster = EXGBoost.train(x, y, train_opts)
    {eval_inputs, eval_labels} = take_eval_sample(inputs, labels, eval_sample)
    {booster, eval_inputs, eval_labels}
  end

  defp take_eval_sample(inputs, labels, eval_sample)
       when is_integer(eval_sample) and eval_sample > 0 do
    {Enum.take(inputs, eval_sample), Enum.take(labels, eval_sample)}
  end

  defp take_eval_sample(inputs, labels, _eval_sample), do: {inputs, labels}

  defp train_file_backed(eval_sample, train_opts, external_cache?) do
    %{
      path: path,
      cache: cache,
      eval_path: eval_path,
      eval_count: eval_count,
      count: n,
      fraud: fraud,
      legit: legit
    } =
      write_libsvm_dataset(eval_sample)

    mode = if external_cache?, do: "external-memory", else: "sparse-file"

    Logger.info("Dataset: #{n} samples (#{fraud} fraud, #{legit} legit, mode=#{mode})")
    Logger.info("Training from #{path}")
    :erlang.garbage_collect()

    dmat = dmatrix_from_libsvm(path, cache, mode == "external-memory")
    booster = EXGBoost.Training.train(dmat, train_opts)
    {eval_inputs, eval_labels} = load_eval_dataset(eval_path, eval_count)
    {booster, eval_inputs, eval_labels}
  end

  defp dmatrix_from_libsvm(path, cache, external_memory?) do
    uri = "#{path}?format=libsvm"
    uri = if external_memory?, do: uri <> "##{cache}", else: uri
    config = Jason.encode!(%{uri: uri, silent: 0, data_split_mode: 0})

    dmat_ref =
      case EXGBoost.NIF.dmatrix_create_from_uri(config) do
        {:ok, ref} -> ref
        {:error, reason} -> raise to_string(reason)
      end

    struct(EXGBoost.DMatrix, ref: dmat_ref, format: :sparse)
  end

  defp priv_dir do
    case :code.priv_dir(:rinha) do
      {:error, :bad_name} -> Path.join([File.cwd!(), "priv"])
      path -> List.to_string(path)
    end
  end

  defp load_dataset(sample, []) do
    data = find_references_path() |> File.read!() |> :zlib.gunzip() |> Jason.decode!()
    data = if is_integer(sample) and sample > 0, do: Enum.take(data, sample), else: data

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
      %{"entries" => entries} when is_list(entries) -> entries
      other -> raise("Invalid labeled dataset at #{path}: expected %{\"entries\" => [...]} got #{inspect(other)}")
    end
  end

  defp maybe_take_sample(data, sample) when is_integer(sample) and sample > 0, do: Enum.take(data, sample)
  defp maybe_take_sample(data, _sample), do: data

  defp write_libsvm_dataset(eval_sample) do
    dir = Path.join(System.tmp_dir!(), "rinha-xgb")
    File.mkdir_p!(dir)

    suffix = System.unique_integer([:positive])
    path = Path.join(dir, "references-#{suffix}.libsvm")
    cache = Path.join(dir, "cache-#{suffix}")
    eval_path = Path.join(dir, "eval-#{suffix}.bin")
    File.touch!(cache)

    Logger.info("Writing scaled LIBSVM training file to #{path}...")

    data = find_references_path() |> File.read!() |> :zlib.gunzip() |> Jason.decode!()

    file = File.open!(path, [:write, :raw, {:delayed_write, 1_048_576, 1000}])
    eval_file = File.open!(eval_path, [:write, :raw, {:delayed_write, 1_048_576, 1000}])

    try do
      {count, fraud, legit, eval_count} =
        Enum.reduce(data, {0, 0, 0, 0}, fn entry, {count, fraud, legit, eval_count} ->
          input = entry["vector"] |> prepare_input()
          label = if entry["label"] == "fraud", do: 1.0, else: 0.0
          IO.binwrite(file, IO.iodata_to_binary(libsvm_row(label, input)))

          {fraud, legit} = if label == 1.0, do: {fraud + 1, legit}, else: {fraud, legit + 1}
          count = count + 1

          if rem(count, 250_000) == 0 do
            Logger.info("Wrote #{count} LIBSVM rows...")
          end

          if eval_count < eval_sample do
            IO.binwrite(eval_file, encode_eval_row(label, input))
            {count, fraud, legit, eval_count + 1}
          else
            {count, fraud, legit, eval_count}
          end
        end)

      %{
        path: path,
        cache: cache,
        eval_path: eval_path,
        eval_count: eval_count,
        count: count,
        fraud: fraud,
        legit: legit
      }
    after
      File.close(file)
      File.close(eval_file)
    end
  end

  defp find_references_path do
    priv = priv_dir()

    [
      Path.join(priv, "resources/references.json.gz"),
      "resources/references.json.gz",
      System.get_env("REFERENCES_PATH")
    ]
    |> Enum.find(fn p -> p && File.exists?(p) end) || raise "references.json.gz not found"
  end

  defp prepare_input(v) when length(v) == 16, do: Enum.map(v, &scale_input/1)
  defp scale_input(x) when is_integer(x), do: x / @input_scale
  defp scale_input(x) when is_float(x), do: x

  defp encode_eval_row(label, input) do
    label_byte = if label == 1.0, do: 1, else: 0
    floats = for value <- input, into: <<>>, do: <<value::little-float-32>>
    <<label_byte::unsigned-8, floats::binary>>
  end

  defp load_eval_dataset(path, count) do
    Logger.info("Loading #{count} sampled eval rows from #{path}...")

    path
    |> File.read!()
    |> decode_eval_rows([], [])
  end

  defp decode_eval_rows(<<>>, inputs, labels), do: {Enum.reverse(inputs), Enum.reverse(labels)}

  defp decode_eval_rows(<<label::unsigned-8, row::binary-size(64), rest::binary>>, inputs, labels) do
    input = for <<value::little-float-32 <- row>>, do: value
    label = if label == 1, do: 1.0, else: 0.0
    decode_eval_rows(rest, [input | inputs], [label | labels])
  end

  defp decode_eval_rows(_bad, _inputs, _labels), do: raise("Invalid eval sample file")

  defp libsvm_row(label, input) do
    [label_text(label), features_text(input, 0), "\n"]
  end

  defp label_text(1.0), do: "1"
  defp label_text(_), do: "0"

  defp features_text([], _idx), do: []

  defp features_text([value | rest], idx) do
    [
      " ",
      Integer.to_string(idx),
      ":",
      :erlang.float_to_binary(value, [:compact, decimals: 8]) | features_text(rest, idx + 1)
    ]
  end

  defp count_labels(labels) do
    Enum.reduce(labels, {0, 0}, fn
      1.0, {fraud, legit} -> {fraud + 1, legit}
      _, {fraud, legit} -> {fraud, legit + 1}
    end)
  end

  defp evaluate(booster, x, labels) do
    predictions = predict_eval(booster, x)

    correct =
      Enum.zip(predictions, labels)
      |> Enum.count(fn {pred, label} ->
        predicted = if pred >= 0.5, do: 1.0, else: 0.0
        predicted == label
      end)

    correct / length(labels)
  end

  defp predict_eval(booster, x) when is_list(x) do
    x
    |> Enum.chunk_every(@eval_batch_size)
    |> Enum.flat_map(fn batch ->
      batch
      |> Nx.tensor(type: :f32)
      |> then(&EXGBoost.predict(booster, &1))
      |> Nx.to_flat_list()
    end)
  end

  defp predict_eval(booster, x) do
    x = if tensor?(x), do: x, else: Nx.tensor(x, type: :f32)
    booster |> EXGBoost.predict(x) |> Nx.to_flat_list()
  end

  defp tensor?(%{__struct__: Nx.Tensor}), do: true
  defp tensor?(_), do: false

  defp export_booster(booster, path) do
    trees =
      booster
      |> EXGBoost.Booster.get_dump(format: :json)
      |> Enum.map(fn tree_json ->
        tree_json |> to_string() |> Jason.decode!() |> flatten_tree()
      end)

    config = booster |> EXGBoost.dump_config() |> Jason.decode!()
    base_score = get_in(config, ["learner", "learner_model_param", "base_score"]) |> parse_float()
    base_margin = logit(base_score)

    trees_bin =
      Enum.map_join(trees, "", fn nodes ->
        <<length(nodes)::little-32>> <> encode_nodes(nodes)
      end)

    data =
      <<"RFF2", 2::little-32, 2::unsigned-8, base_margin::little-float-64,
        length(trees)::little-32>> <> trees_bin

    File.write!(path, data)
    Logger.info("Exported #{length(trees)} boosted trees, #{byte_size(data)} bytes to #{path}")
  end

  defp flatten_tree(tree), do: elem(flatten_tree(tree, []), 0)

  defp flatten_tree(%{"leaf" => value}, acc),
    do: {acc ++ [{-1, 0.0, 0, 0, value * 1.0}], length(acc)}

  defp flatten_tree(
         %{
           "split" => split,
           "split_condition" => threshold,
           "yes" => yes,
           "no" => no,
           "children" => children
         },
         acc
       ) do
    idx = length(acc)
    feature = parse_feature(split)
    children_by_id = Map.new(children, fn child -> {child["nodeid"], child} end)

    {left_nodes, left_idx} =
      flatten_tree(
        Map.fetch!(children_by_id, yes),
        acc ++ [{feature, threshold * 1.0, 0, 0, 0.0}]
      )

    {right_nodes, right_idx} = flatten_tree(Map.fetch!(children_by_id, no), left_nodes)

    nodes =
       List.replace_at(right_nodes, idx, {feature, threshold * 1.0, left_idx, right_idx, 0.0})

    {nodes, idx}
  end

  defp parse_feature("f" <> n), do: String.to_integer(n)

  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v * 1.0
  defp parse_float(v) when is_binary(v), do: String.to_float(v)

  defp logit(p), do: :math.log(p / (1.0 - p))

  defp encode_nodes(nodes) do
    for {feature, threshold, left, right, value} <- nodes, into: <<>> do
      <<feature::signed-little-8, threshold::little-float-64, left::little-32, right::little-32,
        value::little-float-64>>
    end
  end
end

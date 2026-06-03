defmodule Mix.Tasks.Rinha.TrainRf do
  @shortdoc "Train pure-Elixir random forest on references dataset"
  @moduledoc """
  Trains a small random forest and exports it for pure-Elixir runtime scoring.

      MIX_ENV=preprocess mix rinha.train_rf

  Options:
      --trees N       Number of trees (default: 25)
      --depth N       Maximum tree depth (default: 7)
      --min-leaf N    Minimum samples per leaf (default: 32)
      --output PATH   Output model path
  """

  use Mix.Task
  require Logger

  @input_scale 8192.0
  @feature_count 16
  @default_trees 25
  @default_depth 7
  @default_min_leaf 32

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [trees: :integer, depth: :integer, min_leaf: :integer, output: :string]
      )

    tree_count = Keyword.get(opts, :trees, @default_trees)
    max_depth = Keyword.get(opts, :depth, @default_depth)
    min_leaf = Keyword.get(opts, :min_leaf, @default_min_leaf)
    output_path = Keyword.get(opts, :output, Path.join(priv_dir(), "random_forest.bin"))

    :rand.seed(:exsss, {42, 42, 42})

    Logger.info(
      "Random forest training: trees=#{tree_count}, depth=#{max_depth}, min_leaf=#{min_leaf}"
    )

    {x, y} = load_dataset()
    Logger.info("Dataset: #{length(x)} samples")

    trees =
      1..tree_count
      |> Enum.map(fn i ->
        Logger.info("Training tree #{i}/#{tree_count}")
        sample = bootstrap_sample(x, y)
        build_tree(sample, 0, max_depth, min_leaf)
      end)

    acc = evaluate(trees, x, y)
    Logger.info("Final accuracy: #{Float.round(acc * 100, 2)}%")

    export_forest(trees, output_path)
    Logger.info("Done!")
  end

  defp priv_dir do
    case :code.priv_dir(:rinha) do
      {:error, :bad_name} -> Path.join([File.cwd!(), "priv"])
      path -> List.to_string(path)
    end
  end

  defp load_dataset do
    data = find_references_path() |> File.read!() |> :zlib.gunzip() |> Jason.decode!()

    data
    |> Enum.map(fn entry ->
      input = entry["vector"] |> prepare_input() |> List.to_tuple()
      label = if entry["label"] == "fraud", do: 1.0, else: 0.0
      {input, label}
    end)
    |> Enum.unzip()
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

  defp prepare_input(v) when length(v) == 14, do: Enum.map(v, &scale_input/1) ++ [0.0, 0.0]
  defp prepare_input(v) when length(v) == 16, do: Enum.map(v, &scale_input/1)
  defp scale_input(x) when is_integer(x), do: x / @input_scale
  defp scale_input(x) when is_float(x), do: x

  defp bootstrap_sample(x, y) do
    n = length(x)
    xt = List.to_tuple(x)
    yt = List.to_tuple(y)

    for _ <- 1..n do
      idx = :rand.uniform(n) - 1
      {elem(xt, idx), elem(yt, idx)}
    end
  end

  defp build_tree(rows, depth, max_depth, min_leaf) do
    prob = mean_label(rows)

    if depth >= max_depth or length(rows) <= min_leaf * 2 or prob in [0.0, 1.0] do
      {:leaf, prob}
    else
      case best_split(rows, min_leaf) do
        nil ->
          {:leaf, prob}

        {feature, threshold, left, right} ->
          {:node, feature, threshold, build_tree(left, depth + 1, max_depth, min_leaf),
           build_tree(right, depth + 1, max_depth, min_leaf)}
      end
    end
  end

  defp best_split(rows, min_leaf) do
    features = Enum.take_random(0..(@feature_count - 1), 5)

    features
    |> Enum.flat_map(fn feature -> candidate_splits(rows, feature, min_leaf) end)
    |> Enum.min_by(fn {gain, _feature, _threshold, _left, _right} -> -gain end, fn -> nil end)
    |> case do
      nil -> nil
      {gain, feature, threshold, left, right} when gain > 0.0 -> {feature, threshold, left, right}
      _ -> nil
    end
  end

  defp candidate_splits(rows, feature, min_leaf) do
    thresholds =
      rows
      |> Enum.take_random(min(length(rows), 32))
      |> Enum.map(fn {x, _y} -> elem(x, feature) end)
      |> Enum.uniq()

    parent_gini = gini(rows)
    parent_n = length(rows)

    Enum.flat_map(thresholds, fn threshold ->
      {left, right} = Enum.split_with(rows, fn {x, _y} -> elem(x, feature) <= threshold end)

      if length(left) < min_leaf or length(right) < min_leaf do
        []
      else
        weighted = (length(left) * gini(left) + length(right) * gini(right)) / parent_n
        [{parent_gini - weighted, feature, threshold, left, right}]
      end
    end)
  end

  defp gini(rows) do
    p = mean_label(rows)
    1.0 - p * p - (1.0 - p) * (1.0 - p)
  end

  defp mean_label(rows) do
    Enum.reduce(rows, 0.0, fn {_x, y}, acc -> acc + y end) / length(rows)
  end

  defp evaluate(trees, x, y) do
    total = length(x)

    correct =
      Enum.zip(x, y)
      |> Enum.count(fn {input, label} ->
        pred = if predict(trees, input) >= 0.5, do: 1.0, else: 0.0
        pred == label
      end)

    correct / total
  end

  defp predict(trees, input) do
    Enum.reduce(trees, 0.0, fn tree, acc -> acc + eval_tree(tree, input) end) / length(trees)
  end

  defp eval_tree({:leaf, value}, _input), do: value

  defp eval_tree({:node, feature, threshold, left, right}, input) do
    if elem(input, feature) <= threshold,
      do: eval_tree(left, input),
      else: eval_tree(right, input)
  end

  defp export_forest(trees, path) do
    trees_bin =
      Enum.map_join(trees, "", fn tree ->
        nodes = flatten_tree(tree)
        <<length(nodes)::little-32>> <> encode_nodes(nodes)
      end)

    data = <<"RFF1", 1::little-32, length(trees)::little-32>> <> trees_bin
    File.write!(path, data)
    Logger.info("Exported #{byte_size(data)} bytes to #{path}")
  end

  defp flatten_tree(tree), do: elem(flatten_tree(tree, []), 0)

  defp flatten_tree({:leaf, value}, acc), do: {acc ++ [{-1, 0.0, 0, 0, value}], length(acc)}

  defp flatten_tree({:node, feature, threshold, left, right}, acc) do
    idx = length(acc)
    {left_nodes, left_idx} = flatten_tree(left, acc ++ [{feature, threshold, 0, 0, 0.0}])
    {right_nodes, right_idx} = flatten_tree(right, left_nodes)
    nodes = List.replace_at(right_nodes, idx, {feature, threshold, left_idx, right_idx, 0.0})
    {nodes, idx}
  end

  defp encode_nodes(nodes) do
    for {feature, threshold, left, right, value} <- nodes, into: <<>> do
      <<feature::signed-little-8, threshold::little-float-32, left::little-32, right::little-32,
        value::little-float-32>>
    end
  end
end

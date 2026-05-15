defmodule Mix.Tasks.Rinha.Bench do
  @moduledoc """
  Benchmarks the IVF scanner against the brute-force scanner.

  ## What it does

    1. Generates `--count N` synthetic payloads via `Rinha.FraudSimulator`.
    2. Transforms each to a 16-int vector.
    3. For each payload:
         * brute-force score (oracle, full 3M scan)
         * IVF score with each `P` in `--probes` (default 1,2,4,8)
    4. Reports per-P:
         * recall    — share of queries whose IVF n matches brute-force n
         * accuracy  — same thing per fraud bucket (`n` exactly equal)
         * mean / p50 / p95 / p99 latency

  ## Usage

      MIX_ENV=dev mix rinha.bench --count 500 --probes 1,2,4,8

      MIX_ENV=dev mix rinha.bench --count 200 --seed 42

  Costs ~70 ms per brute-force probe on a laptop, so 500 queries ~= 35 s.
  """

  use Mix.Task

  @shortdoc "Benchmark IVF vs brute-force scoring"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [count: :integer, probes: :string, seed: :integer, fraud_bias: :float],
        aliases: [n: :count, p: :probes]
      )

    count = Keyword.get(opts, :count, 200)

    probes_list =
      opts
      |> Keyword.get(:probes, "1,2,4,8")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_integer/1)

    fraud_bias = Keyword.get(opts, :fraud_bias, 0.33)
    seed = Keyword.get(opts, :seed, 1)

    Mix.shell().info("Booting Rinha (without HTTP listeners)...")
    Application.put_env(:rinha, :socket_path, nil)
    {:ok, _} = Application.ensure_all_started(:rinha)

    # Brute-force scanner needs KnnStore loaded (not started by app since we
    # moved to IVF as the hot path).
    Mix.shell().info("Loading KnnStore (brute-force oracle backing)...")
    :ok = Rinha.KnnStore.build()

    # Generate dataset (deterministic)
    Mix.shell().info("Generating #{count} synthetic queries (seed=#{seed}, bias=#{fraud_bias})...")
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    queries =
      for _ <- 1..count do
        {label, payload} = Rinha.FraudSimulator.generate(fraud_bias: fraud_bias)
        vec = Rinha.VectorTransformerV2.transform(payload)
        {label, vec}
      end

    # Brute-force oracle pass (warmup + measured)
    Mix.shell().info("Running brute-force oracle (#{count} queries)...")
    {brute_us, brute_results} =
      :timer.tc(fn ->
        for {_label, vec} <- queries do
          topk = Rinha.KnnScanner.scan_all(vec)
          Rinha.KnnScanner.fraud_count(topk)
        end
      end)

    Mix.shell().info(
      "  brute total=#{ms(brute_us)}ms  mean=#{div(brute_us, count)}us"
    )

    # IVF passes per probe count
    fixed_results =
      for p <- probes_list do
        Mix.shell().info("Running IVF P=#{p} (#{count} queries)...")

        # Warmup (one pass) to ensure caches/binary refs are hot
        for {_label, vec} <- Enum.take(queries, 10) do
          _ = Rinha.IvfScanner.score(vec, p)
        end

        latencies =
          for {_label, vec} <- queries do
            {us, n} = :timer.tc(fn -> Rinha.IvfScanner.score(vec, p) end)
            {us, n}
          end

        ivf_results = Enum.map(latencies, fn {_us, n} -> n end)
        us_list = Enum.map(latencies, fn {us, _n} -> us end)

        recall = recall(brute_results, ivf_results)
        bucket_match = bucket_match(brute_results, ivf_results)

        %{
          label: "P=#{p}",
          recall: recall,
          bucket_match: bucket_match,
          mean_us: mean(us_list),
          p50_us: percentile(us_list, 0.50),
          p95_us: percentile(us_list, 0.95),
          p99_us: percentile(us_list, 0.99),
          max_us: Enum.max(us_list)
        }
      end

    # Adaptive pass (P=2 → P=3 escalation on disagreement, with 50ms budget)
    Mix.shell().info("Running IVF adaptive (#{count} queries)...")

    for {_label, vec} <- Enum.take(queries, 10) do
      _ = Rinha.IvfScanner.score_adaptive(vec)
    end

    adaptive_latencies =
      for {_label, vec} <- queries do
        {us, n} = :timer.tc(fn -> Rinha.IvfScanner.score_adaptive(vec) end)
        {us, n}
      end

    adaptive_ns = Enum.map(adaptive_latencies, fn {_us, n} -> n end)
    adaptive_us = Enum.map(adaptive_latencies, fn {us, _n} -> us end)

    adaptive_result = %{
      label: "adaptive",
      recall: recall(brute_results, adaptive_ns),
      bucket_match: bucket_match(brute_results, adaptive_ns),
      mean_us: mean(adaptive_us),
      p50_us: percentile(adaptive_us, 0.50),
      p95_us: percentile(adaptive_us, 0.95),
      p99_us: percentile(adaptive_us, 0.99),
      max_us: Enum.max(adaptive_us)
    }

    results = fixed_results ++ [adaptive_result]

    Mix.shell().info("\n=== Results ===\n")
    Mix.shell().info(
      "  mode      | recall | bucket | mean_us | p50  | p95   | p99   | max"
    )
    Mix.shell().info(
      "------------+--------+--------+---------+------+-------+-------+------"
    )

    for r <- results do
      Mix.shell().info(
        :io_lib.format(
          "  ~-9s | ~6.2f | ~6.2f | ~7w | ~4w | ~5w | ~5w | ~5w",
          [
            r.label,
            r.recall * 100,
            r.bucket_match * 100,
            r.mean_us,
            r.p50_us,
            r.p95_us,
            r.p99_us,
            r.max_us
          ]
        )
        |> IO.iodata_to_binary()
      )
    end

    Mix.shell().info("")
    Mix.shell().info(
      "Recall = share of queries where IVF n exactly matches brute-force n."
    )
    Mix.shell().info(
      "(Same column == bucket_match for k=5 since fraud_count drives bucket.)"
    )
  end

  ## Helpers

  defp recall(a, b) do
    matches =
      a
      |> Enum.zip(b)
      |> Enum.count(fn {x, y} -> x == y end)

    matches / max(length(a), 1)
  end

  defp bucket_match(a, b), do: recall(a, b)

  defp mean([]), do: 0
  defp mean(xs), do: div(Enum.sum(xs), length(xs))

  defp percentile([], _), do: 0
  defp percentile(xs, pct) do
    sorted = Enum.sort(xs)
    idx = max(0, trunc(length(sorted) * pct) - 1)
    Enum.at(sorted, idx)
  end

  defp ms(us), do: div(us, 1000)
end

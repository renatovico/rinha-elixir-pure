defmodule Mix.Tasks.Rinha.Simulate do
  @moduledoc """
  Run synthetic fraud-score payloads through the local pipeline and print
  aggregated stats.

      mix rinha.simulate [--count 10000] [--bias 0.33] [--warmup 200] [--seed 42]
                         [--json]

  Options:

    * `--count`  - number of payloads to score (default 10000)
    * `--bias`   - probability that a generated payload is fraud (0..1)
    * `--warmup` - samples discarded before measurement starts
    * `--seed`   - integer seed for deterministic input
    * `--json`   - emit machine-readable JSON instead of human text
  """

  use Mix.Task

  @shortdoc "Stress the KNN pipeline with synthetic payloads"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          count: :integer,
          bias: :float,
          warmup: :integer,
          seed: :integer,
          json: :boolean
        ]
      )

    count = opts[:count] || 10_000
    bias = opts[:bias] || 0.33
    warmup = opts[:warmup] || min(500, div(count, 10))
    seed = opts[:seed]
    json? = opts[:json] || false

    Mix.Task.run("loadpaths")
    {:ok, _} = Application.ensure_all_started(:jason)

    Rinha.Resources.load!()
    :persistent_term.put(:prof_counter, :atomics.new(1, signed: false))
    :ok = Rinha.KnnStore.build()

    sim_opts = [fraud_bias: bias, warmup: warmup]
    sim_opts = if seed, do: [{:seed, {seed, seed + 1, seed + 2}} | sim_opts], else: sim_opts

    t0 = System.monotonic_time(:microsecond)
    stats = Rinha.FraudSimulator.run(count, sim_opts)
    elapsed = System.monotonic_time(:microsecond) - t0

    final =
      stats
      |> Map.put(:wall_us, elapsed)
      |> Map.put(:throughput_per_sec, throughput(count, elapsed))
      |> Map.put(:params, %{count: count, fraud_bias: bias, warmup: warmup, seed: seed})

    if json? do
      Mix.shell().info(Jason.encode!(final))
    else
      print_human(final)
    end
  end

  defp print_human(s) do
    Mix.shell().info("""

    ── Rinha simulation ──────────────────────────────────────────
    count:           #{s.count}
    wall:            #{format_us(s.wall_us)}
    throughput:      #{s.throughput_per_sec} req/s

    accuracy:        #{percent(s.accuracy)}
    recall (fraud):  #{percent(s.recall_fraud)}
    precision (ok):  #{percent(s.precision_legit)}

    latency total    min=#{us(s.latency.total.min)} p50=#{us(s.latency.total.p50)} p95=#{us(s.latency.total.p95)} p99=#{us(s.latency.total.p99)} max=#{us(s.latency.total.max)}
    latency knn      min=#{us(s.latency.knn.min)} p50=#{us(s.latency.knn.p50)} p95=#{us(s.latency.knn.p95)} p99=#{us(s.latency.knn.p99)} max=#{us(s.latency.knn.max)}
    latency tform    min=#{us(s.latency.transform.min)} p50=#{us(s.latency.transform.p50)} p95=#{us(s.latency.transform.p95)} p99=#{us(s.latency.transform.p99)} max=#{us(s.latency.transform.max)}

    fraud-neighbor distribution:
    #{format_buckets(s.buckets)}
    """)
  end

  defp percent(f), do: :io_lib.format("~6.2f%%", [f * 100]) |> IO.iodata_to_binary()
  defp us(n), do: "#{n}us"

  defp format_us(us) when us < 1_000, do: "#{us}us"
  defp format_us(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 2)}ms"
  defp format_us(us), do: "#{Float.round(us / 1_000_000, 2)}s"

  defp format_buckets(buckets) do
    0..5
    |> Enum.map(fn n ->
      c = Map.get(buckets, n, 0)
      "  n=#{n}: #{c}"
    end)
    |> Enum.join("\n")
  end

  defp throughput(_, 0), do: 0.0
  defp throughput(count, elapsed_us), do: Float.round(count * 1_000_000 / elapsed_us, 2)
end

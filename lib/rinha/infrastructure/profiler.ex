defmodule Rinha.Profiler do
  @moduledoc """
  Lock-free latency histograms backed by `:counters`.

  One histogram per telemetry event (metric name).  Each histogram has
  fixed log-scale buckets covering 1 µs .. ~16 s, plus a total counter
  and a sum counter (for mean).

  Buckets: powers-of-2 in microseconds:
    1, 2, 4, 8, 16, 32, 64, 128, 256, 512,
    1024, 2048, 4096, 8192, 16_384, 32_768,
    65_536, 131_072, 262_144, 524_288,
    1_048_576, 2_097_152, 4_194_304, 8_388_608, 16_777_216

  Events recorded by default (subscribed in `start_link/1`):

    * `[:rinha, :ivf, :centroid_scan]` -> `:ivf_centroid`
    * `[:rinha, :ivf, :bucket_scan]`   -> `:ivf_bucket`
    * `[:rinha, :ivf, :total]`         -> `:ivf_total`

  All values are read by `summary/0` which returns p50/p95/p99/max/mean
  per metric.  Reads are O(buckets) so they are cheap.

  Histograms are global (one per BEAM node).  Reset via `reset/0`.
  """

  use GenServer
  require Logger

  @default_log_interval_ms 10_000

  @buckets_us [
    1,
    2,
    4,
    8,
    16,
    32,
    64,
    128,
    256,
    512,
    1024,
    2048,
    4096,
    8192,
    16_384,
    32_768,
    65_536,
    131_072,
    262_144,
    524_288,
    1_048_576,
    2_097_152,
    4_194_304,
    8_388_608,
    16_777_216
  ]

  @bucket_count length(@buckets_us)
  # Layout per metric counter array:
  #   index 1..@bucket_count : bucket counts
  #   index @bucket_count + 1 : total samples
  #   index @bucket_count + 2 : sum of values (us)
  #   index @bucket_count + 3 : max value
  @total_idx @bucket_count + 1
  @sum_idx @bucket_count + 2
  @max_idx @bucket_count + 3
  @array_size @bucket_count + 3

  @metrics %{
    [:rinha, :ivf, :centroid_scan] => :ivf_centroid,
    [:rinha, :ivf, :bucket_scan] => :ivf_bucket,
    [:rinha, :ivf, :total] => :ivf_total
  }

  @metric_order [:ivf_centroid, :ivf_bucket, :ivf_total]

  @persistent_key {:rinha, :profiler_counters}

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns map of metric_name => stats."
  def summary do
    counters = :persistent_term.get(@persistent_key)

    Map.new(counters, fn {name, ref} ->
      {name, snapshot(ref)}
    end)
  end

  @doc "Reset all counters to zero."
  def reset do
    :persistent_term.get(@persistent_key)
    |> Enum.each(fn {_name, ref} ->
      for i <- 1..@array_size, do: :counters.put(ref, i, 0)
    end)

    :ok
  end

  @doc "Manually record a value (microseconds) under a metric name."
  def record(metric_name, us) when is_integer(us) and us >= 0 do
    case :persistent_term.get(@persistent_key) |> Map.get(metric_name) do
      nil -> :ok
      ref -> do_record(ref, us)
    end
  end

  ## GenServer

  @impl true
  def init(opts) do
    counters =
      Map.new(@metrics, fn {_event, name} ->
        ref = :counters.new(@array_size, [:write_concurrency])
        {name, ref}
      end)

    :persistent_term.put(@persistent_key, counters)

    Enum.each(@metrics, fn {event, name} ->
      :telemetry.attach(
        {__MODULE__, name},
        event,
        &__MODULE__.handle_event/4,
        nil
      )
    end)

    log_interval_ms = configured_log_interval_ms(opts)

    if log_interval_ms > 0 do
      Process.send_after(self(), :emit_periodic_summary, log_interval_ms)
      Logger.info("Profiler periodic logs enabled every #{format_interval(log_interval_ms)}")
    end

    {:ok,
     %{
       log_interval_ms: log_interval_ms,
       previous_raw: raw_metrics_snapshot(counters)
     }}
  end

  @impl true
  def terminate(_reason, _state) do
    Enum.each(@metrics, fn {_event, name} ->
      :telemetry.detach({__MODULE__, name})
    end)
  end

  @impl true
  def handle_info(:emit_periodic_summary, %{log_interval_ms: interval_ms} = state)
      when interval_ms > 0 do
    current_raw = raw_metrics_snapshot(:persistent_term.get(@persistent_key))
    window = diff_raw_metrics(current_raw, state.previous_raw)
    log_window(window, interval_ms)

    Process.send_after(self(), :emit_periodic_summary, interval_ms)
    {:noreply, %{state | previous_raw: current_raw}}
  end

  def handle_info(_, state), do: {:noreply, state}

  ## Telemetry handler

  @doc false
  def handle_event(event, %{us: us}, _meta, _config) do
    case Map.get(@metrics, event) do
      nil -> :ok
      name -> record(name, us)
    end
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  ## Internals

  defp do_record(ref, us) do
    bucket = bucket_index(us)
    :counters.add(ref, bucket, 1)
    :counters.add(ref, @total_idx, 1)
    :counters.add(ref, @sum_idx, us)

    current_max = :counters.get(ref, @max_idx)
    if us > current_max, do: :counters.put(ref, @max_idx, us)

    :ok
  end

  # Find smallest bucket whose upper bound is >= us.
  defp bucket_index(us) do
    bucket_index(us, @buckets_us, 1)
  end

  defp bucket_index(_us, [], _i), do: @bucket_count
  defp bucket_index(us, [b | _rest], i) when us <= b, do: i
  defp bucket_index(us, [_b | rest], i), do: bucket_index(us, rest, i + 1)

  defp snapshot(ref) do
    counts =
      for i <- 1..@bucket_count do
        :counters.get(ref, i)
      end

    total = :counters.get(ref, @total_idx)
    sum = :counters.get(ref, @sum_idx)
    max = :counters.get(ref, @max_idx)

    mean = if total > 0, do: div(sum, total), else: 0

    %{
      count: total,
      mean_us: mean,
      max_us: max,
      p50_us: percentile(counts, total, 0.50),
      p95_us: percentile(counts, total, 0.95),
      p99_us: percentile(counts, total, 0.99)
    }
  end

  defp percentile(_counts, 0, _pct), do: 0

  defp percentile(counts, total, pct) do
    target = max(1, trunc(total * pct))

    counts
    |> Enum.zip(@buckets_us)
    |> Enum.reduce_while(0, fn {c, bucket_us}, acc ->
      acc2 = acc + c
      if acc2 >= target, do: {:halt, bucket_us}, else: {:cont, acc2}
    end)
    |> case do
      0 -> 0
      v -> v
    end
  end

  defp configured_log_interval_ms(opts) do
    opts
    |> Keyword.get(
      :log_interval_ms,
      Application.get_env(:rinha, :telemetry_log_interval_ms, @default_log_interval_ms)
    )
    |> case do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 0
    end
  end

  defp raw_metrics_snapshot(counters) do
    Map.new(counters, fn {name, ref} ->
      {name,
       %{
         counts: for(i <- 1..@bucket_count, do: :counters.get(ref, i)),
         total: :counters.get(ref, @total_idx),
         sum: :counters.get(ref, @sum_idx)
       }}
    end)
  end

  defp diff_raw_metrics(current, previous) do
    Map.new(current, fn {name, cur} ->
      prev =
        Map.get(previous, name, %{counts: List.duplicate(0, @bucket_count), total: 0, sum: 0})

      {name,
       %{
         counts: Enum.zip_with(cur.counts, prev.counts, &max(&1 - &2, 0)),
         total: max(cur.total - prev.total, 0),
         sum: max(cur.sum - prev.sum, 0)
       }}
    end)
  end

  defp log_window(window, interval_ms) do
    metrics =
      @metric_order
      |> Enum.map(fn name ->
        raw = Map.fetch!(window, name)
        {name, interval_stats(raw)}
      end)
      |> Enum.filter(fn {_name, stats} -> stats.count > 0 end)

    if metrics == [] do
      Logger.info("[telemetry] last #{format_interval(interval_ms)} no samples")
    else
      message =
        metrics
        |> Enum.map(fn {name, stats} ->
          "#{name} n=#{stats.count} mean=#{stats.mean_us}us p95=#{stats.p95_us}us p99=#{stats.p99_us}us max~#{stats.max_us}us"
        end)
        |> Enum.join(" | ")

      Logger.info("[telemetry] last #{format_interval(interval_ms)} #{message}")
    end
  end

  defp interval_stats(%{counts: counts, total: total, sum: sum}) do
    %{
      count: total,
      mean_us: if(total > 0, do: div(sum, total), else: 0),
      p95_us: percentile(counts, total, 0.95),
      p99_us: percentile(counts, total, 0.99),
      max_us: max_bucket_us(counts)
    }
  end

  defp max_bucket_us(counts) do
    counts
    |> Enum.zip(@buckets_us)
    |> Enum.reduce(0, fn {count, bucket_us}, acc ->
      if count > 0, do: bucket_us, else: acc
    end)
  end

  defp format_interval(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s"
  defp format_interval(ms), do: "#{ms}ms"
end

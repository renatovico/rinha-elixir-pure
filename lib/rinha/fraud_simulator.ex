defmodule Rinha.FraudSimulator do
  @moduledoc """
  Generates synthetic fraud-score payloads and replays them through the
  pipeline.

  The simulator is intended for debugging, profiling, and load testing
  outside of HTTP. It is **not** used in production paths.

  ## Distribution

  Each call to `generate/1` flips a biased coin (default 1/3) to decide
  whether to emit a "fraud-shaped" or "legit-shaped" payload. The shapes
  exaggerate the features that drive the KNN's lane values:

    * fraud  — high amount, many installments, off-hours, far from home,
               new merchant, large customer/merchant amount delta, etc.
    * legit  — small amount, few installments, business hours, near home,
               known merchant, balanced amounts.

  The schema matches `priv/resources/fixtures/*.json` exactly (camelCase nested,
  ISO-8601 `requested_at`, optional `last_transaction`).
  """

  @merchant_ids for n <- 1..50, do: "MERC-" <> String.pad_leading(Integer.to_string(n), 3, "0")
  @mccs ~w(5411 5812 5541 5912 5311 5732 4111 7011 5942 5651 7995 6010)
  @fraud_mccs ~w(7995 6010 4829 5933)

  @doc """
  Generate a single payload.

  Options:

    * `:fraud_bias` — float in 0..1, probability of generating a fraud-shaped
      payload (default `0.33`).
    * `:seed` — `:rand` seed tuple to make generation deterministic.
  """
  @spec generate(keyword()) :: {:fraud | :legit, map()}
  def generate(opts \\ []) do
    if seed = opts[:seed], do: :rand.seed(:exsss, seed)
    bias = Keyword.get(opts, :fraud_bias, 0.33)

    if :rand.uniform() < bias do
      {:fraud, fraud_payload()}
    else
      {:legit, legit_payload()}
    end
  end

  @doc """
  Generate `count` payloads as a stream of `{label, payload}` tuples.
  """
  @spec stream(non_neg_integer(), keyword()) :: Enumerable.t()
  def stream(count, opts \\ []) do
    if seed = opts[:seed], do: :rand.seed(:exsss, seed)
    opts = Keyword.delete(opts, :seed)
    Stream.repeatedly(fn -> generate(opts) end) |> Stream.take(count)
  end

  @doc """
  Run `count` payloads through the full scoring pipeline and return summary
  stats. Use `:warmup` to discard the first N samples.
  """
  @spec run(non_neg_integer(), keyword()) :: map()
  def run(count, opts \\ []) do
    warmup = Keyword.get(opts, :warmup, min(50, div(count, 10)))

    _ = if warmup > 0, do: do_run(warmup, opts), else: %{latencies: []}

    do_run(count, opts)
  end

  defp do_run(count, opts) do
    samples =
      for {label, payload} <- stream(count, opts) do
        t0 = System.monotonic_time(:microsecond)
        vector = Rinha.VectorTransformerV2.transform(payload)
        t1 = System.monotonic_time(:microsecond)
        n = Rinha.KnnServer.score(vector)
        t2 = System.monotonic_time(:microsecond)
        approved = n < 3
        truthy_correct = (label == :fraud and not approved) or (label == :legit and approved)

        %{
          label: label,
          n: n,
          approved: approved,
          correct?: truthy_correct,
          transform_us: t1 - t0,
          knn_us: t2 - t1,
          total_us: t2 - t0
        }
      end

    summarize(samples)
  end

  defp summarize(samples) do
    n = length(samples)
    correct = Enum.count(samples, & &1.correct?)
    fraud_total = Enum.count(samples, &(&1.label == :fraud))
    legit_total = n - fraud_total
    fraud_caught = Enum.count(samples, &(&1.label == :fraud and not &1.approved))
    legit_passed = Enum.count(samples, &(&1.label == :legit and &1.approved))

    totals = samples |> Enum.map(& &1.total_us) |> Enum.sort()
    transforms = samples |> Enum.map(& &1.transform_us) |> Enum.sort()
    knns = samples |> Enum.map(& &1.knn_us) |> Enum.sort()

    %{
      count: n,
      accuracy: safe_div(correct, n),
      recall_fraud: safe_div(fraud_caught, fraud_total),
      precision_legit: safe_div(legit_passed, legit_total),
      latency: %{
        total: percentiles(totals),
        transform: percentiles(transforms),
        knn: percentiles(knns)
      },
      buckets: Enum.frequencies_by(samples, & &1.n)
    }
  end

  defp safe_div(_, 0), do: 0.0
  defp safe_div(a, b), do: a / b

  defp percentiles([]), do: %{min: 0, p50: 0, p95: 0, p99: 0, max: 0}

  defp percentiles(sorted) do
    n = length(sorted)

    %{
      min: List.first(sorted),
      p50: Enum.at(sorted, div(n, 2)),
      p95: Enum.at(sorted, min(n - 1, trunc(n * 0.95))),
      p99: Enum.at(sorted, min(n - 1, trunc(n * 0.99))),
      max: List.last(sorted)
    }
  end

  # ---- payload builders ----

  defp legit_payload do
    merchant_id = Enum.random(@merchant_ids)
    known = Enum.uniq([merchant_id | Enum.take_random(@merchant_ids -- [merchant_id], 1 + :rand.uniform(3))])
    avg = uniform(20.0, 150.0)

    %{
      "id" => "tx-" <> Integer.to_string(:rand.uniform(10_000_000)),
      "transaction" => %{
        "amount" => uniform(10.0, avg * 1.5) |> Float.round(2),
        "installments" => Enum.random([1, 1, 1, 2, 3]),
        "requested_at" => business_hour_iso()
      },
      "customer" => %{
        "avg_amount" => avg |> Float.round(2),
        "tx_count_24h" => :rand.uniform(6),
        "known_merchants" => known
      },
      "merchant" => %{
        "id" => merchant_id,
        "mcc" => Enum.random(@mccs),
        "avg_amount" => uniform(20.0, 200.0) |> Float.round(2)
      },
      "terminal" => %{
        "is_online" => Enum.random([true, false]),
        "card_present" => Enum.random([true, true, true, false]),
        "km_from_home" => uniform(0.0, 50.0) |> Float.round(2)
      },
      "last_transaction" => maybe_recent_legit_tx()
    }
  end

  defp fraud_payload do
    merchant_id = "MERC-" <> String.pad_leading(Integer.to_string(900 + :rand.uniform(99)), 3, "0")
    avg = uniform(50.0, 300.0)

    %{
      "id" => "tx-" <> Integer.to_string(:rand.uniform(10_000_000)),
      "transaction" => %{
        "amount" => uniform(avg * 5, avg * 50) |> Float.round(2),
        "installments" => Enum.random([6, 8, 10, 12, 12]),
        "requested_at" => off_hour_iso()
      },
      "customer" => %{
        "avg_amount" => avg |> Float.round(2),
        "tx_count_24h" => 8 + :rand.uniform(20),
        "known_merchants" => Enum.take_random(@merchant_ids, :rand.uniform(2))
      },
      "merchant" => %{
        "id" => merchant_id,
        "mcc" => Enum.random(@fraud_mccs),
        "avg_amount" => uniform(avg * 3, avg * 30) |> Float.round(2)
      },
      "terminal" => %{
        "is_online" => Enum.random([true, true, false]),
        "card_present" => Enum.random([false, false, true]),
        "km_from_home" => uniform(150.0, 1500.0) |> Float.round(2)
      },
      "last_transaction" => recent_far_tx()
    }
  end

  defp uniform(lo, hi), do: lo + :rand.uniform() * (hi - lo)

  defp business_hour_iso do
    days_back = :rand.uniform(60)
    hour = 8 + :rand.uniform(11)
    minute = :rand.uniform(59)

    DateTime.utc_now()
    |> DateTime.add(-days_back, :day)
    |> DateTime.to_date()
    |> DateTime.new!(Time.new!(hour, minute, 0))
    |> DateTime.to_iso8601()
    |> String.replace(~r/\.\d+Z$/, "Z")
    |> String.replace(~r/\+00:00$/, "Z")
  end

  defp off_hour_iso do
    days_back = :rand.uniform(60)
    hour = Enum.random([0, 1, 2, 3, 4, 23])
    minute = :rand.uniform(59)

    DateTime.utc_now()
    |> DateTime.add(-days_back, :day)
    |> DateTime.to_date()
    |> DateTime.new!(Time.new!(hour, minute, 0))
    |> DateTime.to_iso8601()
    |> String.replace(~r/\.\d+Z$/, "Z")
    |> String.replace(~r/\+00:00$/, "Z")
  end

  defp maybe_recent_legit_tx do
    if :rand.uniform() < 0.5 do
      nil
    else
      hours_back = :rand.uniform(48)

      ts =
        DateTime.utc_now()
        |> DateTime.add(-hours_back * 3600, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()
        |> String.replace(~r/\+00:00$/, "Z")

      %{"timestamp" => ts, "km_from_current" => uniform(0.1, 30.0) |> Float.round(2)}
    end
  end

  defp recent_far_tx do
    minutes_back = :rand.uniform(20)

    ts =
      DateTime.utc_now()
      |> DateTime.add(-minutes_back * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace(~r/\+00:00$/, "Z")

    %{"timestamp" => ts, "km_from_current" => uniform(100.0, 800.0) |> Float.round(2)}
  end
end

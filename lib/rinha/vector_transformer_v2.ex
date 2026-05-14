defmodule Rinha.VectorTransformerV2 do
  @moduledoc """
  14-dimensional, int16-quantized fraud feature vectorizer.

  Vectorizes a transaction request into a 16-int (`s16`) feature vector
  consumed by `Rinha.KnnScanner`.

  Output layout (16 lanes, stride matches the reference binary):

       0  amount / max_amount
       1  installments / max_installments
       2  (amount / customer.avg_amount) / amount_vs_avg_ratio
       3  hour_of_day  (HourLut)
       4  day_of_week  (DowLut, Monday=0)
       5  minutes_since_last_tx / max_minutes   (-Scale if no last_transaction)
       6  km_from_current / max_km              (-Scale if no last_transaction)
       7  km_from_home / max_km
       8  customer.tx_count_24h / max_tx_count_24h
       9  terminal.is_online      (Scale or 0)
      10  terminal.card_present   (Scale or 0)
      11  unknown_merchant        (Scale if merchant not in known list, else 0)
      12  mcc_risk[merchant.mcc]  (default 0.5)
      13  merchant.avg_amount / max_merchant_avg_amount
   14,15  zero pads (kept for SIMD-friendly stride 16)

  Constants `@scale = 8192` and `@stride = 16`.

  Returns a flat list of 16 ints (clamped to int16 range), suitable for
  feeding into `Nx.tensor(_, type: :s16)` or any KNN that expects the
  reference binary layout.
  """

  @scale 8192
  @stride 16

  # LUTs precomputed at compile time (HourLut, DowLut)
  @hour_lut for h <- 0..23, into: %{}, do: {h, round(h / 23.0 * @scale)}
  @dow_lut for d <- 0..6, into: %{}, do: {d, round(d / 6.0 * @scale)}

  @doc "Length of the output list (always 16)."
  def stride, do: @stride

  @doc "Quantization scale (8192)."
  def scale, do: @scale

  @doc "Transform a fraud-score request payload into a flat list of 16 ints."
  def transform(payload) do
    norm = Rinha.Resources.normalization()
    mcc_risk = Rinha.Resources.mcc_risk()

    transaction = payload["transaction"] || %{}
    customer = payload["customer"] || %{}
    merchant = payload["merchant"] || %{}
    terminal = payload["terminal"] || %{}
    last_tx = payload["last_transaction"]

    amount = (transaction["amount"] || 0.0) * 1.0
    installments = (transaction["installments"] || 0) * 1.0
    requested_at = transaction["requested_at"]

    avg_amount = (customer["avg_amount"] || 1.0) * 1.0
    tx_count_24h = (customer["tx_count_24h"] || 0) * 1.0
    known_merchants = customer["known_merchants"] || []

    merchant_id = merchant["id"]
    mcc = merchant["mcc"]
    merchant_avg = (merchant["avg_amount"] || 0.0) * 1.0

    is_online = terminal["is_online"] == true
    card_present = terminal["card_present"] == true
    km_from_home = (terminal["km_from_home"] || 0.0) * 1.0

    {hour, dow} = parse_iso_utc(requested_at)

    {dim5, dim6} = last_transaction_lanes(last_tx, requested_at, norm)

    [
      q(clamp01(amount / norm.max_amount)),
      q(clamp01(installments / norm.max_installments)),
      q(clamp01(amount / avg_amount / norm.amount_vs_avg_ratio)),
      Map.get(@hour_lut, hour, 0),
      Map.get(@dow_lut, dow, 0),
      dim5,
      dim6,
      q(clamp01(km_from_home / norm.max_km)),
      q(clamp01(tx_count_24h / norm.max_tx_count_24h)),
      if(is_online, do: @scale, else: 0),
      if(card_present, do: @scale, else: 0),
      if(merchant_id in known_merchants, do: 0, else: @scale),
      q(Map.get(mcc_risk, mcc, 0.5)),
      q(clamp01(merchant_avg / norm.max_merchant_avg_amount)),
      0,
      0
    ]
  end

  # ---- helpers ---------------------------------------------------------

  defp last_transaction_lanes(nil, _requested_at, _norm), do: {-@scale, -@scale}

  defp last_transaction_lanes(last_tx, requested_at, norm) do
    last_ts = last_tx["timestamp"]
    km = (last_tx["km_from_current"] || 0.0) * 1.0

    minutes =
      case {parse_iso_seconds(requested_at), parse_iso_seconds(last_ts)} do
        {{:ok, a}, {:ok, b}} -> (a - b) / 60.0
        _ -> 0.0
      end

    {q(clamp01(minutes / norm.max_minutes)), q(clamp01(km / norm.max_km))}
  end

  @compile {:inline, q: 1, clamp01: 1}

  defp clamp01(x) when x < 0.0, do: 0.0
  defp clamp01(x) when x > 1.0, do: 1.0
  defp clamp01(x), do: x * 1.0

  defp q(v) do
    qv = round(v * @scale)
    cond do
      qv > 32_767 -> 32_767
      qv < -32_768 -> -32_768
      true -> qv
    end
  end

  # Returns {hour, dow_zero_based_monday}; 0/0 on parse failure.
  defp parse_iso_utc(<<
         y1, y2, y3, y4, ?-,
         mo1, mo2, ?-,
         d1, d2, ?T,
         h1, h2, ?:,
         _mi1, _mi2, ?:,
         _s1, _s2, ?Z
       >>)
       when y1 in ?0..?9 and y2 in ?0..?9 and y3 in ?0..?9 and y4 in ?0..?9 and
              mo1 in ?0..?9 and mo2 in ?0..?9 and d1 in ?0..?9 and d2 in ?0..?9 and
              h1 in ?0..?9 and h2 in ?0..?9 do
    year = (y1 - ?0) * 1000 + (y2 - ?0) * 100 + (y3 - ?0) * 10 + (y4 - ?0)
    month = (mo1 - ?0) * 10 + (mo2 - ?0)
    day = (d1 - ?0) * 10 + (d2 - ?0)
    hour = (h1 - ?0) * 10 + (h2 - ?0)
    {hour, :calendar.day_of_the_week(year, month, day) - 1}
  end

  defp parse_iso_utc(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {dt.hour, :calendar.day_of_the_week(dt.year, dt.month, dt.day) - 1}
      _ -> {0, 0}
    end
  end

  defp parse_iso_utc(_), do: {0, 0}

  # Returns {:ok, total_seconds_from_year_0} or :error.
  defp parse_iso_seconds(<<
         y1, y2, y3, y4, ?-,
         mo1, mo2, ?-,
         d1, d2, ?T,
         h1, h2, ?:,
         mi1, mi2, ?:,
         s1, s2, ?Z
       >>)
       when y1 in ?0..?9 and y2 in ?0..?9 and y3 in ?0..?9 and y4 in ?0..?9 and
              mo1 in ?0..?9 and mo2 in ?0..?9 and d1 in ?0..?9 and d2 in ?0..?9 and
              h1 in ?0..?9 and h2 in ?0..?9 and mi1 in ?0..?9 and mi2 in ?0..?9 and
              s1 in ?0..?9 and s2 in ?0..?9 do
    year = (y1 - ?0) * 1000 + (y2 - ?0) * 100 + (y3 - ?0) * 10 + (y4 - ?0)
    month = (mo1 - ?0) * 10 + (mo2 - ?0)
    day = (d1 - ?0) * 10 + (d2 - ?0)
    hour = (h1 - ?0) * 10 + (h2 - ?0)
    minute = (mi1 - ?0) * 10 + (mi2 - ?0)
    sec = (s1 - ?0) * 10 + (s2 - ?0)
    {:ok, :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, sec}})}
  end

  defp parse_iso_seconds(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {:ok, DateTime.to_unix(dt)}
      _ -> :error
    end
  end

  defp parse_iso_seconds(_), do: :error
end

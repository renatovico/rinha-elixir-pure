defmodule Rinha.IvfScanner do
  @moduledoc """
  IVF KNN scan over the indexed reference set.

  For a given query vector, chooses top centroids then brute-scans those
  buckets and returns the number of fraud labels among the top-5 neighbors.
  """

  @probes_max 3
  @k_neighbors 5
  @big_dist 2_147_000_000
  @max_probes 64

  @doc "Score a 16-int query with default probe budget."
  @spec score([integer()]) :: 0..5
  def score(query) when is_list(query) do
    score(query, @probes_max)
  end

  @doc "Score with an explicit probe budget."
  @spec score([integer()], pos_integer()) :: 0..5
  def score(query, probes) when is_list(query) and is_integer(probes) and probes > 0 do
    probes = min(probes, @max_probes)
    query16 = List.to_tuple(query) |> ensure_16!()
    centroids = Rinha.Domain.Index.centroids()

    t0 = System.monotonic_time(:microsecond)

    centroid_topk = top_centroids(centroids, query16, probes)
    t1 = System.monotonic_time(:microsecond)

    {topk, refs_scanned} = scan_buckets(centroid_topk, query16, init_topk(), 0)

    t2 = System.monotonic_time(:microsecond)

    n = Rinha.KnnScanner.fraud_count(topk)

    emit_telemetry(t0, t1, t2, n, probes, refs_scanned)
    n
  end

  defp scan_buckets(centroid_topk, query16, init_acc, init_count) do
    Enum.reduce(centroid_topk, {init_acc, init_count}, fn
      {_dist, cid}, {acc, count} when cid >= 0 ->
        {v_slice, l_slice, len} = Rinha.Domain.Index.bucket_slice(cid)

        if len > 0 do
          updated = Rinha.KnnScanner.scan_slice_prepared(v_slice, l_slice, query16, acc)
          {updated, count + len}
        else
          {acc, count}
        end

      {_dist, _cid}, {acc, count} ->
        {acc, count}
    end)
  end

  defp emit_telemetry(t0, t1, t2, n, probes, refs) do
    :telemetry.execute([:rinha, :ivf, :centroid_scan], %{us: t1 - t0}, %{})

    :telemetry.execute(
      [:rinha, :ivf, :bucket_scan],
      %{us: t2 - t1, refs: refs},
      %{probes: probes}
    )

    :telemetry.execute(
      [:rinha, :ivf, :total],
      %{us: t2 - t0, n: n, probes: probes},
      %{refs: refs}
    )
  end

  defp init_topk do
    List.duplicate({@big_dist, 0}, @k_neighbors)
  end

  defp top_centroids(
         centroids,
         {q0, q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12, q13, q14, q15},
         p
       ) do
    init = topk_seed(p)

    centroid_loop(
      centroids,
      0,
      init,
      @big_dist,
      q0,
      q1,
      q2,
      q3,
      q4,
      q5,
      q6,
      q7,
      q8,
      q9,
      q10,
      q11,
      q12,
      q13,
      q14,
      q15
    )
  end

  defp ensure_16!({_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _} = t), do: t

  defp ensure_16!(other),
    do: raise("IvfScanner expects a 16-int query, got #{inspect(other)}")

  defp topk_seed(1), do: [{@big_dist, -1}]
  defp topk_seed(2), do: [{@big_dist, -1}, {@big_dist, -1}]
  defp topk_seed(3), do: [{@big_dist, -1}, {@big_dist, -1}, {@big_dist, -1}]
  defp topk_seed(4), do: [{@big_dist, -1}, {@big_dist, -1}, {@big_dist, -1}, {@big_dist, -1}]

  defp topk_seed(5),
    do: [{@big_dist, -1}, {@big_dist, -1}, {@big_dist, -1}, {@big_dist, -1}, {@big_dist, -1}]

  defp topk_seed(6),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(7),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(8),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(9),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(10),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(11),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(12),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(13),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(14),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(15),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(16),
    do: [
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1},
      {@big_dist, -1}
    ]

  defp topk_seed(p), do: List.duplicate({@big_dist, -1}, p)

  defp centroid_loop(<<>>, _i, topk, _wd, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _),
    do: topk

  defp centroid_loop(
         <<r0::little-signed-16, r1::little-signed-16, r2::little-signed-16, r3::little-signed-16,
           r4::little-signed-16, r5::little-signed-16, r6::little-signed-16, r7::little-signed-16,
           r8::little-signed-16, r9::little-signed-16, r10::little-signed-16,
           r11::little-signed-16, r12::little-signed-16, r13::little-signed-16,
           r14::little-signed-16, r15::little-signed-16, rest::binary>>,
         i,
         topk,
         worst_dist,
         q0,
         q1,
         q2,
         q3,
         q4,
         q5,
         q6,
         q7,
         q8,
         q9,
         q10,
         q11,
         q12,
         q13,
         q14,
         q15
       ) do
    d0 = q0 - r0
    d1 = q1 - r1
    d2 = q2 - r2
    d3 = q3 - r3
    d4 = q4 - r4
    d5 = q5 - r5
    d6 = q6 - r6
    d7 = q7 - r7
    d8 = q8 - r8
    d9 = q9 - r9
    d10 = q10 - r10
    d11 = q11 - r11
    d12 = q12 - r12
    d13 = q13 - r13
    d14 = q14 - r14
    d15 = q15 - r15

    dist =
      d0 * d0 + d1 * d1 + d2 * d2 + d3 * d3 +
        d4 * d4 + d5 * d5 + d6 * d6 + d7 * d7 +
        d8 * d8 + d9 * d9 + d10 * d10 + d11 * d11 +
        d12 * d12 + d13 * d13 + d14 * d14 + d15 * d15

    if dist < worst_dist do
      new_topk = insert_sorted(topk, {dist, i}, [])
      {new_worst, _} = :lists.last(new_topk)

      centroid_loop(
        rest,
        i + 1,
        new_topk,
        new_worst,
        q0,
        q1,
        q2,
        q3,
        q4,
        q5,
        q6,
        q7,
        q8,
        q9,
        q10,
        q11,
        q12,
        q13,
        q14,
        q15
      )
    else
      centroid_loop(
        rest,
        i + 1,
        topk,
        worst_dist,
        q0,
        q1,
        q2,
        q3,
        q4,
        q5,
        q6,
        q7,
        q8,
        q9,
        q10,
        q11,
        q12,
        q13,
        q14,
        q15
      )
    end
  end

  defp insert_sorted([], new, acc), do: :lists.reverse([new | acc])

  defp insert_sorted([{d, _} = head | tail], {nd, _} = new, acc) when nd < d do
    :lists.reverse(acc, [new | drop_last([head | tail])])
  end

  defp insert_sorted([head | tail], new, acc) do
    insert_sorted(tail, new, [head | acc])
  end

  defp drop_last([_]), do: []
  defp drop_last([h | t]), do: [h | drop_last(t)]
end

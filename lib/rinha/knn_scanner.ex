defmodule Rinha.KnnScanner do
  @moduledoc """
  Pure-Elixir KNN scan over the refcounted reference binary.

  Computes the squared L2 distance between a 16-int query and every
  reference row, maintaining a running top-K (smallest distances).
  Returns a list of `{distance, label}` pairs of size K, unsorted.

  Hot loop is `scan_chunk/6` — a tail-recursive binary pattern match
  that consumes 32 bytes (16 × s16) per iteration alongside one byte
  from the labels stream.

  Distance is computed via 16 hand-unrolled subtract+square+add to
  avoid list traversal overhead.

  Top-K is maintained as a sorted list of length K (small, K=5).
  """

  @k 5
  @big_dist 2_147_000_000

  @doc """
  Scan the entire reference set with the given 16-int query.
  Returns a list of K `{distance, label}` pairs (unsorted).
  """
  @spec scan_all([integer()]) :: [{integer(), 0 | 1}]
  def scan_all(query) do
    {q0, q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12, q13, q14, q15} =
      List.to_tuple(query) |> ensure_16!()

    vectors = Rinha.KnnStore.vectors_binary()
    labels = Rinha.KnnStore.labels_binary()

    init_topk = List.duplicate({@big_dist, 0}, @k)

    scan_chunk(
      vectors,
      labels,
      init_topk,
      @big_dist,
      q0, q1, q2, q3, q4, q5, q6, q7,
      q8, q9, q10, q11, q12, q13, q14, q15
    )
  end

  @doc """
  Scan a slice of references (used for cluster sharding / parallel scans).

  `vectors_slice` and `labels_slice` must be aligned: a slice of
  `chunk_size` rows is `chunk_size * 32` bytes of vectors and
  `chunk_size` bytes of labels.
  """
  @spec scan_slice(binary, binary, [integer()]) :: [{integer(), 0 | 1}]
  def scan_slice(vectors_slice, labels_slice, query) do
    {q0, q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12, q13, q14, q15} =
      List.to_tuple(query) |> ensure_16!()

    init_topk = List.duplicate({@big_dist, 0}, @k)

    scan_chunk(
      vectors_slice,
      labels_slice,
      init_topk,
      @big_dist,
      q0, q1, q2, q3, q4, q5, q6, q7,
      q8, q9, q10, q11, q12, q13, q14, q15
    )
  end

  @doc "Merge several top-K lists, returning the global top-K."
  @spec merge_topk([[{integer(), 0 | 1}]]) :: [{integer(), 0 | 1}]
  def merge_topk(lists) do
    lists
    |> List.flatten()
    |> Enum.sort_by(fn {d, _} -> d end)
    |> Enum.take(@k)
  end

  @doc "Count fraud labels in a top-K list."
  @spec fraud_count([{integer(), 0 | 1}]) :: 0..5
  def fraud_count(topk) do
    Enum.reduce(topk, 0, fn {_, label}, acc -> acc + label end)
  end

  ## Internals

  defp ensure_16!({_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _} = t), do: t

  defp ensure_16!(other),
    do: raise("KnnScanner expects a 16-int query, got #{inspect(other)}")

  # End of binary: return current top-K.
  defp scan_chunk(<<>>, <<>>, topk, _wd, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _),
    do: topk

  defp scan_chunk(
         <<r0::little-signed-16, r1::little-signed-16, r2::little-signed-16,
           r3::little-signed-16, r4::little-signed-16, r5::little-signed-16,
           r6::little-signed-16, r7::little-signed-16, r8::little-signed-16,
           r9::little-signed-16, r10::little-signed-16, r11::little-signed-16,
           r12::little-signed-16, r13::little-signed-16, r14::little-signed-16,
           r15::little-signed-16, vrest::binary>>,
         <<label, lrest::binary>>,
         topk,
         worst_dist,
         q0, q1, q2, q3, q4, q5, q6, q7,
         q8, q9, q10, q11, q12, q13, q14, q15
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

    # Hot fast-path: if dist >= worst, skip insert entirely.
    if dist < worst_dist do
      new_topk = insert_sorted(topk, {dist, label}, [])
      {new_worst, _} = :lists.last(new_topk)

      scan_chunk(
        vrest, lrest, new_topk, new_worst,
        q0, q1, q2, q3, q4, q5, q6, q7,
        q8, q9, q10, q11, q12, q13, q14, q15
      )
    else
      scan_chunk(
        vrest, lrest, topk, worst_dist,
        q0, q1, q2, q3, q4, q5, q6, q7,
        q8, q9, q10, q11, q12, q13, q14, q15
      )
    end
  end

  defp insert_sorted([], new, acc), do: :lists.reverse([new | acc])

  defp insert_sorted([{d, _} = head | tail], {nd, _} = new, acc) when nd < d do
    # New element goes before head. Drop the last element (worst) by
    # only taking K-1 of the tail.
    :lists.reverse(acc, [new | drop_last([head | tail])])
  end

  defp insert_sorted([head | tail], new, acc) do
    insert_sorted(tail, new, [head | acc])
  end

  defp drop_last([_]), do: []
  defp drop_last([h | t]), do: [h | drop_last(t)]
end

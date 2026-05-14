#!/usr/bin/env elixir
# Build the IVF (Inverted File) index for pure-Elixir KNN.
#
# Reads:  priv/references_v2.bin   (3M × 16 :s16 + 3M :u8)
# Writes: priv/ivf_index.bin
#
# Layout of priv/ivf_index.bin:
#
#   <<K::little-32, N::little-32, stride::little-32>>     # 12 B header
#   <<centroids::binary-K*16*int16-le>>                   # K * 32 B
#   <<offsets::binary-(K+1)*int32-le>>                    # (K+1) * 4 B  (CSR)
#   <<vectors::binary-N*16*int16-le>>                     # N * 32 B  (regrouped)
#   <<labels::binary-N*int8>>                             # N B       (regrouped)
#
# K = 1024 centroids, ~3000 refs per bucket.
#
# Usage:
#   MIX_ENV=dev mix run priv/build_ivf_index.exs
#
# Tunables via env:
#   IVF_K=1024               - number of centroids
#   IVF_ITERS=15             - k-means iterations
#   IVF_BATCH=20000          - mini-batch size for centroid update

{:ok, _} = Application.ensure_all_started(:exla)
Application.put_env(:nx, :default_backend, EXLA.Backend)
Application.put_env(:nx, :default_defn_options, compiler: EXLA)

defmodule BuildIvf do
  import Nx.Defn

  @big 2_147_000_000

  def run do
    k = String.to_integer(System.get_env("IVF_K") || "1024")
    iters = String.to_integer(System.get_env("IVF_ITERS") || "15")
    batch = String.to_integer(System.get_env("IVF_BATCH") || "20000")

    in_path = Path.join(File.cwd!(), "priv/references_v2.bin")
    out_path = Path.join(File.cwd!(), "priv/ivf_index.bin")

    IO.puts("Loading references from #{in_path}...")
    {vectors, labels, n, stride} = load_refs!(in_path)
    IO.puts("Loaded n=#{n} stride=#{stride}")

    IO.puts("Initialising #{k} centroids by random sampling...")
    seed = :rand.uniform(1_000_000)
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    init_idx =
      0..(k - 1)
      |> Enum.map(fn _ -> :rand.uniform(n) - 1 end)
      |> Nx.tensor(type: :s32)

    centroids =
      vectors
      |> Nx.take(init_idx)
      |> Nx.as_type(:s32)

    IO.puts("Running k-means: #{iters} iterations, batch=#{batch}")

    centroids = run_kmeans(centroids, vectors, n, k, iters, batch)

    IO.puts("Assigning all #{n} refs to nearest centroid...")
    assignments = assign_all(centroids, vectors, n, k)

    IO.puts("Regrouping refs by bucket...")
    {sorted_idx, offsets} = regroup(assignments, k)

    IO.puts("Writing index to #{out_path}...")
    write_index!(out_path, k, n, stride, centroids, offsets, vectors, labels, sorted_idx)

    bucket_sizes = bucket_size_stats(offsets, k)
    IO.puts("Bucket sizes: min=#{bucket_sizes.min} max=#{bucket_sizes.max} mean=#{bucket_sizes.mean} empty=#{bucket_sizes.empty}")
    IO.puts("Done.")
  end

  defp load_refs!(path) do
    bin = File.read!(path)
    <<count::little-32, rest::binary>> = bin
    vec_bytes = count * 32
    <<vec_bin::binary-size(vec_bytes), label_bin::binary-size(count)>> = rest

    vectors =
      vec_bin
      |> Nx.from_binary(:s16)
      |> Nx.reshape({count, 16})

    labels = Nx.from_binary(label_bin, :u8)
    {vectors, labels, count, 16}
  end

  defp run_kmeans(centroids, vectors, n, k, iters, batch) do
    Enum.reduce(1..iters, centroids, fn iter, c ->
      # sample a random batch
      idx =
        0..(batch - 1)
        |> Enum.map(fn _ -> :rand.uniform(n) - 1 end)
        |> Nx.tensor(type: :s32)

      batch_vecs = Nx.take(vectors, idx) |> Nx.as_type(:s32)

      {new_centroids, inertia} = kmeans_step(batch_vecs, c, k: k)
      IO.puts("  iter #{iter}/#{iters}  inertia=#{Nx.to_number(inertia)}")
      new_centroids
    end)
  end

  defn kmeans_step(batch_vecs, centroids, opts \\ []) do
    opts = keyword!(opts, k: 1024)
    k = opts[:k]
    {b, _} = Nx.shape(batch_vecs)

    # distances: batch x k
    bn = Nx.sum(batch_vecs * batch_vecs, axes: [1]) |> Nx.new_axis(1)
    cn = Nx.sum(centroids * centroids, axes: [1]) |> Nx.new_axis(0)
    bc = Nx.dot(batch_vecs, [1], centroids, [1])
    dists = bn + cn - 2 * bc

    assignments = Nx.argmin(dists, axis: 1)

    # one-hot for sum/count
    onehot =
      Nx.iota({k})
      |> Nx.new_axis(0)
      |> Nx.equal(Nx.new_axis(assignments, 1))
      |> Nx.as_type(:s32)

    # sums: k x 16
    sums = Nx.dot(onehot, [0], batch_vecs, [0])
    counts = Nx.sum(onehot, axes: [0]) |> Nx.max(1) |> Nx.new_axis(1)
    new_centroids = Nx.divide(sums, counts) |> Nx.as_type(:s32)

    inertia = Nx.sum(Nx.reduce_min(dists, axes: [1]))
    {new_centroids, inertia}
  end

  defp assign_all(centroids, vectors, n, k) do
    chunk = 50_000
    chunks = ceil(n / chunk)

    0..(chunks - 1)
    |> Enum.map(fn ci ->
      start = ci * chunk
      len = min(chunk, n - start)

      slice =
        vectors
        |> Nx.slice([start, 0], [len, 16])
        |> Nx.as_type(:s32)

      assign_chunk(slice, centroids) |> Nx.to_flat_list()
    end)
    |> List.flatten()
  end

  defn assign_chunk(slice, centroids) do
    sn = Nx.sum(slice * slice, axes: [1]) |> Nx.new_axis(1)
    cn = Nx.sum(centroids * centroids, axes: [1]) |> Nx.new_axis(0)
    sc = Nx.dot(slice, [1], centroids, [1])
    dists = sn + cn - 2 * sc
    Nx.argmin(dists, axis: 1) |> Nx.as_type(:s32)
  end

  defp regroup(assignments, k) do
    # assignments :: list of integers (length n)
    # Sort indices by their centroid id; produce a CSR offsets array.
    indexed =
      assignments
      |> Enum.with_index()
      |> Enum.map(fn {c, i} -> {c, i} end)

    sorted = Enum.sort_by(indexed, fn {c, _} -> c end)
    sorted_idx = Enum.map(sorted, fn {_, i} -> i end)

    # Counts per bucket
    counts =
      Enum.reduce(sorted, %{}, fn {c, _}, acc ->
        Map.update(acc, c, 1, &(&1 + 1))
      end)

    # CSR offsets
    {offsets, _} =
      0..(k - 1)
      |> Enum.map_reduce(0, fn c, acc ->
        size = Map.get(counts, c, 0)
        {acc, acc + size}
      end)

    n = length(assignments)
    offsets = offsets ++ [n]
    {sorted_idx, offsets}
  end

  defp write_index!(path, k, n, stride, centroids, offsets, vectors, labels, sorted_idx) do
    sorted_idx_t = Nx.tensor(sorted_idx, type: :s32)

    # Regroup vectors and labels in sorted order
    regrouped_vecs = Nx.take(vectors, sorted_idx_t)
    regrouped_labels = Nx.take(labels, sorted_idx_t)

    centroids_s16 = Nx.as_type(centroids, :s16)

    header = <<k::little-32, n::little-32, stride::little-32>>
    centroids_bin = Nx.to_binary(centroids_s16)

    offsets_bin =
      offsets
      |> Enum.map(fn o -> <<o::little-32>> end)
      |> IO.iodata_to_binary()

    vecs_bin = Nx.to_binary(regrouped_vecs)
    labels_bin = Nx.to_binary(regrouped_labels)

    File.write!(path, [header, centroids_bin, offsets_bin, vecs_bin, labels_bin])
  end

  defp bucket_size_stats(offsets, k) do
    sizes =
      offsets
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)

    %{
      min: Enum.min(sizes),
      max: Enum.max(sizes),
      mean: div(Enum.sum(sizes), length(sizes)),
      empty: Enum.count(sizes, &(&1 == 0))
    }
  end
end

BuildIvf.run()

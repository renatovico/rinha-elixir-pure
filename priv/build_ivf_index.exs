#!/usr/bin/env elixir

# Build IVF index from `priv/references_v2.bin`.
#
# Input format (`priv/references_v2.bin`):
#   <<count::little-32>>
#   <<vectors::binary-size(count * 16 * 2)>>  # int16 little-endian
#   <<labels::binary-size(count)>>             # uint8
#
# Output format (`priv/ivf_index.bin`, v1):
#   <<k::little-32, n::little-32, stride::little-32>>
#   <<centroids::binary-size(k * stride * 2)>>
#   <<offsets::binary-size((k + 1) * 4)>>
#   <<vectors::binary-size(n * stride * 2)>>   # regrouped by centroid id
#   <<labels::binary-size(n)>>                  # regrouped by centroid id

{:ok, _} = Application.ensure_all_started(:exla)
Application.put_env(:nx, :default_backend, EXLA.Backend)
Application.put_env(:nx, :default_defn_options, compiler: EXLA)

defmodule BuildIvfIndex do
  import Nx.Defn

  def run(opts) do
    refs_path = Keyword.fetch!(opts, :input)
    out_path = Keyword.fetch!(opts, :output)
    k = Keyword.fetch!(opts, :k)
    iters = Keyword.fetch!(opts, :iters)
    batch = Keyword.fetch!(opts, :batch)

    IO.puts("Loading references from #{refs_path}...")
    {vectors, labels, n, stride} = load_refs!(refs_path)
    IO.puts("Loaded n=#{n} stride=#{stride}")

    if k > n do
      raise "IVF_K=#{k} cannot be greater than number of references n=#{n}"
    end

    IO.puts("Initializing #{k} centroids by random sampling...")
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

    IO.puts("Assigning all references to nearest centroid...")
    assignments = assign_all(centroids, vectors, n)

    IO.puts("Regrouping references by bucket...")
    {sorted_idx, offsets} = regroup(assignments, k)

    IO.puts("Writing IVF index to #{out_path}...")
    write_index!(out_path, k, n, stride, centroids, offsets, vectors, labels, sorted_idx)

    stats = bucket_size_stats(offsets)

    IO.puts(
      "Bucket sizes: min=#{stats.min} max=#{stats.max} mean=#{stats.mean} empty=#{stats.empty}"
    )

    :ok
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
    Enum.reduce(1..iters, centroids, fn iter, current_centroids ->
      idx =
        0..(batch - 1)
        |> Enum.map(fn _ -> :rand.uniform(n) - 1 end)
        |> Nx.tensor(type: :s32)

      batch_vecs = Nx.take(vectors, idx) |> Nx.as_type(:s32)
      {new_centroids, inertia} = kmeans_step(batch_vecs, current_centroids, k: k)

      IO.puts("  iter #{iter}/#{iters} inertia=#{Nx.to_number(inertia)}")
      new_centroids
    end)
  end

  defn kmeans_step(batch_vecs, centroids, opts \\ []) do
    opts = keyword!(opts, k: 1024)
    k = opts[:k]

    batch_norms = Nx.sum(batch_vecs * batch_vecs, axes: [1]) |> Nx.new_axis(1)
    centroid_norms = Nx.sum(centroids * centroids, axes: [1]) |> Nx.new_axis(0)
    cross = Nx.dot(batch_vecs, [1], centroids, [1])
    dists = batch_norms + centroid_norms - 2 * cross

    assignments = Nx.argmin(dists, axis: 1)

    onehot =
      Nx.iota({k})
      |> Nx.new_axis(0)
      |> Nx.equal(Nx.new_axis(assignments, 1))
      |> Nx.as_type(:s32)

    sums = Nx.dot(onehot, [0], batch_vecs, [0])
    counts = Nx.sum(onehot, axes: [0]) |> Nx.max(1) |> Nx.new_axis(1)
    new_centroids = Nx.divide(sums, counts) |> Nx.as_type(:s32)

    inertia = Nx.sum(Nx.reduce_min(dists, axes: [1]))
    {new_centroids, inertia}
  end

  defp assign_all(centroids, vectors, n) do
    chunk_size = 50_000
    chunks = ceil(n / chunk_size)

    0..(chunks - 1)
    |> Enum.flat_map(fn chunk_index ->
      start = chunk_index * chunk_size
      len = min(chunk_size, n - start)

      vectors
      |> Nx.slice([start, 0], [len, 16])
      |> Nx.as_type(:s32)
      |> assign_chunk(centroids)
      |> Nx.to_flat_list()
    end)
  end

  defn assign_chunk(slice, centroids) do
    slice_norms = Nx.sum(slice * slice, axes: [1]) |> Nx.new_axis(1)
    centroid_norms = Nx.sum(centroids * centroids, axes: [1]) |> Nx.new_axis(0)
    cross = Nx.dot(slice, [1], centroids, [1])
    dists = slice_norms + centroid_norms - 2 * cross

    Nx.argmin(dists, axis: 1)
    |> Nx.as_type(:s32)
  end

  defp regroup(assignments, k) do
    indexed = Enum.with_index(assignments)
    sorted = Enum.sort_by(indexed, fn {cid, _idx} -> cid end)

    sorted_idx = Enum.map(sorted, fn {_cid, idx} -> idx end)

    counts =
      Enum.reduce(sorted, %{}, fn {cid, _idx}, acc ->
        Map.update(acc, cid, 1, &(&1 + 1))
      end)

    {offsets, final_offset} =
      Enum.map_reduce(0..(k - 1), 0, fn cid, offset ->
        size = Map.get(counts, cid, 0)
        {offset, offset + size}
      end)

    {sorted_idx, offsets ++ [final_offset]}
  end

  defp write_index!(path, k, n, stride, centroids, offsets, vectors, labels, sorted_idx) do
    sorted_idx_t = Nx.tensor(sorted_idx, type: :s32)

    regrouped_vectors = Nx.take(vectors, sorted_idx_t)
    regrouped_labels = Nx.take(labels, sorted_idx_t)
    centroids_s16 = Nx.as_type(centroids, :s16)

    header = <<k::little-32, n::little-32, stride::little-32>>
    centroids_bin = Nx.to_binary(centroids_s16)

    offsets_bin =
      offsets
      |> Enum.map(fn offset -> <<offset::little-32>> end)
      |> IO.iodata_to_binary()

    vectors_bin = Nx.to_binary(regrouped_vectors)
    labels_bin = Nx.to_binary(regrouped_labels)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [header, centroids_bin, offsets_bin, vectors_bin, labels_bin])
  end

  defp bucket_size_stats(offsets) do
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

input = System.get_env("INPUT") || "priv/references_v2.bin"
output = System.get_env("OUTPUT") || "priv/ivf_index.bin"
k = String.to_integer(System.get_env("IVF_K") || "2048")
iters = String.to_integer(System.get_env("IVF_ITERS") || "15")
batch = String.to_integer(System.get_env("IVF_BATCH") || "20000")

:ok = BuildIvfIndex.run(input: input, output: output, k: k, iters: iters, batch: batch)

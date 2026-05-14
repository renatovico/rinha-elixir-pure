# Build references_v2.bin from resources/references.json.gz.
#
# K-means clustering uses Nx+EXLA for vectorized distance computation.
#
# Output format (Nx.serialize of a {vectors_tensor, labels_tensor} tuple):
#
#   vectors :: Nx.Tensor of shape {n, 16} type :s16
#             - dims 0..13 = quantized features (scale 8192)
#             - dims 14,15 = zero pads (kept for SIMD-friendly stride 16)
#   labels  :: Nx.Tensor of shape {n}      type :u8
#             - 1 = fraud, 0 = legit
#
# Usage:
#   mix run --no-start priv/build_references.exs                       # no clustering
#   mix run --no-start priv/build_references.exs -- 256                # k=256 centroids
#   mix run --no-start priv/build_references.exs -- 512 100            # k=512, 100 iters
#   K=256 ITERS=50 mix run --no-start priv/build_references.exs        # via env

defmodule BuildRefs do
  import Nx.Defn

  @scale 8192
  @stride 16
  @dims 14

  def run(opts) do
    in_path = Keyword.get(opts, :input, "resources/references.json.gz")
    out_path = Keyword.get(opts, :output, "priv/references_v2.bin")
    k = Keyword.get(opts, :k, 0)
    max_iters = Keyword.get(opts, :max_iters, 50)

    IO.puts("Loading references from #{in_path}...")
    refs = load_json_gz(in_path)
    IO.puts("Loaded #{length(refs)} references.")

    {fraud, legit} = Enum.split_with(refs, fn %{"label" => l} -> l == "fraud" end)
    fraud_vecs = Enum.map(fraud, & &1["vector"])
    legit_vecs = Enum.map(legit, & &1["vector"])
    IO.puts("Fraud: #{length(fraud_vecs)}  Legit: #{length(legit_vecs)}")

    {fraud_chosen, legit_chosen} =
      if k > 0 do
        ratio = length(fraud_vecs) / length(refs)
        fraud_k = max(1, round(k * ratio))
        legit_k = k - fraud_k
        IO.puts("Clustering: #{fraud_k} fraud + #{legit_k} legit centroids = #{k}")

        IO.puts("Clustering fraud vectors (n=#{length(fraud_vecs)}, k=#{fraud_k})...")
        fk = nx_kmeans(fraud_vecs, fraud_k, max_iters)
        IO.puts("Clustering legit vectors (n=#{length(legit_vecs)}, k=#{legit_k})...")
        lk = nx_kmeans(legit_vecs, legit_k, max_iters)
        {fk, lk}
      else
        IO.puts("No clustering — converting all references to binary.")
        {fraud_vecs, legit_vecs}
      end

    total = length(fraud_chosen) + length(legit_chosen)
    IO.puts("Quantizing #{total} vectors @ scale #{@scale} stride #{@stride}...")

    flat_int =
      (fraud_chosen ++ legit_chosen)
      |> Enum.flat_map(&quantize_padded/1)

    vectors = Nx.tensor(flat_int, type: :s16) |> Nx.reshape({total, @stride})

    labels =
      Nx.tensor(
        List.duplicate(1, length(fraud_chosen)) ++ List.duplicate(0, length(legit_chosen)),
        type: :u8
      )

    bin = Nx.serialize({vectors, labels})
    File.mkdir_p!(Path.dirname(out_path))
    File.write!(out_path, bin)
    %{size: size} = File.stat!(out_path)
    IO.puts("Wrote #{total} references to #{out_path} (#{size} bytes)")
  end

  defp load_json_gz(path) do
    {:ok, gz} = File.open(path, [:read, :compressed])
    binary = IO.binread(gz, :eof)
    File.close(gz)
    Jason.decode!(binary)
  end

  defp quantize_padded(vec) when is_list(vec) and length(vec) == @dims do
    quantized = Enum.map(vec, &quantize/1)
    quantized ++ [0, 0]
  end

  defp quantize(v) do
    q = round(v * @scale)
    cond do
      q > 32_767 -> 32_767
      q < -32_768 -> -32_768
      true -> q
    end
  end

  # ---- Nx-based k-means ----------------------------------------------

  defp nx_kmeans(vectors, k, max_iters) do
    n = length(vectors)

    # Build the {n, dims} f32 tensor once. Pin to EXLA host backend.
    points =
      vectors
      |> Enum.flat_map(& &1)
      |> Nx.tensor(type: :f32)
      |> Nx.reshape({n, @dims})
      |> Nx.backend_transfer({EXLA.Backend, client: :host})

    # Initial centroids: random k indices (deterministic via :rand seed)
    :rand.seed(:exsplus, {42, 0, 0})
    init_indices = 0..(n - 1) |> Enum.shuffle() |> Enum.take(k)
    init_centroids = Nx.take(points, Nx.tensor(init_indices, type: :s64))

    {centroids, assignments} =
      Enum.reduce_while(1..max_iters, {init_centroids, nil}, fn iter, {c, prev_a} ->
        new_a = EXLA.jit(&assign/2).(points, c)
        new_c = EXLA.jit(fn pts, asn -> recompute(pts, asn, k: k) end).(points, new_a)

        changed =
          case prev_a do
            nil -> n
            pa -> Nx.sum(Nx.not_equal(pa, new_a)) |> Nx.to_number()
          end

        IO.puts("  Iteration #{iter}: #{changed} reassignments")

        if changed == 0 do
          {:halt, {new_c, new_a}}
        else
          {:cont, {new_c, new_a}}
        end
      end)

    IO.puts("  Replacing centroids with medoids...")
    medoids_tensor =
      EXLA.jit(fn pts, asn, c -> medoids(pts, asn, c, k: k) end).(points, assignments, centroids)

    medoids_tensor
    |> Nx.to_list()
  end

  defn assign(points, centroids) do
    p_sq = Nx.sum(points * points, axes: [1], keep_axes: true)
    c_sq = Nx.sum(centroids * centroids, axes: [1])
    cross = Nx.dot(points, [1], centroids, [1])
    dists = p_sq - 2.0 * cross + c_sq
    Nx.argmin(dists, axis: 1)
  end

  defn recompute(points, assignments, opts \\ []) do
    opts = keyword!(opts, k: 1)
    k = opts[:k]
    one_hot = Nx.equal(Nx.new_axis(assignments, 1), Nx.iota({1, k}))
    one_hot_f = Nx.as_type(one_hot, :f32)
    sums = Nx.dot(one_hot_f, [0], points, [0])
    counts = Nx.sum(one_hot_f, axes: [0]) |> Nx.max(1.0)
    sums / Nx.new_axis(counts, 1)
  end

  defn medoids(points, assignments, centroids, opts \\ []) do
    opts = keyword!(opts, k: 1)
    k = opts[:k]
    n = Nx.axis_size(points, 0)

    p_sq = Nx.sum(points * points, axes: [1], keep_axes: true)
    c_sq = Nx.sum(centroids * centroids, axes: [1])
    cross = Nx.dot(points, [1], centroids, [1])
    all_dists = p_sq - 2.0 * cross + c_sq

    one_hot = Nx.equal(Nx.new_axis(assignments, 1), Nx.iota({1, k}))
    big = Nx.broadcast(Nx.tensor(1.0e18, type: :f32), {n, k})
    masked = Nx.select(one_hot, all_dists, big)

    best_idx = Nx.argmin(masked, axis: 0)
    Nx.take(points, best_idx)
  end
end

# ----- arg parsing -----

# Make sure Nx + EXLA are running even with `mix run --no-start`.
{:ok, _} = Application.ensure_all_started(:exla)
{:ok, _} = Application.ensure_all_started(:jason)

parse_int = fn
  nil, default -> default
  s, _ -> String.to_integer(s)
end

argv = System.argv()

k =
  case System.get_env("K") do
    nil -> parse_int.(Enum.at(argv, 0), 0)
    s -> String.to_integer(s)
  end

iters =
  case System.get_env("ITERS") do
    nil -> parse_int.(Enum.at(argv, 1), 50)
    s -> String.to_integer(s)
  end

input = System.get_env("INPUT") || "resources/references.json.gz"
output = System.get_env("OUTPUT") || "priv/references_v2.bin"

BuildRefs.run(input: input, output: output, k: k, max_iters: iters)
:ok

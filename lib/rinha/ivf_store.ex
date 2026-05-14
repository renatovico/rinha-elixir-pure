defmodule Rinha.IvfStore do
  @moduledoc """
  Loads the IVF (Inverted File) index built by `priv/build_ivf_index.exs`.

  The on-disk format is documented in `priv/build_ivf_index.exs`.

  After load (`build/0`):

    * `centroids/0`      — refcounted binary, K * 32 bytes (K rows of 16 s16)
    * `offsets/0`        — tuple of K+1 ints (CSR offsets into `vectors/0`)
    * `vectors/0`        — refcounted binary, N * 32 bytes (regrouped by bucket)
    * `labels/0`         — refcounted binary, N bytes (regrouped by bucket)
    * `k/0`              — number of centroids
    * `n/0`              — total references

  Memory: ~99 MB persistent total.  Centroids (32 KB) + offsets (8 KB)
  are tiny; the bulk is the regrouped vector + label binaries which are
  the same size as the source `references_v2.bin`.
  """

  require Logger

  @persistent_key {:rinha, :ivf_store}

  def build(opts \\ []) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:rinha, :ivf_index_path) ||
        System.get_env("IVF_INDEX_PATH") ||
        Path.join(:code.priv_dir(:rinha), "ivf_index.bin")

    Logger.info("Loading IVF index from #{path}...")
    bin = File.read!(path)

    <<k::little-32, n::little-32, stride::little-32, rest::binary>> = bin

    centroids_bytes = k * stride * 2
    offsets_bytes = (k + 1) * 4
    vec_bytes = n * stride * 2

    <<centroids::binary-size(centroids_bytes),
      offsets_bin::binary-size(offsets_bytes),
      vectors::binary-size(vec_bytes),
      labels::binary-size(n)>> = rest

    offsets =
      for <<o::little-32 <- offsets_bin>>, do: o

    payload = %{
      centroids: centroids,
      offsets: List.to_tuple(offsets),
      vectors: vectors,
      labels: labels,
      k: k,
      n: n,
      stride: stride
    }

    :persistent_term.put(@persistent_key, payload)

    Logger.info(
      "IVF store ready: k=#{k} n=#{n} stride=#{stride} " <>
        "centroids=#{byte_size(centroids)}B vectors=#{byte_size(vectors)}B"
    )

    :ok
  end

  def get, do: :persistent_term.get(@persistent_key)
  def centroids, do: get().centroids
  def offsets, do: get().offsets
  def vectors, do: get().vectors
  def labels, do: get().labels
  def k, do: get().k
  def n, do: get().n
  def stride, do: get().stride

  @doc """
  Return the byte slice of `vectors` and `labels` for the given centroid id.
  """
  def bucket_slice(cid) do
    %{offsets: o, vectors: v, labels: l} = get()
    start = elem(o, cid)
    stop = elem(o, cid + 1)
    len = stop - start
    {:binary.part(v, start * 32, len * 32), :binary.part(l, start, len), len}
  end
end

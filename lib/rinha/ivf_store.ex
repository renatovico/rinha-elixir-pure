defmodule Rinha.IvfStore do
  @moduledoc """
  Loads the IVF (Inverted File) index built by `priv/build_ivf_index.exs`.

  To keep RAM usage low, only centroids + offsets are held in memory.
  Bucket vectors/labels are read on-demand from disk via `:file.pread/3`.

  Two on-disk formats are supported:

  ## v1 (legacy)

      <<K::little-32, N::little-32, stride::little-32>>     # 12 B header
      <<centroids::binary-K*16*int16-le>>                   # K * 32 B
      <<offsets::binary-(K+1)*int32-le>>                    # (K+1) * 4 B  CSR
      <<vectors::binary-N*16*int16-le>>                     # N * 32 B
      <<labels::binary-N*int8>>                             # N B

  ## v2 (with cached squared norms)

  Identical to v1 but with two extra sections appended after the
  centroid block and the vector block respectively. A 4-byte magic
  `0xF2F1F0v2` distinguishes it from v1 (which has K < 2^31 in the
  first 4 bytes — magic is chosen above any plausible K).

      <<magic::little-32, K, N, stride>>                    # 16 B header
      <<centroids: K*32>>
      <<centroid_norms: K*4 (s32 LE)>>                      # NEW
      <<offsets: (K+1)*4>>
      <<vectors: N*32>>
      <<ref_norms: N*4 (s32 LE)>>                           # NEW
      <<labels: N>>

  After load (`build/0`):

    * `centroids/0`      — refcounted binary, K * 32 bytes
    * `centroid_norms/0` — refcounted binary, K * 4 bytes (s32 LE), or `nil` for v1
    * `offsets/0`        — tuple of K+1 ints (CSR offsets)
    * `vectors/0`        — `nil` (read on demand)
    * `ref_norms/0`      — `nil` (v2 cache not used in hot path)
    * `labels/0`         — `nil` (read on demand)
    * `k/0`, `n/0`, `stride/0`, `version/0`
  """

  require Logger

  @persistent_key {:rinha, :ivf_store}
  @magic_v2 0xF2F1F0F2

  def build(opts \\ []) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:rinha, :ivf_index_path) ||
        System.get_env("IVF_INDEX_PATH") ||
        Path.join(:code.priv_dir(:rinha), "ivf_index.bin")

    Logger.info("Loading IVF index metadata from #{path}...")
    payload = load_metadata(path)

    :persistent_term.put(@persistent_key, payload)

    Logger.info(
      "IVF store ready: v#{payload.version} k=#{payload.k} n=#{payload.n} " <>
        "stride=#{payload.stride} centroids=#{byte_size(payload.centroids)}B " <>
        "vectors=ondemand labels=ondemand norms=#{payload.centroid_norms != nil}"
    )

    :ok
  end

  defp load_metadata(path) do
    {:ok, fd} = :file.open(path, [:read, :binary])

    case read_exact(fd, 0, 16) do
      <<@magic_v2::little-32, k::little-32, n::little-32, stride::little-32>> ->
        load_v2(fd, path, k, n, stride)

      <<k::little-32, n::little-32, stride::little-32, _::little-32>> ->
        load_v1(fd, path, k, n, stride)
    end
  end

  defp load_v2(fd, path, k, n, stride) do
    centroids_bytes = k * stride * 2
    cnorms_bytes = k * 4
    offsets_bytes = (k + 1) * 4
    vectors_offset = 16 + centroids_bytes + cnorms_bytes + offsets_bytes
    labels_offset = vectors_offset + n * stride * 2 + n * 4

    centroids = read_exact(fd, 16, centroids_bytes)
    centroid_norms = read_exact(fd, 16 + centroids_bytes, cnorms_bytes)
    offsets_bin = read_exact(fd, 16 + centroids_bytes + cnorms_bytes, offsets_bytes)

    %{
      version: 2,
      fd: fd,
      path: path,
      centroids: centroids,
      centroid_norms: centroid_norms,
      offsets: List.to_tuple(decode_offsets(offsets_bin)),
      vectors: nil,
      ref_norms: nil,
      labels: nil,
      vectors_offset: vectors_offset,
      labels_offset: labels_offset,
      k: k,
      n: n,
      stride: stride
    }
  end

  defp load_v1(fd, path, k, n, stride) do
    centroids_bytes = k * stride * 2
    offsets_bytes = (k + 1) * 4
    vectors_offset = 12 + centroids_bytes + offsets_bytes
    labels_offset = vectors_offset + n * stride * 2

    centroids = read_exact(fd, 12, centroids_bytes)
    offsets_bin = read_exact(fd, 12 + centroids_bytes, offsets_bytes)

    %{
      version: 1,
      fd: fd,
      path: path,
      centroids: centroids,
      centroid_norms: nil,
      offsets: List.to_tuple(decode_offsets(offsets_bin)),
      vectors: nil,
      ref_norms: nil,
      labels: nil,
      vectors_offset: vectors_offset,
      labels_offset: labels_offset,
      k: k,
      n: n,
      stride: stride
    }
  end

  defp decode_offsets(bin), do: for(<<o::little-32 <- bin>>, do: o)

  def get, do: :persistent_term.get(@persistent_key)
  def centroids, do: get().centroids
  def centroid_norms, do: get().centroid_norms
  def offsets, do: get().offsets
  def vectors, do: get().vectors
  def ref_norms, do: get().ref_norms
  def labels, do: get().labels
  def k, do: get().k
  def n, do: get().n
  def stride, do: get().stride
  def version, do: get().version

  @doc """
  Return the byte slice of `vectors` and `labels` for the given centroid id.
  """
  def bucket_slice(cid) do
    %{offsets: o, fd: fd, vectors_offset: voff, labels_offset: loff, stride: stride} = get()
    start = elem(o, cid)
    stop = elem(o, cid + 1)
    len = stop - start

    if len <= 0 do
      {<<>>, <<>>, 0}
    else
      vectors_bytes = len * stride * 2
      vectors = read_exact(fd, voff + start * stride * 2, vectors_bytes)
      labels = read_exact(fd, loff + start, len)
      {vectors, labels, len}
    end
  end

  defp read_exact(fd, offset, len) do
    case :file.pread(fd, offset, len) do
      {:ok, bin} when byte_size(bin) == len -> bin
      {:ok, _short} -> raise "short read from IVF index"
      {:error, reason} -> raise "IVF read failed: #{inspect(reason)}"
    end
  end
end

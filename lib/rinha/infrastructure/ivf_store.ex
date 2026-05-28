defmodule Rinha.IvfStore do
  @moduledoc """
  Loads IVF index metadata and reads bucket payloads on demand.

  The default index path is `priv/ivf_index.bin`, produced from the official
  `references.json.gz` dataset.
  """

  require Logger

  @persistent_key {:rinha, :ivf_store}

  def build(opts \\ []) do
    previous = :persistent_term.get(@persistent_key, nil)

    references_path =
      Application.get_env(:rinha, :references_path) ||
        System.get_env("REFERENCES_PATH") ||
        "(default)"

    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:rinha, :ivf_index_path) ||
        System.get_env("IVF_INDEX_PATH") ||
        Path.join(:code.priv_dir(:rinha), "ivf_index.bin")

    Logger.info(
      "Loading IVF index metadata from #{path} (references=#{references_path}, io=iommap)..."
    )

    handle = open_mapping!(path)
    payload = load_metadata(path, handle)

    if is_map(previous) do
      maybe_close_mapping(previous)
    end

    payload = Map.put(payload, :iommap_handle, handle)

    :persistent_term.put(@persistent_key, payload)

    Logger.info(
      "IVF store ready: v#{payload.version} k=#{payload.k} n=#{payload.n} " <>
        "stride=#{payload.stride} centroids=#{byte_size(payload.centroids)}B " <>
        "vectors=ondemand labels=ondemand io=iommap norms=#{payload.centroid_norms != nil}"
    )

    :ok
  end

  defp load_metadata(path, handle) do
    case read_exact_mmap(handle, 0, 16) do
      {:ok, <<k::little-32, n::little-32, stride::little-32, _::little-32>>} ->
        load_v1(path, handle, k, n, stride)

      {:ok, other} ->
        raise "unsupported IVF index format (expected v1 header, got #{inspect(other)})"

      {:error, reason} ->
        raise "IVF metadata read failed: #{inspect(reason)}"
    end
  end

  defp open_mapping!(path) do
    case :iommap.open(String.to_charlist(path), :read, [:shared]) do
      {:ok, handle} ->
        handle

      {:error, reason} ->
        raise "failed to open IVF iommap handle: #{inspect(reason)}"

      other ->
        raise "unexpected iommap.open/3 return: #{inspect(other)}"
    end
  end

  defp load_v1(path, handle, k, n, stride) do
    centroids_bytes = k * stride * 2
    offsets_bytes = (k + 1) * 4
    vectors_offset = 12 + centroids_bytes + offsets_bytes
    labels_offset = vectors_offset + n * stride * 2

    centroids = read_exact_mmap!(handle, 12, centroids_bytes)
    offsets_bin = read_exact_mmap!(handle, 12 + centroids_bytes, offsets_bytes)

    %{
      version: 1,
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

  defp maybe_close_mapping(%{iommap_handle: handle}) when not is_nil(handle) do
    try do
      _ = :iommap.close(handle)
      :ok
    catch
      :error, _ -> :ok
      :exit, _ -> :ok
    end
  end

  defp maybe_close_mapping(_), do: :ok

  defp decode_offsets(bin), do: for(<<o::little-32 <- bin>>, do: o)

  def get do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        :ok = build()
        :persistent_term.get(@persistent_key)

      store ->
        store
    end
  end

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

  def bucket_slice(cid) do
    store = get()

    start = elem(store.offsets, cid)
    stop = elem(store.offsets, cid + 1)
    len = stop - start

    if len <= 0 do
      {<<>>, <<>>, 0}
    else
      case read_bucket(store, start, len) do
        {:ok, vectors, labels} ->
          {vectors, labels, len}

        {:error, reason} ->
          recover_and_retry(store.path, cid, reason)
      end
    end
  end

  defp read_bucket(store, start, len) do
    vectors_bytes = len * store.stride * 2
    vectors_offset = store.vectors_offset + start * store.stride * 2
    labels_offset = store.labels_offset + start

    with {:ok, vectors} <- read_exact_mmap(store.iommap_handle, vectors_offset, vectors_bytes),
         {:ok, labels} <- read_exact_mmap(store.iommap_handle, labels_offset, len) do
      {:ok, vectors, labels}
    end
  end

  defp recover_and_retry(path, cid, reason) do
    Logger.warning("IVF mmap read failed (#{inspect(reason)}), remapping #{path}")
    :ok = build(path: path)

    store = get()

    start = elem(store.offsets, cid)
    stop = elem(store.offsets, cid + 1)
    len = stop - start

    if len <= 0 do
      {<<>>, <<>>, 0}
    else
      case read_bucket(store, start, len) do
        {:ok, vectors, labels} ->
          {vectors, labels, len}

        {:error, retry_reason} ->
          raise "IVF mmap read failed after retry: #{inspect(retry_reason)}"
      end
    end
  end

  defp read_exact_mmap(handle, offset, len) do
    try do
      case :iommap.region_binary(handle, offset, len) do
        {:ok, bin} when byte_size(bin) == len -> {:ok, bin}
        {:ok, _short} -> {:error, :short_read}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_iommap_read_result, other}}
      end
    catch
      :error, reason -> {:error, reason}
      :exit, reason -> {:error, reason}
    end
  end

  defp read_exact_mmap!(handle, offset, len) do
    case read_exact_mmap(handle, offset, len) do
      {:ok, bin} -> bin
      {:error, :short_read} -> raise "short read from IVF index"
      {:error, reason} -> raise "IVF metadata read failed: #{inspect(reason)}"
    end
  end
end

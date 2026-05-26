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

    Logger.info("Loading IVF index metadata from #{path} (references=#{references_path})...")
    payload = load_metadata(path)
    {fd_owner, fd} = open_shared_fd(path)

    if is_map(previous) do
      maybe_stop_fd_owner(previous)
    end

    payload = Map.merge(payload, %{fd_owner: fd_owner, fd: fd})

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

    try do
      case read_exact(fd, 0, 16) do
        <<k::little-32, n::little-32, stride::little-32, _::little-32>> ->
          load_v1(fd, path, k, n, stride)

        other ->
          raise "unsupported IVF index format (expected v1 header, got #{inspect(other)})"
      end
    after
      :ok = :file.close(fd)
    end
  end

  defp open_shared_fd(path) do
    parent = self()

    owner =
      spawn(fn ->
        case :file.open(path, [:read, :binary]) do
          {:ok, fd} ->
            send(parent, {:ivf_fd_ready, self(), fd})
            fd_owner_loop(fd)

          {:error, reason} ->
            send(parent, {:ivf_fd_error, self(), reason})
        end
      end)

    receive do
      {:ivf_fd_ready, ^owner, fd} ->
        {owner, fd}

      {:ivf_fd_error, ^owner, reason} ->
        raise "failed to open IVF index fd: #{inspect(reason)}"
    after
      5_000 ->
        raise "timed out opening IVF index fd"
    end
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

  defp fd_owner_loop(fd) do
    receive do
      {:stop, from, ref} ->
        _ = :file.close(fd)
        send(from, {:stopped, ref})

      _other ->
        fd_owner_loop(fd)
    end
  end

  defp maybe_stop_fd_owner(%{fd_owner: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = make_ref()
      send(pid, {:stop, self(), ref})

      receive do
        {:stopped, ^ref} -> :ok
      after
        500 -> Process.exit(pid, :kill)
      end
    else
      :ok
    end
  end

  defp maybe_stop_fd_owner(_), do: :ok

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
    %{offsets: o, fd: fd, vectors_offset: voff, labels_offset: loff, stride: stride, path: path} = get()
    start = elem(o, cid)
    stop = elem(o, cid + 1)
    len = stop - start

    if len <= 0 do
      {<<>>, <<>>, 0}
    else
      vectors_bytes = len * stride * 2

      case {
             read_exact_result(fd, voff + start * stride * 2, vectors_bytes),
             read_exact_result(fd, loff + start, len)
           } do
        {{:ok, vectors}, {:ok, labels}} ->
          {vectors, labels, len}

        {{:error, :terminated}, _} ->
          recover_and_retry(path, cid)

        {_, {:error, :terminated}} ->
          recover_and_retry(path, cid)

        {{:error, reason}, _} ->
          raise "IVF read failed: #{inspect(reason)}"

        {_, {:error, reason}} ->
          raise "IVF read failed: #{inspect(reason)}"
      end
    end
  end

  defp recover_and_retry(path, cid) do
    Logger.warning("IVF file descriptor terminated, reopening #{path}")
    :ok = build(path: path)

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

  defp read_exact_result(fd, offset, len) do
    case :file.pread(fd, offset, len) do
      {:ok, bin} when byte_size(bin) == len -> {:ok, bin}
      {:ok, _short} -> {:error, :short_read}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_exact(fd, offset, len) do
    case read_exact_result(fd, offset, len) do
      {:ok, bin} -> bin
      {:error, :short_read} -> raise "short read from IVF index"
      {:error, reason} -> raise "IVF read failed: #{inspect(reason)}"
    end
  end
end

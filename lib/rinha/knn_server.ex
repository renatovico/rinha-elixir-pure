defmodule Rinha.KnnServer do
  @moduledoc """
  Front door for KNN queries.

  Decides whether to scan locally (full set) or split work with the
  cluster peer.

  Strategy:

    * If a peer is registered (`Rinha.ClusterConnector` keeps it
      fresh) → scan local first half on the calling process while
      asking the peer to scan its second half via `:erpc.send_request`.
      Merge top-K when both finish.

    * If no peer or peer call fails → scan the full set locally
      (graceful degradation, still 0 FP).

  Each scan slice is further parallelised across `@parallel_chunks`
  schedulers via `Task.async_stream`.

  This is the public API for the hot path.
  """

  require Logger

  @parallel_chunks 2
  @peer_timeout 1_500

  @doc """
  Score a 16-int query, returning the fraud-neighbour count in 0..5.
  """
  @spec score([integer()]) :: 0..5
  def score(query) when is_list(query) do
    n = Rinha.KnnStore.count()
    half = div(n, 2)

    case maybe_dispatch_peer(query, half, n) do
      {:peer, request_id} ->
        local_topk = scan_range(query, 0, half)

        peer_topk =
          try do
            :erpc.receive_response(request_id, @peer_timeout)
          catch
            kind, reason ->
              Logger.warning(
                "Peer scan failed (#{inspect(kind)}: #{inspect(reason)}), falling back to local-full"
              )

              scan_range(query, half, n - half)
          end

        Rinha.KnnScanner.merge_topk([local_topk, peer_topk])
        |> Rinha.KnnScanner.fraud_count()

      :local ->
        scan_range(query, 0, n)
        |> Rinha.KnnScanner.fraud_count()
    end
  end

  ## Remote entry point (called via :erpc from the peer node).

  @doc false
  def remote_scan(query, offset, length) do
    scan_range(query, offset, length)
  end

  ## Internals

  defp maybe_dispatch_peer(query, half, n) do
    case Rinha.ClusterConnector.peer_node() do
      nil ->
        :local

      peer ->
        try do
          rid =
            :erpc.send_request(
              peer,
              __MODULE__,
              :remote_scan,
              [query, half, n - half]
            )

          {:peer, rid}
        catch
          _, _ -> :local
        end
    end
  end

  # Scan `length` rows starting at `offset`, using parallel chunks.
  defp scan_range(query, offset, length) do
    vectors = Rinha.KnnStore.vectors_binary()
    labels = Rinha.KnnStore.labels_binary()

    chunk_rows = div(length, @parallel_chunks)
    remainder = rem(length, @parallel_chunks)

    ranges =
      for i <- 0..(@parallel_chunks - 1) do
        chunk_offset = offset + i * chunk_rows
        chunk_len = if i == @parallel_chunks - 1, do: chunk_rows + remainder, else: chunk_rows
        {chunk_offset, chunk_len}
      end

    ranges
    |> Task.async_stream(
      fn {off, len} ->
        v_slice = :binary.part(vectors, off * 32, len * 32)
        l_slice = :binary.part(labels, off, len)
        Rinha.KnnScanner.scan_slice(v_slice, l_slice, query)
      end,
      max_concurrency: @parallel_chunks,
      ordered: false,
      timeout: 5_000
    )
    |> Enum.map(fn {:ok, topk} -> topk end)
    |> Rinha.KnnScanner.merge_topk()
  end
end

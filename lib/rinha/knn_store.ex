defmodule Rinha.KnnStore do
  @moduledoc """
  Loads the reference set into a single refcounted binary (shared across
  all schedulers, single 99 MB allocation per node).

  Layout of `references_v2.bin`:

      <<count::little-32, count*16*int16-le, count*u8>>

  After load:

    * `vectors_binary/0` returns the `count * 32` byte slice (s16 LE,
      row-major, 16 lanes per row).
    * `labels_binary/0` returns the `count` byte slice (u8 fraud labels).
    * `count/0` returns the number of references.
  """

  require Logger

  @persistent_key {:rinha, :knn_store}

  def build(opts \\ []) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:rinha, :references_v2_path) ||
        System.get_env("REFERENCES_V2_PATH") ||
        Path.join(:code.priv_dir(:rinha), "references_v2.bin")

    Logger.info("Loading KNN references from #{path}...")
    bin = File.read!(path)

    <<count::little-32, rest::binary>> = bin
    vec_bytes = count * 32
    <<vectors::binary-size(vec_bytes), labels::binary-size(count)>> = rest

    payload = %{
      vectors: vectors,
      labels: labels,
      count: count
    }

    :persistent_term.put(@persistent_key, payload)
    Logger.info("KNN store ready: count=#{count} vectors=#{byte_size(vectors)}B")
    :ok
  end

  def vectors_binary, do: get().vectors
  def labels_binary, do: get().labels
  def count, do: get().count
  def get, do: :persistent_term.get(@persistent_key)
end

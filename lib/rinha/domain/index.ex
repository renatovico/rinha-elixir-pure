defmodule Rinha.Domain.Index do
  @moduledoc """
  Domain facade for IVF index lifecycle and reads.
  """

  @spec build!() :: :ok
  def build!, do: Rinha.IvfStore.build()

  @spec bucket_slice(non_neg_integer()) :: {binary(), binary(), non_neg_integer()}
  def bucket_slice(cid), do: Rinha.IvfStore.bucket_slice(cid)

  @spec centroids() :: binary()
  def centroids, do: Rinha.IvfStore.centroids()
end

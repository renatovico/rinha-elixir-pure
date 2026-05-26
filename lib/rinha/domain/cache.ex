defmodule Rinha.Domain.Cache do
  @moduledoc """
  Domain facade for score cache and bloom lifecycle.
  """

  @spec init() :: :ok
  def init, do: Rinha.BloomFilter.init()

  @spec lookup(atom(), [integer()]) :: {:hit, 0..5} | :miss
  def lookup(namespace, vector), do: Rinha.BloomFilter.lookup(namespace, vector)

  @spec put(atom(), [integer()], 0..5) :: :ok
  def put(namespace, vector, n), do: Rinha.BloomFilter.put(namespace, vector, n)
end

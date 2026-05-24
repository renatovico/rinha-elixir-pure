defmodule Rinha.BloomFilterTest do
  use ExUnit.Case, async: false

  setup do
    Rinha.BloomFilter.init(bits: 1024)
    :ok
  end

  @vector [34, 1638, 4096, 6411, 2731, -8192, -8192, 239, 1229, 0, 8192, 0, 1229, 99, 0, 0]

  test "returns a cached fraud count for a previously scored vector" do
    assert Rinha.BloomFilter.lookup(@vector) == :miss

    assert :ok = Rinha.BloomFilter.put(@vector, 3)
    assert Rinha.BloomFilter.lookup(@vector) == {:hit, 3}
  end

  test "non-vector keys bypass the cache" do
    assert Rinha.BloomFilter.lookup(nil) == :miss
    assert Rinha.BloomFilter.put(nil, 1) == :ok
  end
end

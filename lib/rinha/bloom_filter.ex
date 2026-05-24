defmodule Rinha.BloomFilter do
  @moduledoc """
  Probabilistic front door for the vector score cache.

  New vectors skip the ETS lookup and go straight to scoring. Vectors that the Bloom
  filter marks as possible repeats are checked against ETS so false positives
  only cost a lookup; they never change the fraud decision.
  """

  import Bitwise

  @persistent_key {:rinha, :bloom_filter}
  @table :rinha_score_cache
  @default_bits 4_194_304
  @hash_salt 0x9E3779B97F4A7C15
  @word_bits 64

  @doc "Initialize the Bloom filter and clear the score cache."
  def init(opts \\ []) do
    bits = Keyword.get(opts, :bits, @default_bits)
    true = bits >= @word_bits and power_of_two?(bits)

    ensure_table!()
    :ets.delete_all_objects(@table)

    :persistent_term.put(@persistent_key, %{
      ref: :atomics.new(div(bits, @word_bits), signed: false),
      mask: bits - 1
    })

    :ok
  end

  @doc "Return `{:hit, fraud_count}` when a vector was scored before."
  def lookup(vector) when is_list(vector) do
    key = vector_key(vector)
    filter = filter!()

    if maybe_contains?(filter, key) do
      case :ets.lookup(@table, key) do
        [{^key, n}] -> {:hit, n}
        [] -> :miss
      end
    else
      :miss
    end
  end

  def lookup(_id), do: :miss

  @doc "Store the fraud-neighbour count for a scored vector."
  def put(vector, n) when is_list(vector) and n in 0..5 do
    key = vector_key(vector)
    filter = filter!()
    true = :ets.insert(@table, {key, n})
    add(filter, key)
    :ok
  end

  def put(_id, _n), do: :ok

  defp filter! do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        init()
        :persistent_term.get(@persistent_key)

      filter ->
        filter
    end
  end

  defp maybe_contains?(filter, key) do
    {a, b, c} = indexes(filter, key)
    bit_set?(filter, a) and bit_set?(filter, b) and bit_set?(filter, c)
  end

  defp add(filter, key) do
    {a, b, c} = indexes(filter, key)
    set_bit(filter, a)
    set_bit(filter, b)
    set_bit(filter, c)
  end

  defp indexes(%{mask: mask}, key) do
    h1 = :erlang.phash2(key, mask + 1)
    h2 = :erlang.phash2({@hash_salt, key}, mask + 1) ||| 1
    h3 = h1 + h2
    h4 = h3 + h2

    {h1, h3 &&& mask, h4 &&& mask}
  end

  defp vector_key([v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15]) do
    <<v0::little-signed-16, v1::little-signed-16, v2::little-signed-16, v3::little-signed-16,
      v4::little-signed-16, v5::little-signed-16, v6::little-signed-16, v7::little-signed-16,
      v8::little-signed-16, v9::little-signed-16, v10::little-signed-16, v11::little-signed-16,
      v12::little-signed-16, v13::little-signed-16, v14::little-signed-16, v15::little-signed-16>>
  end

  defp bit_set?(%{ref: ref}, idx) do
    word_idx = (idx >>> 6) + 1
    mask = 1 <<< (idx &&& 63)
    (:atomics.get(ref, word_idx) &&& mask) != 0
  end

  defp set_bit(%{ref: ref}, idx) do
    word_idx = (idx >>> 6) + 1
    mask = 1 <<< (idx &&& 63)
    set_word_bit(ref, word_idx, mask)
  end

  defp set_word_bit(ref, word_idx, mask) do
    current = :atomics.get(ref, word_idx)
    updated = current ||| mask

    cond do
      updated == current ->
        :ok

      :atomics.compare_exchange(ref, word_idx, current, updated) == :ok ->
        :ok

      true ->
        set_word_bit(ref, word_idx, mask)
    end
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp power_of_two?(n) do
    (n &&& (n - 1)) == 0
  end
end

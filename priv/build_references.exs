#!/usr/bin/env elixir

# Build `priv/references_v2.bin` from `references.json.gz`.
#
# Output binary format:
#
#   <<count::little-32>>
#   <<vectors::binary-size(count * 16 * 2)>>  # int16 little-endian
#   <<labels::binary-size(count)>>             # uint8 (fraud=1 legit=0)
#
# Vector layout is 16 lanes (`s16`):
#   - lanes 0..13 from reference `vector` quantized by scale=8192
#   - lanes 14..15 fixed to zero (padding)

defmodule BuildReferences do
  @scale 8192
  @dims 14

  def run(opts) do
    input = Keyword.fetch!(opts, :input)
    output = Keyword.fetch!(opts, :output)
    limit = Keyword.get(opts, :limit)

    IO.puts("Loading references from #{input}...")
    references = load_json_gz(input)
    references = maybe_take_limit(references, limit)
    count = length(references)

    IO.puts("Quantizing #{count} references...")

    vectors_iodata =
      Enum.map(references, fn reference ->
        reference
        |> Map.fetch!("vector")
        |> quantize_padded()
        |> Enum.map(fn lane -> <<lane::little-signed-16>> end)
      end)

    labels_iodata =
      Enum.map(references, fn reference ->
        <<encode_label(Map.get(reference, "label"))::unsigned-8>>
      end)

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, [<<count::little-32>>, vectors_iodata, labels_iodata])

    %{size: size} = File.stat!(output)
    IO.puts("Wrote #{output} (#{size} bytes)")
    :ok
  end

  defp maybe_take_limit(references, limit) when is_integer(limit) and limit > 0 do
    Enum.take(references, limit)
  end

  defp maybe_take_limit(references, _), do: references

  defp load_json_gz(path) do
    {:ok, file} = File.open(path, [:read, :compressed])

    try do
      file
      |> IO.binread(:eof)
      |> Jason.decode!()
    after
      File.close(file)
    end
  end

  defp quantize_padded(vector) when is_list(vector) and length(vector) == @dims do
    Enum.map(vector, &quantize/1) ++ [0, 0]
  end

  defp quantize_padded(other) do
    raise "expected 14-d vector, got #{inspect(other)}"
  end

  defp quantize(value) when is_number(value) do
    q = round(value * @scale)

    cond do
      q > 32_767 -> 32_767
      q < -32_768 -> -32_768
      true -> q
    end
  end

  defp encode_label("fraud"), do: 1
  defp encode_label("legit"), do: 0
  defp encode_label(1), do: 1
  defp encode_label(0), do: 0

  defp encode_label(other) do
    raise "unknown reference label #{inspect(other)}"
  end
end

{:ok, _} = Application.ensure_all_started(:jason)

input = System.get_env("INPUT") || "resources/references.json.gz"
output = System.get_env("OUTPUT") || "priv/references_v2.bin"

limit =
  case System.get_env("LIMIT") do
    nil -> nil
    "" -> nil
    value -> String.to_integer(value)
  end

:ok = BuildReferences.run(input: input, output: output, limit: limit)

defmodule Rinha.ReferenceDatasetTest do
  use ExUnit.Case, async: true

  test "official references dataset is present in repository resources" do
    path = Path.expand("resources/references.json.gz")
    assert File.exists?(path)
    assert {:ok, %{size: size}} = File.stat(path)
    assert size > 0
  end
end

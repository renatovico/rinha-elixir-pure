defmodule Rinha.ReferenceDatasetTest do
  use ExUnit.Case, async: true

  test "resolves and validates references dataset path" do
    path = Rinha.Domain.Bootstrap.reference_dataset_path()
    assert is_binary(path)
    assert String.ends_with?(path, "references.json.gz")
    assert :ok = Rinha.Domain.Bootstrap.ensure_reference_dataset!()
  end
end

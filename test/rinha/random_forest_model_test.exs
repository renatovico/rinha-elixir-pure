defmodule Rinha.XGBoostModelTest do
  use ExUnit.Case, async: false

  setup do
    old_path = Application.get_env(:rinha, :random_forest_path)

    on_exit(fn ->
      if old_path == nil do
        Application.delete_env(:rinha, :random_forest_path)
      else
        Application.put_env(:rinha, :random_forest_path, old_path)
      end
    end)

    :ok
  end

  test "loads and scores compact random forest model" do
    path = Path.join(System.tmp_dir!(), "rinha-rf-test-#{System.unique_integer([:positive])}.bin")
    File.write!(path, test_forest())
    Application.put_env(:rinha, :random_forest_path, path)
    :ok = Rinha.RandomForestStore.build()

    assert Rinha.Domain.Models.XGBoost.score(List.duplicate(0, 16)) == 0
    assert Rinha.Domain.Models.XGBoost.score([8192 | List.duplicate(0, 15)]) == 5

    File.rm(path)
  end

  test "loads and scores boosted logistic tree ensemble" do
    path =
      Path.join(System.tmp_dir!(), "rinha-xgb-test-#{System.unique_integer([:positive])}.bin")

    File.write!(path, test_boosted_forest())
    Application.put_env(:rinha, :random_forest_path, path)
    :ok = Rinha.RandomForestStore.build()

    assert Rinha.Domain.Models.XGBoost.score(List.duplicate(0, 16)) == 0
    assert Rinha.Domain.Models.XGBoost.score([8192 | List.duplicate(0, 15)]) == 5

    File.rm(path)
  end

  defp test_forest do
    nodes = [
      {0, 0.5, 1, 2, 0.0},
      {-1, 0.0, 0, 0, 0.0},
      {-1, 0.0, 0, 0, 1.0}
    ]

    <<"RFF1", 1::little-32, 1::little-32, length(nodes)::little-32>> <> encode_nodes(nodes)
  end

  defp encode_nodes(nodes) do
    for {feature, threshold, left, right, value} <- nodes, into: <<>> do
      <<feature::signed-little-8, threshold::little-float-32, left::little-32, right::little-32,
        value::little-float-32>>
    end
  end

  defp test_boosted_forest do
    nodes = [
      {0, 0.5, 1, 2, 0.0},
      {-1, 0.0, 0, 0, -8.0},
      {-1, 0.0, 0, 0, 8.0}
    ]

    <<"RFF2", 2::little-32, 2::unsigned-8, 0.0::little-float-32, 1::little-32,
      length(nodes)::little-32>> <> encode_nodes(nodes)
  end
end

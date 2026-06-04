defmodule Rinha.XGBoostModelTest do
  use ExUnit.Case, async: false

  setup do
    old_path = Application.get_env(:rinha, :xgboost_path)

    on_exit(fn ->
      if old_path == nil do
        Application.delete_env(:rinha, :xgboost_path)
      else
        Application.put_env(:rinha, :xgboost_path, old_path)
      end
    end)

    :ok
  end

  test "loads and scores boosted logistic tree ensemble" do
    path =
      Path.join(System.tmp_dir!(), "rinha-xgb-test-#{System.unique_integer([:positive])}.bin")

    File.write!(path, test_boosted_model())
    Application.put_env(:rinha, :xgboost_path, path)
    :ok = Rinha.XGBoostStore.build()

    assert Rinha.Domain.Models.XGBoost.score(List.duplicate(0, 16)) == 0
    assert Rinha.Domain.Models.XGBoost.score([8192 | List.duplicate(0, 15)]) == 5

    File.rm(path)
  end

  defp encode_nodes(nodes) do
    for {feature, threshold, left, right, value} <- nodes, into: <<>> do
      <<feature::signed-little-8, threshold::little-float-64, left::little-32, right::little-32,
        value::little-float-64>>
    end
  end

  defp test_boosted_model do
    nodes = [
      {0, 0.5, 1, 2, 0.0},
      {-1, 0.0, 0, 0, -8.0},
      {-1, 0.0, 0, 0, 8.0}
    ]

    <<"RFF2", 2::little-32, 2::unsigned-8, 0.0::little-float-64, 1::little-32,
      length(nodes)::little-32>> <> encode_nodes(nodes)
  end
end

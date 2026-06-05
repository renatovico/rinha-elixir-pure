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

  test "loads EXGBoost model and scores 16-dim vectors" do
    path = Path.join(:code.priv_dir(:rinha), "model.json")

    Application.put_env(:rinha, :xgboost_path, path)
    :ok = Rinha.XGBoostStore.build(path: path)

    assert Rinha.Domain.Models.XGBoost.score(List.duplicate(0, 16)) in 0..5
    assert Rinha.Domain.Models.XGBoost.score(List.duplicate(8192, 16)) in 0..5
  end
end

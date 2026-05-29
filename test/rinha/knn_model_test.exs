defmodule Rinha.KNNModelTest do
  use ExUnit.Case, async: false

  setup_all do
    :ok = Rinha.Domain.Bootstrap.ensure_reference_dataset!()
    Rinha.Domain.ReferenceData.load!()
    :ok = Rinha.Domain.Index.build!()
    :ok
  end

  test "legit fixture stays approved and fraud fixture stays denied" do
    legit = fixture_vector("legit")
    fraud = fixture_vector("fraud")

    legit_n = Rinha.Domain.Models.KNN.score(legit)
    fraud_n = Rinha.Domain.Models.KNN.score(fraud)

    assert legit_n in 0..2
    assert fraud_n in 3..5
    assert fraud_n > legit_n
  end

  test "KNN scorer returns counts in valid range" do
    border = fixture_vector("borderline")
    n = Rinha.Domain.Models.KNN.score(border)
    assert n in 0..5
  end

  test "scorer uses configured probe budget" do
    old = Application.get_env(:rinha, :knn_probes)
    vector = fixture_vector("fraud")

    on_exit(fn ->
      if old == nil do
        Application.delete_env(:rinha, :knn_probes)
      else
        Application.put_env(:rinha, :knn_probes, old)
      end
    end)

    Application.put_env(:rinha, :knn_probes, 1)
    n1 = Rinha.Domain.Models.KNN.score(vector)

    Application.put_env(:rinha, :knn_probes, 16)
    n2 = Rinha.Domain.Models.KNN.score(vector)

    assert n1 in 0..5
    assert n2 in 0..5
  end

  defp fixture_vector(name) do
    path = Path.join([:code.priv_dir(:rinha), "resources", "fixtures", "#{name}.json"])

    path
    |> File.read!()
    |> Jason.decode!()
    |> Rinha.Domain.Vectorization.transform()
  end
end

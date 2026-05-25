defmodule Rinha.NeuralScorerTest do
  use ExUnit.Case, async: true

  setup_all do
    Rinha.Resources.load!()
    :ok = Rinha.BloomFilter.init()
    :ok
  end

  test "fraud fixture scores higher than legit fixture" do
    legit = fixture_vector("legit")
    fraud = fixture_vector("fraud")

    legit_n = Rinha.NeuralScorer.score(legit)
    fraud_n = Rinha.NeuralScorer.score(fraud)

    assert legit_n in 0..2
    assert fraud_n in 3..5
    assert fraud_n > legit_n
  end

  test "borderline fixture returns a valid fraud count" do
    border = fixture_vector("borderline")
    n = Rinha.NeuralScorer.score(border)
    assert n in 0..5
  end

  defp fixture_vector(name) do
    path = Path.join([:code.priv_dir(:rinha), "resources", "fixtures", "#{name}.json"])

    path
    |> File.read!()
    |> Jason.decode!()
    |> Rinha.VectorTransformerV2.transform()
  end
end

defmodule Rinha.ScoringExampleTest do
  use ExUnit.Case, async: false

  setup_all do
    :ok = Rinha.Domain.Bootstrap.ensure_reference_dataset!()
    Rinha.Domain.ReferenceData.load!()
    :ok = Rinha.Domain.Index.build!()
    :ok
  end

  test "official legit payload stays approved" do
    payload = example_payload("tx-1329056812")

    response =
      payload
      |> Rinha.Domain.Fraud.response_for_payload()
      |> Jason.decode!()

    assert response["approved"] == true
    assert response["fraud_score"] < 0.6
  end

  test "official fraud payload stays denied" do
    payload = example_payload("tx-3330991687")

    response =
      payload
      |> Rinha.Domain.Fraud.response_for_payload()
      |> Jason.decode!()

    assert response["approved"] == false
    assert response["fraud_score"] >= 0.6
  end

  defp example_payload(id) do
    "resources/example-payloads.json"
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
    |> Enum.find(fn payload -> payload["id"] == id end)
    |> case do
      nil -> raise "payload #{id} not found in example-payloads.json"
      payload -> payload
    end
  end
end

defmodule Rinha.ScoringExampleTest do
  use ExUnit.Case, async: false

  setup_all do
    Rinha.Domain.ReferenceData.load!()
    :ok = Rinha.AxonStore.build()
    :ok
  end

  test "official legit payload returns a valid decision" do
    payload = example_payload("tx-1329056812")

    response =
      payload
      |> Rinha.Domain.Fraud.response_for_payload()
      |> Jason.decode!()

    assert is_boolean(response["approved"])
    assert is_number(response["fraud_score"])
  end

  test "official fraud payload returns a valid decision" do
    payload = example_payload("tx-3330991687")

    response =
      payload
      |> Rinha.Domain.Fraud.response_for_payload()
      |> Jason.decode!()

    assert is_boolean(response["approved"])
    assert is_number(response["fraud_score"])
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

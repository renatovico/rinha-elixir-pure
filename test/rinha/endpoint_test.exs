defmodule Rinha.EndpointTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Rinha.Endpoint

  setup do
    prev = :persistent_term.get(:rinha_ready, false)
    on_exit(fn -> :persistent_term.put(:rinha_ready, prev) end)
    :ok
  end

  describe "GET /ready" do
    test "returns 503 when not ready" do
      :persistent_term.put(:rinha_ready, false)

      conn = conn(:get, "/ready") |> Endpoint.call(Endpoint.init([]))
      assert conn.status == 503
    end

    test "returns 200 when ready" do
      :persistent_term.put(:rinha_ready, true)

      conn = conn(:get, "/ready") |> Endpoint.call(Endpoint.init([]))
      assert conn.status == 200
      assert conn.resp_body == "OK"
    end
  end

  describe "POST /fraud-score" do
    test "returns 503 when not ready" do
      :persistent_term.put(:rinha_ready, false)

      payload =
        File.read!(Path.join([:code.priv_dir(:rinha), "resources", "fixtures", "legit.json"]))

      conn =
        conn(:post, "/fraud-score", payload)
        |> put_req_header("content-type", "application/json")
        |> Endpoint.call(Endpoint.init([]))

      assert conn.status == 503
    end

    test "scores a legit transaction when ready" do
      ensure_ready!()

      payload =
        File.read!(Path.join([:code.priv_dir(:rinha), "resources", "fixtures", "legit.json"]))

      conn =
        conn(:post, "/fraud-score", payload)
        |> put_req_header("content-type", "application/json")
        |> Endpoint.call(Endpoint.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["approved"] == true
      assert is_number(body["fraud_score"])
    end

    test "denies a fraud transaction when ready" do
      ensure_ready!()

      payload =
        File.read!(Path.join([:code.priv_dir(:rinha), "resources", "fixtures", "fraud.json"]))

      conn =
        conn(:post, "/fraud-score", payload)
        |> put_req_header("content-type", "application/json")
        |> Endpoint.call(Endpoint.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["approved"] == false
      assert body["fraud_score"] >= 0.6
    end
  end

  defp ensure_ready! do
    unless :persistent_term.get(:rinha_ready, false) do
      Rinha.Resources.load!()
      Rinha.KnnStore.build()
      :persistent_term.put(:rinha_ready, true)
    end
  end
end

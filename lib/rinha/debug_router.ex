defmodule Rinha.DebugRouter do
  @moduledoc """
  Dev/test-only debugging endpoints.

  Mounted under `/debug` from `Rinha.Endpoint` only when `Mix.env()` is not
  `:prod` so it adds zero overhead to the production hot path.

  ## Routes

    * `GET  /debug/ready`              — liveness/readiness flag
    * `GET  /debug/fixtures`           — list bundled fixtures
    * `GET  /debug/fixtures/:name`     — score a bundled fixture
    * `POST /debug/score`              — score an arbitrary payload (echoes vector + n)
    * `POST /debug/simulate`           — generate + run N synthetic payloads,
                                        return aggregated stats

  Bodies are JSON. Responses are JSON. Latencies are reported in microseconds.
  """

  use Plug.Router

  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :dispatch

  get "/ready" do
    ok = :persistent_term.get(:rinha_ready, false)
    json(conn, if(ok, do: 200, else: 503), %{ready: ok})
  end

  get "/profile" do
    summary = Rinha.Profiler.summary()
    json(conn, 200, summary)
  end

  post "/profile/reset" do
    Rinha.Profiler.reset()
    json(conn, 200, %{ok: true})
  end

  get "/fixtures" do
    dir = Path.join(:code.priv_dir(:rinha), "fixtures")

    names =
      case File.ls(dir) do
        {:ok, files} -> files |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.map(&Path.rootname/1)
        _ -> []
      end

    json(conn, 200, %{fixtures: names})
  end

  get "/fixtures/:name" do
    path = Path.join([:code.priv_dir(:rinha), "fixtures", "#{name}.json"])

    if File.exists?(path) do
      payload = path |> File.read!() |> Jason.decode!()
      score_payload(conn, payload, name)
    else
      json(conn, 404, %{error: "fixture not found", name: name})
    end
  end

  post "/score" do
    case conn.body_params do
      payload when is_map(payload) and map_size(payload) > 0 ->
        score_payload(conn, payload, nil)

      _ ->
        json(conn, 400, %{error: "expected JSON object body"})
    end
  end

  post "/simulate" do
    params = conn.body_params || %{}
    count = params["count"] |> to_int(1_000)
    fraud_bias = params["fraud_bias"] |> to_float(0.33)
    warmup = params["warmup"] |> to_int(min(100, div(count, 10)))

    seed_opts =
      case params["seed"] do
        s when is_integer(s) -> [seed: {s, s + 1, s + 2}]
        _ -> []
      end

    opts = [fraud_bias: fraud_bias, warmup: warmup] ++ seed_opts

    t0 = System.monotonic_time(:microsecond)
    stats = Rinha.FraudSimulator.run(count, opts)
    elapsed = System.monotonic_time(:microsecond) - t0

    body =
      stats
      |> Map.put(:wall_us, elapsed)
      |> Map.put(:throughput_per_sec, throughput(count, elapsed))
      |> Map.put(:params, %{count: count, fraud_bias: fraud_bias, warmup: warmup})

    json(conn, 200, body)
  end

  match _ do
    json(conn, 404, %{error: "not found", path: conn.request_path})
  end

  # ---- helpers ----

  defp score_payload(conn, payload, fixture_name) do
    t0 = System.monotonic_time(:microsecond)
    vector = Rinha.VectorTransformerV2.transform(payload)
    t1 = System.monotonic_time(:microsecond)
    n = Rinha.IvfScanner.score(vector)
    t2 = System.monotonic_time(:microsecond)

    response = Rinha.FraudScorer.response_for(n)

    json(conn, 200, %{
      fixture: fixture_name,
      n: n,
      vector: vector,
      response: Jason.decode!(response),
      latency_us: %{
        transform: t1 - t0,
        knn: t2 - t1,
        total: t2 - t0
      }
    })
  end

  defp throughput(_count, 0), do: 0.0
  defp throughput(count, elapsed_us), do: Float.round(count * 1_000_000 / elapsed_us, 2)

  defp to_int(nil, default), do: default
  defp to_int(v, _) when is_integer(v), do: v
  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end
  defp to_int(_, default), do: default

  defp to_float(nil, default), do: default
  defp to_float(v, _) when is_float(v), do: v
  defp to_float(v, _) when is_integer(v), do: v * 1.0
  defp to_float(v, default) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end
  defp to_float(_, default), do: default

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end

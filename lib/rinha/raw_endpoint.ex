defmodule Rinha.RawEndpoint do
  @moduledoc """
  Hot-path Plug for `POST /fraud-score`.

  Sits in front of `Phoenix.Router` to bypass router/controller machinery.
  Uses OTP 27+'s built-in `:json.decode/1` (faster than Jason) and writes
  the precomputed JSON response directly via `Plug.Conn.send_resp/3`.

  Falls through to the next plug for any other method/path.
  """

  @behaviour Plug
  import Plug.Conn

  @json_ct {"content-type", "application/json"}
  @ready_503 ~s({"error":"warming up"})
  @remote_timeout 1_800

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["fraud-score"]} = conn, _opts) do
    if :persistent_term.get(:rinha_ready, false) do
      {:ok, body, conn} = read_body(conn)
      payload = decode!(body)

      response = score_response(payload)

      conn
      |> put_resp_header_fast(@json_ct)
      |> send_resp(200, response)
      |> halt()
    else
      conn
      |> put_resp_header_fast(@json_ct)
      |> send_resp(503, @ready_503)
      |> halt()
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: ["ready"]} = conn, _opts) do
    {status, body} =
      if :persistent_term.get(:rinha_ready, false), do: {200, "OK"}, else: {503, "NOT READY"}

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end

  def call(conn, _opts), do: conn

  @compile {:inline, decode!: 1, put_resp_header_fast: 2, denull: 1, local_score: 1}

  def remote_score(payload), do: local_score(payload)
  def remote_ready?, do: :persistent_term.get(:rinha_ready, false)

  def remote_cluster_status do
    %{
      node: Atom.to_string(Node.self()),
      ready: :persistent_term.get(:rinha_ready, false),
      connected_nodes: Enum.map(Node.list(), &Atom.to_string/1),
      configured_peer: configured_peer_string()
    }
  end

  defp score_response(payload) do
    case remote_peer() do
      nil ->
        local_score(payload)

      peer ->
        case :erpc.call(peer, __MODULE__, :remote_score, [payload], @remote_timeout) do
          response when is_binary(response) -> response
          _ -> local_score(payload)
        end
    end
  end

  defp remote_peer do
    case Rinha.ClusterConnector.peer_node() do
      nil -> nil
      peer -> if route_remote?(), do: peer, else: nil
    end
  end

  defp route_remote? do
    counter = :persistent_term.get(:cluster_rr_counter)
    rem(:atomics.add_get(counter, 1, 1), 2) == 0
  end

  defp local_score(payload) do
    vector = Rinha.VectorTransformerV2.transform(payload)
    n = Rinha.HybridScorer.score(vector)
    Rinha.FraudScorer.response_for(n)
  end

  if Code.ensure_loaded?(:json) and function_exported?(:json, :decode, 1) do
    # OTP 27+ decodes JSON `null` as the atom `:null`. Normalize to `nil`
    # so downstream code (and tests written against Jason) Just Works.
    defp decode!(body), do: body |> :json.decode() |> denull()
  else
    defp decode!(body), do: Jason.decode!(body)
  end

  defp denull(:null), do: nil
  defp denull(map) when is_map(map), do: :maps.map(fn _, v -> denull(v) end, map)
  defp denull(list) when is_list(list), do: Enum.map(list, &denull/1)
  defp denull(other), do: other

  defp put_resp_header_fast(conn, {key, val}) do
    %{conn | resp_headers: [{key, val} | conn.resp_headers]}
  end

  defp configured_peer_string do
    case Rinha.ClusterConnector.peer_node() do
      nil -> nil
      peer -> Atom.to_string(peer)
    end
  end
end

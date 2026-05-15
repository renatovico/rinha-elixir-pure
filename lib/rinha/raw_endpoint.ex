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

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["fraud-score"]} = conn, _opts) do
    if :persistent_term.get(:rinha_ready, false) do
      {:ok, body, conn} = read_body(conn)
      payload = decode!(body)

      vector = Rinha.VectorTransformerV2.transform(payload)
      n = Rinha.IvfScanner.score_adaptive(vector)
      response = Rinha.FraudScorer.response_for(n)

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

  @compile {:inline, decode!: 1, put_resp_header_fast: 2, denull: 1}

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
end

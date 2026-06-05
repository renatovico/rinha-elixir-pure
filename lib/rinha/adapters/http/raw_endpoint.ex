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
  @bad_json_400 ~s({"error":"invalid json"})

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["fraud-score"]} = conn, _opts) do
    if Rinha.Domain.Readiness.ready?() do
      {:ok, body, conn} = read_body(conn)

      case score_response_binary(body) do
        {:ok, response} ->
          conn
          |> put_resp_header_fast(@json_ct)
          |> send_resp(200, response)
          |> halt()

        {:error, :bad_json} ->
          conn
          |> put_resp_header_fast(@json_ct)
          |> send_resp(400, @bad_json_400)
          |> halt()
      end
    else
      conn
      |> put_resp_header_fast(@json_ct)
      |> send_resp(503, @ready_503)
      |> halt()
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: ["ready"]} = conn, _opts) do
    {status, body} = if Rinha.Domain.Readiness.ready?(), do: {200, "OK"}, else: {503, "NOT READY"}

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end

  def call(conn, _opts), do: conn

  @compile {:inline, put_resp_header_fast: 2, local_score: 1}

  defp score_response_binary(body) do
    case decode_payload(body) do
      {:ok, payload} -> {:ok, local_score(payload)}
      {:error, :bad_json} -> {:error, :bad_json}
    end
  end

  defp local_score(payload) do
    Rinha.Domain.Fraud.response_for_payload(payload)
  end

  if Code.ensure_loaded?(:json) and function_exported?(:json, :decode, 1) do
    defp decode_payload(body) do
      try do
        case :json.decode(body) do
          payload when is_map(payload) -> {:ok, payload}
          _ -> {:error, :bad_json}
        end
      rescue
        _ -> {:error, :bad_json}
      end
    end
  else
    defp decode_payload(body) do
      case Jason.decode(body) do
        {:ok, payload} when is_map(payload) -> {:ok, payload}
        {:error, _} -> {:error, :bad_json}
        _ -> {:error, :bad_json}
      end
    end
  end

  defp put_resp_header_fast(conn, {key, val}) do
    %{conn | resp_headers: [{key, val} | conn.resp_headers]}
  end
end

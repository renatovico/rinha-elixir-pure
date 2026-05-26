defmodule Rinha.LoadBalancerPlug do
  @moduledoc """
  HTTP entrypoint for `RINHA_MODE=lb`.

  Requests are forwarded to API BEAM nodes using Erlang distribution (`:erpc`)
  instead of proxying raw TCP streams.
  """

  @behaviour Plug
  import Plug.Conn

  @json_ct "application/json"
  @rpc_timeout 1_800
  @fraud_err ~s({"error":"upstream unavailable"})

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["fraud-score"]} = conn, _opts) do
    with {:ok, body, conn} <- read_full_body(conn),
         {:ok, payload} <- decode_json(body),
         {:ok, response} <- call_peer(:remote_score, [payload]) do
      conn
      |> put_resp_content_type(@json_ct)
      |> send_resp(200, response)
      |> halt()
    else
      {:error, :bad_json} ->
        conn
        |> put_resp_content_type(@json_ct)
        |> send_resp(400, ~s({"error":"invalid json"}))
        |> halt()

      _ ->
        conn
        |> put_resp_content_type(@json_ct)
        |> send_resp(503, @fraud_err)
        |> halt()
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: ["ready"]} = conn, _opts) do
    case call_peer(:remote_ready?, []) do
      {:ok, true} -> send_resp(conn, 200, "OK")
      _ -> send_resp(conn, 503, "NOT READY")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "Not Found")

  defp read_full_body(conn, acc \\ []) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
      {:more, chunk, conn} -> read_full_body(conn, [chunk | acc])
      {:error, _reason} -> {:error, :read_error}
    end
  end

  defp decode_json(body) do
    Jason.decode(body)
  end

  defp call_peer(fun, args) do
    Rinha.LoadBalancer.ordered_peers()
    |> Enum.reduce_while({:error, :no_peer}, fn peer, _acc ->
      ensure_connected(peer)

      try do
        result = :erpc.call(peer, Rinha.RawEndpoint, fun, args, @rpc_timeout)
        {:halt, {:ok, result}}
      rescue
        _ -> {:cont, {:error, :rpc_failed}}
      catch
        :exit, _ -> {:cont, {:error, :rpc_failed}}
      end
    end)
  end

  defp ensure_connected(peer) do
    if peer in Node.list(), do: :ok, else: _ = Node.connect(peer)
    :ok
  end
end

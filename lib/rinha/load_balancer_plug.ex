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

  def call(%Plug.Conn{method: "GET", path_info: ["debug", "cluster"]} = conn, _opts) do
    peers = Rinha.LoadBalancer.peer_nodes() |> Enum.map(&Atom.to_string/1)
    connected = Node.list() |> Enum.map(&Atom.to_string/1)

    remotes =
      Rinha.LoadBalancer.peer_nodes()
      |> Enum.map(fn peer ->
        ensure_connected(peer)

        status =
          case rpc_call(peer, :remote_cluster_status, []) do
            {:ok, map} when is_map(map) -> Map.put(map, :reachable, true)
            _ -> %{reachable: false}
          end

        {Atom.to_string(peer), status}
      end)
      |> Map.new()

    body =
      Jason.encode!(%{
        lb: %{
          node: Atom.to_string(Node.self()),
          connected_nodes: connected,
          configured_peers: peers
        },
        remotes: remotes
      })

    conn
    |> put_resp_content_type(@json_ct)
    |> send_resp(200, body)
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

      case rpc_call(peer, fun, args) do
        {:ok, result} -> {:halt, {:ok, result}}
        {:error, :rpc_failed} -> {:cont, {:error, :rpc_failed}}
      end
    end)
  end

  defp rpc_call(peer, fun, args) do
    try do
      {:ok, :erpc.call(peer, Rinha.RawEndpoint, fun, args, @rpc_timeout)}
    rescue
      _ -> {:error, :rpc_failed}
    catch
      :exit, _ -> {:error, :rpc_failed}
    end
  end

  defp ensure_connected(peer) do
    if peer in Node.list(), do: :ok, else: _ = Node.connect(peer)
    :ok
  end
end

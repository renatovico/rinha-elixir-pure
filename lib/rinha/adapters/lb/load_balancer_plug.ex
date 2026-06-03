defmodule Rinha.LoadBalancerPlug do
  @moduledoc """
  HTTP entrypoint for `RINHA_MODE=lb`.

  Requests are forwarded to API BEAM nodes using Erlang distribution (`:erpc`)
  instead of proxying raw TCP streams.
  """

  @behaviour Plug
  import Plug.Conn

  @json_ct "application/json"
  @default_rpc_timeout_ms 120
  @default_rpc_retry_timeout_ms 120
  @fraud_err ~s({"error":"upstream unavailable"})

  @impl true
  def init(opts) do
    rpc_timeout_ms = env_int("LB_RPC_TIMEOUT_MS", @default_rpc_timeout_ms)
    rpc_retry_timeout_ms = env_int("LB_RPC_RETRY_TIMEOUT_MS", @default_rpc_retry_timeout_ms)

    opts
    |> Keyword.put_new(:rpc_timeout_ms, rpc_timeout_ms)
    |> Keyword.put_new(:rpc_retry_timeout_ms, rpc_retry_timeout_ms)
  end

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["fraud-score"]} = conn, opts) do
    with {:ok, body, conn} <- read_full_body(conn),
         {:ok, response} <- call_peer(:remote_score_binary, [body], opts) do
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

  def call(%Plug.Conn{method: "GET", path_info: ["ready"]} = conn, opts) do
    case call_peer(:remote_ready?, [], opts) do
      {:ok, true} -> send_resp(conn, 200, "OK")
      _ -> send_resp(conn, 503, "NOT READY")
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: ["debug", "cluster"]} = conn, _opts) do
    peers = Rinha.LoadBalancer.peer_nodes() |> Enum.map(&Atom.to_string/1)
    connected = Rinha.Domain.Cluster.connected_nodes()

    remotes =
      Rinha.LoadBalancer.peer_nodes()
      |> Enum.map(fn peer ->
        ensure_connected(peer)

        status =
          case rpc_call(peer, :remote_cluster_status, [], @default_rpc_timeout_ms) do
            {:ok, map} when is_map(map) -> Map.put(map, :reachable, true)
            _ -> %{reachable: false}
          end

        {Atom.to_string(peer), status}
      end)
      |> Map.new()

    body =
      Jason.encode!(%{
        lb: %{
          node: Rinha.Domain.Cluster.self_node(),
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

  defp call_peer(fun, args, opts) do
    timeout_ms = Keyword.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms)
    retry_timeout_ms = Keyword.get(opts, :rpc_retry_timeout_ms, @default_rpc_retry_timeout_ms)

    Rinha.LoadBalancer.ordered_peers()
    |> Enum.with_index()
    |> Enum.reduce_while({:error, :no_peer}, fn {peer, attempt}, _acc ->
      per_attempt_timeout = if attempt == 0, do: timeout_ms, else: retry_timeout_ms

      ensure_connected(peer)

      case rpc_call(peer, fun, args, per_attempt_timeout) do
        {:ok, true} ->
          {:halt, {:ok, true}}

        {:ok, false} ->
          {:cont, {:error, :rpc_failed}}

        {:ok, {:ok, result}} when is_binary(result) ->
          {:halt, {:ok, result}}

        {:ok, {:error, :bad_json}} ->
          {:halt, {:error, :bad_json}}

        {:ok, result} when is_binary(result) ->
          {:halt, {:ok, result}}

        {:error, :rpc_failed} ->
          {:cont, {:error, :rpc_failed}}

        _ ->
          {:cont, {:error, :rpc_failed}}
      end
    end)
  end

  defp rpc_call(peer, fun, args, timeout_ms) do
    try do
      {:ok, :erpc.call(peer, Rinha.RawEndpoint, fun, args, timeout_ms)}
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

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _ -> default
        end
    end
  end
end

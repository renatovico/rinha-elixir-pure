defmodule Rinha.LoadBalancer do
  @moduledoc """
  Round-robin peer selector for Erlang-distribution load balancing.

  In `RINHA_MODE=lb`, HTTP is handled by `Rinha.LoadBalancerPlug`, and each
  request is forwarded to one of the configured API BEAM nodes with `:erpc.call/5`.
  """

  use GenServer

  @default_peer_nodes ["api1@api1", "api2@api2"]

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Returns configured peer nodes in round-robin order for this request."
  def ordered_peers(server \\ __MODULE__), do: GenServer.call(server, :ordered_peers)

  @doc "Returns configured peer nodes."
  def peer_nodes(server \\ __MODULE__), do: GenServer.call(server, :peer_nodes)

  @impl true
  def init(opts) do
    peer_nodes =
      opts
      |> Keyword.get(:peer_nodes, configured_peer_nodes())
      |> Enum.map(&parse_peer_node!/1)

    true = length(peer_nodes) > 0

    peers = List.to_tuple(peer_nodes)
    counter = :atomics.new(1, signed: false)

    {:ok, %{peers: peers, counter: counter}}
  end

  @impl true
  def handle_call(:peer_nodes, _from, state) do
    {:reply, Tuple.to_list(state.peers), state}
  end

  @impl true
  def handle_call(:ordered_peers, _from, state) do
    size = tuple_size(state.peers)
    start_idx = rem(:atomics.add_get(state.counter, 1, 1) - 1, size)

    ordered =
      0..(size - 1)
      |> Enum.map(fn step -> elem(state.peers, rem(start_idx + step, size)) end)

    {:reply, ordered, state}
  end

  defp configured_peer_nodes do
    case System.get_env("LB_PEER_NODES") do
      nil -> Application.get_env(:rinha, :lb_peer_nodes, @default_peer_nodes)
      value -> String.split(value, ",", trim: true)
    end
  end

  defp parse_peer_node!(entry) when is_atom(entry), do: entry

  defp parse_peer_node!(entry) when is_binary(entry) do
    if String.contains?(entry, "@") do
      String.to_atom(entry)
    else
      raise ArgumentError, "invalid LB peer node: #{inspect(entry)}"
    end
  end
end

defmodule Rinha.LoadBalancer do
  @moduledoc """
  Round-robin peer selector for Erlang-distribution load balancing.

  In `RINHA_MODE=lb`, HTTP is handled by `Rinha.LoadBalancerPlug`, and each
  request is forwarded to one of the configured API BEAM nodes with `:erpc.call/5`.
  """

  use GenServer

  @default_peer_nodes ["api1@api1", "api2@api2"]
  @fast_state_key {:rinha, :lb_fast_state}

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Returns configured peer nodes in round-robin order for this request."
  def ordered_peers(server \\ __MODULE__)

  def ordered_peers(__MODULE__) do
    owner = Process.whereis(__MODULE__)

    case :persistent_term.get(@fast_state_key, nil) do
      %{owner: ^owner, peers: peers, counter: counter} ->
        ordered_from_tuple(peers, counter)

      _ ->
        GenServer.call(__MODULE__, :ordered_peers)
    end
  end

  def ordered_peers(server), do: GenServer.call(server, :ordered_peers)

  @doc "Returns configured peer nodes."
  def peer_nodes(server \\ __MODULE__)

  def peer_nodes(__MODULE__) do
    owner = Process.whereis(__MODULE__)

    case :persistent_term.get(@fast_state_key, nil) do
      %{owner: ^owner, peers: peers} ->
        Tuple.to_list(peers)

      _ ->
        GenServer.call(__MODULE__, :peer_nodes)
    end
  end

  def peer_nodes(server), do: GenServer.call(server, :peer_nodes)

  @impl true
  def init(opts) do
    peer_nodes =
      opts
      |> Keyword.get(:peer_nodes, configured_peer_nodes())
      |> Enum.map(&parse_peer_node!/1)

    true = length(peer_nodes) > 0

    peers = List.to_tuple(peer_nodes)
    counter = :atomics.new(1, signed: false)
    state = %{owner: self(), peers: peers, counter: counter}

    maybe_put_fast_state(state)

    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    maybe_clear_fast_state()
    :ok
  end

  @impl true
  def handle_call(:peer_nodes, _from, state) do
    {:reply, Tuple.to_list(state.peers), state}
  end

  @impl true
  def handle_call(:ordered_peers, _from, state) do
    {:reply, ordered_from_tuple(state.peers, state.counter), state}
  end

  defp ordered_from_tuple(peers, counter) do
    size = tuple_size(peers)
    start_idx = rem(:atomics.add_get(counter, 1, 1) - 1, size)

    0..(size - 1)
    |> Enum.map(fn step -> elem(peers, rem(start_idx + step, size)) end)
  end

  defp maybe_put_fast_state(state) do
    if Process.whereis(__MODULE__) == self() do
      :persistent_term.put(@fast_state_key, state)
    end
  end

  defp maybe_clear_fast_state do
    if Process.whereis(__MODULE__) == self() do
      :persistent_term.erase(@fast_state_key)
    end
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

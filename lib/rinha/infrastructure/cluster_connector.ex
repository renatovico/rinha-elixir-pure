defmodule Rinha.ClusterConnector do
  @moduledoc """
  Joins the two API BEAMs into a small Erlang cluster so each node can
  ask the other to scan its half of the reference set.

  Configuration (env vars, applied in `runtime.exs`):

    * `RINHA_PEER_NODE` — fully-qualified name of the peer node, e.g.
      `api2@api2`.  When unset the connector is a no-op (standalone).

  Discovery loop:

    1. `Node.connect(peer)` every `@interval_ms`.
    2. Track up/down via `:net_kernel.monitor_nodes(true)`.
    3. Stash the peer node atom in `:persistent_term` so the hot path
       can read it with no process hop.
  """

  use GenServer
  require Logger

  @interval_ms 1_000
  @peer_key {:rinha, :peer_node}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Returns the peer node atom (when up), or nil."
  def peer_node, do: :persistent_term.get(@peer_key, nil)

  @impl true
  def init(:ok) do
    peer = configured_peer()
    :net_kernel.monitor_nodes(true)

    if peer do
      Logger.info("ClusterConnector: peer=#{peer}")
      send(self(), :tick)
    else
      Logger.info("ClusterConnector: no RINHA_PEER_NODE set, standalone")
    end

    {:ok, %{peer: peer}}
  end

  @impl true
  def handle_info(:tick, %{peer: nil} = state), do: {:noreply, state}

  def handle_info(:tick, %{peer: peer} = state) do
    if peer in Node.list() do
      :persistent_term.put(@peer_key, peer)
    else
      case Node.connect(peer) do
        true ->
          Logger.info("ClusterConnector: connected to #{peer}")
          :persistent_term.put(@peer_key, peer)

        _ ->
          :persistent_term.put(@peer_key, nil)
      end
    end

    Process.send_after(self(), :tick, @interval_ms)
    {:noreply, state}
  end

  def handle_info({:nodeup, n}, state) do
    Logger.info("ClusterConnector: nodeup #{n}")
    if n == state.peer, do: :persistent_term.put(@peer_key, n)
    {:noreply, state}
  end

  def handle_info({:nodedown, n}, state) do
    Logger.warning("ClusterConnector: nodedown #{n}")
    if n == state.peer, do: :persistent_term.put(@peer_key, nil)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp configured_peer do
    case System.get_env("RINHA_PEER_NODE") do
      nil -> nil
      "" -> nil
      n -> String.to_atom(n)
    end
  end
end

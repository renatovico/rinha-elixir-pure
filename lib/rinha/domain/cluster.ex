defmodule Rinha.Domain.Cluster do
  @moduledoc """
  Domain facade for cluster/distribution introspection.
  """

  @spec connected_nodes() :: [String.t()]
  def connected_nodes, do: Enum.map(Node.list(), &Atom.to_string/1)

  @spec self_node() :: String.t()
  def self_node, do: Atom.to_string(Node.self())

  @spec configured_peer() :: String.t() | nil
  def configured_peer do
    case Rinha.ClusterConnector.peer_node() do
      nil -> nil
      peer -> Atom.to_string(peer)
    end
  end

  @spec status_snapshot() :: map()
  def status_snapshot do
    %{
      node: self_node(),
      ready: Rinha.Domain.Readiness.ready?(),
      connected_nodes: connected_nodes(),
      configured_peer: configured_peer()
    }
  end
end

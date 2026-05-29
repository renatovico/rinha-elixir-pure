defmodule Rinha.LoadBalancerTest do
  use ExUnit.Case, async: false

  test "returns peers in round-robin order" do
    {:ok, lb} =
      Rinha.LoadBalancer.start_link(
        peer_nodes: ["api1@api1", "api2@api2", "api3@api3"],
        name: nil
      )

    assert Rinha.LoadBalancer.ordered_peers(lb) == [:api1@api1, :api2@api2, :api3@api3]
    assert Rinha.LoadBalancer.ordered_peers(lb) == [:api2@api2, :api3@api3, :api1@api1]
    assert Rinha.LoadBalancer.ordered_peers(lb) == [:api3@api3, :api1@api1, :api2@api2]

    GenServer.stop(lb)
  end
end

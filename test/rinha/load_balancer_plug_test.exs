defmodule Rinha.LoadBalancerPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test

  setup do
    original_lb = Process.whereis(Rinha.LoadBalancer)
    if original_lb, do: GenServer.stop(original_lb)

    {:ok, lb} = Rinha.LoadBalancer.start_link(peer_nodes: ["missing1@host", "missing2@host"])

    on_exit(fn ->
      if Process.alive?(lb), do: GenServer.stop(lb)
      if original_lb, do: {:ok, _} = Rinha.LoadBalancer.start_link(name: Rinha.LoadBalancer)
    end)

    :ok
  end

  test "GET /debug/cluster returns diagnostics even with unreachable peers" do
    conn = conn(:get, "/debug/cluster") |> Rinha.LoadBalancerPlug.call([])

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["lb"]["configured_peers"] == ["missing1@host", "missing2@host"]
    assert body["remotes"]["missing1@host"]["reachable"] == false
    assert body["remotes"]["missing2@host"]["reachable"] == false
  end
end

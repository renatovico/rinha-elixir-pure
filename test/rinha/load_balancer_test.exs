defmodule Rinha.LoadBalancerTest do
  use ExUnit.Case, async: false

  test "proxies connections round-robin to unix socket backends" do
    base = System.unique_integer([:positive])
    paths = ["/tmp/rinha-lb-#{base}-1.sock", "/tmp/rinha-lb-#{base}-2.sock"]
    Enum.each(paths, &File.rm/1)

    servers =
      Enum.map(Enum.with_index(paths, 1), fn {path, idx} ->
        start_echo_server(path, "backend-#{idx}")
      end)

    {:ok, lb} = Rinha.LoadBalancer.start_link(port: 0, upstreams: paths, acceptors: 1, name: nil)
    port = Rinha.LoadBalancer.port(lb)

    responses = for _ <- 1..4, do: request(port, "ping")

    assert responses == ["backend-1:ping", "backend-2:ping", "backend-1:ping", "backend-2:ping"]

    GenServer.stop(lb)
    Enum.each(servers, &Process.exit(&1, :kill))
    Enum.each(paths, &File.rm/1)
  end

  defp start_echo_server(path, prefix) do
    parent = self()

    spawn(fn ->
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ifaddr: {:local, path}])

      send(parent, {:ready, self()})
      echo_loop(listen, prefix)
    end)
    |> tap(fn pid ->
      receive do
        {:ready, ^pid} -> :ok
      after
        1_000 -> flunk("echo server did not start")
      end
    end)
  end

  defp echo_loop(listen, prefix) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
    :ok = :gen_tcp.send(socket, prefix <> ":" <> data)
    :gen_tcp.close(socket)
    echo_loop(listen, prefix)
  end

  defp request(port, data) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false], 1_000)

    :ok = :gen_tcp.send(socket, data)
    {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    :gen_tcp.close(socket)
    response
  end
end

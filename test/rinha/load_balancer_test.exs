defmodule Rinha.LoadBalancerTest do
  use ExUnit.Case, async: false

  test "proxies connections round-robin to tcp backends" do
    {:ok, backend1} = start_echo_server("backend-1")
    {:ok, backend2} = start_echo_server("backend-2")

    upstreams = ["127.0.0.1:#{backend1.port}", "127.0.0.1:#{backend2.port}"]

    {:ok, lb} = Rinha.LoadBalancer.start_link(port: 0, upstreams: upstreams, acceptors: 1, name: nil)
    lb_port = Rinha.LoadBalancer.port(lb)

    responses = for _ <- 1..4, do: request(lb_port, "ping")

    assert responses == ["backend-1:ping", "backend-2:ping", "backend-1:ping", "backend-2:ping"]

    GenServer.stop(lb)
    stop_echo_server(backend1)
    stop_echo_server(backend2)
  end

  defp start_echo_server(prefix) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listen)
        send(parent, {:ready, self(), listen, port})
        echo_loop(listen, prefix)
      end)

    receive do
      {:ready, ^pid, listen, port} -> {:ok, %{pid: pid, listen: listen, port: port}}
    after
      1_000 -> flunk("echo server did not start")
    end
  end

  defp stop_echo_server(%{pid: pid, listen: listen}) do
    :gen_tcp.close(listen)
    Process.exit(pid, :kill)
    :ok
  end

  defp echo_loop(listen, prefix) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, prefix <> ":" <> data)
        :gen_tcp.close(socket)
        echo_loop(listen, prefix)

      {:error, :closed} ->
        :ok
    end
  end

  defp request(port, data) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false], 1_000)
    :ok = :gen_tcp.send(socket, data)
    {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    :gen_tcp.close(socket)
    response
  end
end

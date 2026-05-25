defmodule Rinha.LoadBalancer do
  @moduledoc """
  Tiny TCP stream load balancer for API backends.

  It does not parse HTTP. Each accepted client connection is proxied byte-for-byte
  to a backend TCP endpoint selected by round-robin.
  """

  use GenServer
  require Logger

  @default_port 9999
  @default_upstreams ["api1:4000", "api2:4000"]
  @connect_timeout 1_000

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, configured_port())
    upstreams = Keyword.get(opts, :upstreams, configured_upstreams())
    acceptors = Keyword.get(opts, :acceptors, configured_acceptors())

    true = length(upstreams) > 0

    parsed_upstreams = Enum.map(upstreams, &parse_upstream!/1) |> List.to_tuple()

    {:ok, listen} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        nodelay: true,
        backlog: 4096,
        ip: {0, 0, 0, 0}
      ])

    {:ok, actual_port} = :inet.port(listen)
    counter = :atomics.new(1, signed: false)

    for _ <- 1..acceptors do
      spawn_link(fn -> accept_loop(listen, parsed_upstreams, counter) end)
    end

    Logger.info("LoadBalancer listening on :#{actual_port} upstreams=#{inspect(upstreams)}")

    {:ok, %{listen: listen, port: actual_port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  defp accept_loop(listen, upstreams, counter) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        handoff(client, upstreams, counter)
        accept_loop(listen, upstreams, counter)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("LoadBalancer accept failed: #{inspect(reason)}")
        accept_loop(listen, upstreams, counter)
    end
  end

  defp handoff(client, upstreams, counter) do
    proxy =
      spawn(fn ->
        receive do
          :go -> proxy(client, upstreams, counter)
        after
          1_000 -> :gen_tcp.close(client)
        end
      end)

    case :gen_tcp.controlling_process(client, proxy) do
      :ok -> send(proxy, :go)
      {:error, _reason} -> :gen_tcp.close(client)
    end
  end

  defp proxy(client, upstreams, counter) do
    case connect_upstream(upstreams, counter) do
      {:ok, upstream} -> bridge(client, upstream)
      {:error, _reason} -> :gen_tcp.close(client)
    end
  end

  defp connect_upstream(upstreams, counter) do
    size = tuple_size(upstreams)
    start_idx = rem(:atomics.add_get(counter, 1, 1) - 1, size)
    connect_attempt(upstreams, start_idx, 0)
  end

  defp connect_attempt(upstreams, _start_idx, attempts) when attempts >= tuple_size(upstreams) do
    {:error, :all_upstreams_failed}
  end

  defp connect_attempt(upstreams, start_idx, attempts) do
    idx = rem(start_idx + attempts, tuple_size(upstreams))
    {host, port} = elem(upstreams, idx)

    case :gen_tcp.connect(host, port, [:binary, packet: :raw, active: false, nodelay: true], @connect_timeout) do
      {:ok, socket} -> {:ok, socket}
      {:error, _reason} -> connect_attempt(upstreams, start_idx, attempts + 1)
    end
  end

  defp bridge(client, upstream) do
    parent = self()

    client_to_upstream = spawn(fn -> wait_and_pump(client, upstream, parent) end)
    upstream_to_client = spawn(fn -> wait_and_pump(upstream, client, parent) end)

    with :ok <- :gen_tcp.controlling_process(client, client_to_upstream),
         :ok <- :gen_tcp.controlling_process(upstream, upstream_to_client) do
      send(client_to_upstream, :go)
      send(upstream_to_client, :go)

      receive do
        {:done, _pid} -> :ok
      end
    end

    :gen_tcp.close(client)
    :gen_tcp.close(upstream)
    Process.exit(client_to_upstream, :kill)
    Process.exit(upstream_to_client, :kill)
  end

  defp wait_and_pump(from, to, parent) do
    receive do
      :go -> pump(from, to, parent)
    after
      1_000 -> send(parent, {:done, self()})
    end
  end

  defp pump(from, to, parent) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        case :gen_tcp.send(to, data) do
          :ok -> pump(from, to, parent)
          {:error, _reason} -> send(parent, {:done, self()})
        end

      {:error, _reason} ->
        send(parent, {:done, self()})
    end
  end

  defp configured_port do
    case System.get_env("LB_PORT") do
      nil -> Application.get_env(:rinha, :lb_port, @default_port)
      value -> String.to_integer(value)
    end
  end

  defp configured_upstreams do
    case System.get_env("LB_UPSTREAMS") do
      nil -> Application.get_env(:rinha, :lb_upstreams, @default_upstreams)
      value -> String.split(value, ",", trim: true)
    end
  end

  defp configured_acceptors do
    case System.get_env("LB_ACCEPTORS") do
      nil -> max(System.schedulers_online() * 4, 8)
      value -> String.to_integer(value)
    end
  end

  defp parse_upstream!(entry) do
    case String.split(entry, ":", parts: 2) do
      [host, port] ->
        {String.to_charlist(host), String.to_integer(port)}

      _ ->
        raise ArgumentError, "invalid LB upstream: #{inspect(entry)}"
    end
  end
end

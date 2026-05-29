defmodule Rinha.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Rinha application...")

    if System.get_env("RINHA_MODE") == "lb" do
      start_load_balancer()
    else
      start_api()
    end
  end

  defp start_api do
    :ok = Rinha.Domain.Bootstrap.boot_api!()

    children =
      [
        Rinha.Profiler,
        Rinha.ClusterConnector,
        Rinha.Endpoint
      ] ++ unix_socket_child()

    case Supervisor.start_link(children, strategy: :one_for_one, name: Rinha.Supervisor) do
      {:ok, _sup} = ok ->
        Rinha.Domain.Readiness.mark_ready!()

        write_ready_file()
        Logger.info("Ready!")

        ok

      err ->
        err
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    Rinha.Endpoint.config_change(changed, removed)
    :ok
  end

  defp write_ready_file do
    ready_file = System.get_env("READY_FILE", "/tmp/ready")
    File.write!(ready_file, "ok")
  end

  defp start_load_balancer do
    lb_port =
      case System.get_env("LB_PORT") do
        nil -> 9999
        value -> String.to_integer(value)
      end

    lb_acceptors =
      case System.get_env("LB_ACCEPTORS") do
        nil -> max(System.schedulers_online() * 4, 8)
        value -> String.to_integer(value)
      end

    children = [
      Rinha.LoadBalancer,
      {Plug.Cowboy,
       scheme: :http,
       plug: Rinha.LoadBalancerPlug,
       options: [
         ip: {0, 0, 0, 0},
         port: lb_port,
         transport_options: [
           num_acceptors: lb_acceptors,
           max_connections: 16_384,
           socket_opts: [
             {:nodelay, true},
             {:backlog, 4096}
           ]
         ],
         protocol_options: [
           idle_timeout: 60_000,
           max_keepalive: 10_000,
           request_timeout: 5_000
         ]
       ]}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: Rinha.Supervisor) do
      {:ok, _sup} = ok ->
        write_ready_file()
        Logger.info("Load balancer ready on :#{lb_port} (Erlang distribution mode)")
        ok

      err ->
        err
    end
  end

  defp unix_socket_child do
    case Application.get_env(:rinha, :socket_path) do
      nil ->
        []

      "" ->
        []

      socket_path ->
        _ = File.rm(socket_path)
        _ = File.mkdir_p(Path.dirname(socket_path))

        Logger.info("Also listening on UNIX socket #{socket_path}")

        [
          {Plug.Cowboy,
           scheme: :http,
           plug: Rinha.Endpoint,
           options: [
             ref: Rinha.Endpoint.UnixSocket,
             port: 0,
             transport_options: [
               socket_opts: [{:ifaddr, {:local, socket_path}}],
               num_acceptors: 100
             ]
           ]}
        ]
    end
  end
end

defmodule Rinha.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Rinha application...")

    Rinha.Resources.load!()

    :persistent_term.put(:prof_counter, :atomics.new(1, signed: false))

    Logger.info("Loading IVF index...")
    :ok = Rinha.IvfStore.build()

    Logger.info("Warming up scoring with bundled fixtures...")
    warmup()

    children =
      [
        Rinha.Profiler,
        Rinha.ClusterConnector,
        Rinha.Endpoint
      ] ++ unix_socket_child()

    case Supervisor.start_link(children, strategy: :one_for_one, name: Rinha.Supervisor) do
      {:ok, _sup} = ok ->
        :persistent_term.put(:rinha_ready, true)

        ready_file = System.get_env("READY_FILE", "/tmp/ready")
        File.write!(ready_file, "ok")
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

  defp warmup do
    fixtures_dir = Path.join(:code.priv_dir(:rinha), "fixtures")

    if File.dir?(fixtures_dir) do
      for name <- ~w(legit fraud borderline) do
        path = Path.join(fixtures_dir, "#{name}.json")

        if File.exists?(path) do
          payload = path |> File.read!() |> Jason.decode!()
          vector = Rinha.VectorTransformerV2.transform(payload)
          _ = Rinha.IvfScanner.score(vector)
        end
      end
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

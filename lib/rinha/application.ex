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
    Rinha.Resources.load!()

    :persistent_term.put(:prof_counter, :atomics.new(1, signed: false))
    :persistent_term.put(:cluster_rr_counter, :atomics.new(1, signed: false))
    :ok = Rinha.BloomFilter.init()

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

  defp warmup do
    fixtures_dir = Path.join([:code.priv_dir(:rinha), "resources", "fixtures"])

    fixture_vectors =
      if File.dir?(fixtures_dir) do
        for name <- ~w(legit fraud borderline),
            path = Path.join(fixtures_dir, "#{name}.json"),
            File.exists?(path) do
          path
          |> File.read!()
          |> Jason.decode!()
          |> Rinha.VectorTransformerV2.transform()
        end
      else
        []
      end

    synthetic = synthetic_warmup_vectors(200)

    vectors = fixture_vectors ++ synthetic

    Enum.each(vectors, fn v ->
      _ = Rinha.NeuralScorer.score(v)
    end)

    require Logger
    Logger.info("Warmup done (#{length(vectors)} queries)")
  end

  defp synthetic_warmup_vectors(count) do
    1..count
    |> Enum.map(fn _ ->
      {_shape, payload} = Rinha.FraudSimulator.generate()
      Rinha.VectorTransformerV2.transform(payload)
    end)
  end

  defp write_ready_file do
    ready_file = System.get_env("READY_FILE", "/tmp/ready")
    File.write!(ready_file, "ok")
  end

  defp start_load_balancer do
    case Supervisor.start_link([Rinha.LoadBalancer], strategy: :one_for_one, name: Rinha.Supervisor) do
      {:ok, _sup} = ok ->
        write_ready_file()
        Logger.info("Load balancer ready!")
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

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

    # Plus 200 synthetic queries derived from real refs in the index
    # (sample one ref from each of 200 buckets, then perturb slightly
    # to avoid trivial top-K hits). This JIT-warms the BEAM, primes
    # caches and pre-allocates atoms / persistent_term shapes for the
    # hot path before we accept traffic.
    synthetic = synthetic_warmup_vectors(200)

    vectors = fixture_vectors ++ synthetic

    Enum.each(vectors, fn v ->
      _ = Rinha.IvfScanner.score_adaptive(v)
    end)

    require Logger
    Logger.info("Warmup done (#{length(vectors)} queries)")
  end

  defp synthetic_warmup_vectors(count) do
    %{vectors: vectors, offsets: offsets, k: k, stride: stride} = Rinha.IvfStore.get()

    step = max(1, div(k, count))

    0..(k - 1)//step
    |> Enum.flat_map(fn cid ->
      case take_one(offsets, cid, vectors, stride) do
        nil -> []
        v -> [v]
      end
    end)
    |> Enum.take(count)
  end

  defp take_one(offsets, cid, vectors, stride) do
    start = elem(offsets, cid)
    stop = elem(offsets, cid + 1)

    if stop > start do
      row_bin = :binary.part(vectors, start * stride * 2, stride * 2)

      for <<v::little-signed-16 <- row_bin>>, do: v
    else
      nil
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

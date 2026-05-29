import Config

if config_env() != :test do
  port = String.to_integer(System.get_env("PORT") || "4000")

  num_acceptors =
    System.get_env("HTTP_ACCEPTORS")
    |> case do
      nil -> max(System.schedulers_online() * 4, 16)
      v -> String.to_integer(v)
    end

  max_connections =
    System.get_env("HTTP_MAX_CONNECTIONS")
    |> case do
      nil -> 16_384
      v -> String.to_integer(v)
    end

  telemetry_log_interval_ms =
    System.get_env("TELEMETRY_LOG_INTERVAL_MS")
    |> case do
      nil -> 10_000
      "0" -> 0
      "off" -> 0
      "OFF" -> 0
      v -> String.to_integer(v)
    end

  knn_probes =
    System.get_env("KNN_PROBES")
    |> case do
      nil -> 12
      "" -> 12
      v -> String.to_integer(v)
    end

  n3_borderline_calibration =
    System.get_env("N3_BORDERLINE_CALIBRATION")
    |> case do
      nil -> true
      "" -> true
      "0" -> false
      "false" -> false
      "FALSE" -> false
      "off" -> false
      "OFF" -> false
      _ -> true
    end

  config :rinha,
    port: port,
    socket_path: System.get_env("SOCKET_PATH"),
    telemetry_log_interval_ms: telemetry_log_interval_ms,
    references_path: System.get_env("REFERENCES_PATH"),
    knn_probes: knn_probes,
    n3_borderline_calibration: n3_borderline_calibration

  # Phoenix Endpoint always listens on the TCP port.
  config :rinha, Rinha.Endpoint,
    http: [
      ip: {0, 0, 0, 0},
      port: port,
      transport_options: [
        num_acceptors: num_acceptors,
        max_connections: max_connections,
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
    ],
    server: true
end

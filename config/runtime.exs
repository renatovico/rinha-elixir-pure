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

  config :rinha,
    port: port,
    socket_path: System.get_env("SOCKET_PATH"),
    references_v2_path:
      System.get_env("REFERENCES_V2_PATH") ||
        Path.join(File.cwd!(), "priv/references_v2.bin")

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


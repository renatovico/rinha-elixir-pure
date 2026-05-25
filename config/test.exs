import Config

config :logger, level: :warning

config :rinha, Rinha.Endpoint,
  http: [port: 4002, transport_options: [num_acceptors: 10]],
  server: false

import Config

config :logger, level: :warning

config :rinha,
  references_v2_path: Path.expand("../priv/references_v2.bin", __DIR__)

config :rinha, Rinha.Endpoint,
  http: [port: 4002, transport_options: [num_acceptors: 10]],
  server: false


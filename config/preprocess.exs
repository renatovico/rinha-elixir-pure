import Config

config :logger, level: :warning
config :nx, default_backend: EXLA.Backend
config :nx, default_defn_options: [compiler: EXLA]

config :rinha, Rinha.Endpoint, server: false

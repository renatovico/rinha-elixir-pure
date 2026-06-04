import Config

config :logger, level: :info

config :nx, default_backend: {EXLA.Backend, client: :host}
config :nx, default_defn_options: [compiler: EXLA]

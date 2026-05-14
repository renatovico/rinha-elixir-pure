import Config

config :rinha,
  port: 4000

config :rinha, Rinha.Endpoint,
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  url: [host: "localhost"],
  render_errors: [formats: [json: Rinha.ErrorJSON], layout: false],
  http: [port: 4000, transport_options: [num_acceptors: 100]],
  server: true

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"

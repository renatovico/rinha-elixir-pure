defmodule Rinha.Endpoint do
  use Phoenix.Endpoint, otp_app: :rinha

  # Tidewave (dev only) — must come before the router.
  if Code.ensure_loaded?(Tidewave) do
    plug Tidewave, team: [id: "voyonit", token: "ifh32un7uogwawim7pys3xnnbyxhnlqrekhtq6y"]
  end

  # Hot-path: bypass router for POST /fraud-score and GET /ready.
  # Reads raw body itself (uses :json), so it must run BEFORE Plug.Parsers.
  plug Rinha.RawEndpoint

  # Debug endpoints — only mounted outside :prod.
  if Mix.env() != :prod do
    plug :debug_dispatch
  end

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug Rinha.Router

  if Mix.env() != :prod do
    defp debug_dispatch(%Plug.Conn{path_info: ["debug" | rest]} = conn, _opts) do
      conn = %{conn | path_info: rest, script_name: conn.script_name ++ ["debug"]}
      Rinha.DebugRouter.call(conn, Rinha.DebugRouter.init([])) |> Plug.Conn.halt()
    end

    defp debug_dispatch(conn, _opts), do: conn
  end
end

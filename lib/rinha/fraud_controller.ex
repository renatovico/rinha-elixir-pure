defmodule Rinha.FraudController do
  @moduledoc """
  Fraud scoring HTTP endpoints. Bypasses Phoenix view layer for speed:
  the scorer returns a pre-encoded JSON string.
  """

  use Phoenix.Controller, formats: [:json]
  import Plug.Conn

  def ready(conn, _params) do
    if :persistent_term.get(:rinha_ready, false) do
      send_resp(conn, 200, "OK")
    else
      send_resp(conn, 503, "NOT READY")
    end
  end

  def score(conn, params) do
    if :persistent_term.get(:rinha_ready, false) do
      response = Rinha.FraudScorer.score(params)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, response)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, ~s({"error":"warming up"}))
    end
  end
end

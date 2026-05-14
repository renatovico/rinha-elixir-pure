defmodule Rinha.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Rinha do
    pipe_through :api

    get "/ready", FraudController, :ready
    post "/fraud-score", FraudController, :score
  end
end

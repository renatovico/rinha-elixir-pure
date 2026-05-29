defmodule Rinha.Domain.Readiness do
  @moduledoc """
  Single source of truth for service readiness state.
  """

  @ready_key :rinha_ready

  @spec ready?() :: boolean()
  def ready?, do: :persistent_term.get(@ready_key, false)

  @spec mark_ready!() :: true
  def mark_ready!, do: :persistent_term.put(@ready_key, true)
end

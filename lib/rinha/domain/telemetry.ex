defmodule Rinha.Domain.Telemetry do
  @moduledoc """
  Domain service for profiling/diagnostic telemetry.
  """

  @behaviour Rinha.Domain.Ports.Telemetry

  @impl true
  def profiler_summary, do: Rinha.Profiler.summary()

  @impl true
  def reset_profiler, do: Rinha.Profiler.reset()

  @impl true
  def throughput(_count, 0), do: 0.0

  def throughput(count, elapsed_us), do: Float.round(count * 1_000_000 / elapsed_us, 2)
end

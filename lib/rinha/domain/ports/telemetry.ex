defmodule Rinha.Domain.Ports.Telemetry do
  @moduledoc """
  Port for diagnostics/profiling telemetry exposed to adapters.
  """

  @callback profiler_summary() :: map()
  @callback reset_profiler() :: any()
  @callback throughput(non_neg_integer(), non_neg_integer()) :: float()
end

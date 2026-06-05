defmodule Rinha do
  @moduledoc """
  Public architecture entrypoints.

  Domain services:

    * `Rinha.Domain.Fraud` - core scoring rules
    * `Rinha.Domain.Models.Axon` - Axon binary classifier scorer
    * `Rinha.Domain.Vectorization` - request payload vectorization
    * `Rinha.Domain.Decision` - approval/score response mapping
    * `Rinha.Domain.ReferenceData` - static resource data
    * `Rinha.Domain.Simulation` - synthetic data and runs
    * `Rinha.Domain.Readiness` - service readiness state
    * `Rinha.Domain.Telemetry` - profiling and diagnostics helpers

  Adapter layer:

    * `Rinha.Endpoint` / `Rinha.RawEndpoint`
    * `Rinha.DebugRouter`

  See `docs/architecture.md` for dependency boundaries.

  Folder layout:

    * `lib/rinha/domain` - business rules and use-cases
    * `lib/rinha/adapters` - HTTP/CLI boundaries
    * `lib/rinha/infrastructure` - concrete low-level implementations
    * `lib/rinha/runtime` - OTP application wiring/bootstrap
  """
end

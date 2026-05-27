defmodule Rinha do
  @moduledoc """
  Public architecture entrypoints.

  Domain services:

    * `Rinha.Domain.Fraud` - core scoring rules
    * `Rinha.Domain.Models.KNN` - KNN model over the IVF index
    * `Rinha.Domain.Vectorization` - request payload vectorization
    * `Rinha.Domain.Decision` - approval/score response mapping
    * `Rinha.Domain.ReferenceData` - static resource data
    * `Rinha.Domain.Index` - IVF index reads and lifecycle
    * `Rinha.Domain.Simulation` - synthetic data and runs
    * `Rinha.Domain.Readiness` - service readiness state
    * `Rinha.Domain.Cluster` - BEAM cluster introspection
    * `Rinha.Domain.Telemetry` - profiling and diagnostics helpers

  Adapter layer:

    * `Rinha.Endpoint` / `Rinha.RawEndpoint`
    * `Rinha.LoadBalancerPlug` / `Rinha.LoadBalancer`
    * `Rinha.DebugRouter`

  See `docs/architecture.md` for dependency boundaries.

  Folder layout:

    * `lib/rinha/domain` - business rules and use-cases
    * `lib/rinha/adapters` - HTTP/LB/CLI boundaries
    * `lib/rinha/infrastructure` - concrete low-level implementations
    * `lib/rinha/runtime` - OTP application wiring/bootstrap
  """
end

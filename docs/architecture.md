# Architecture

This codebase follows a domain-first architecture with thin adapters.

## Folder Structure

- `lib/rinha/domain`
  - Business use-cases, domain policies, and domain-facing ports.

- `lib/rinha/adapters`
  - Transport boundaries (HTTP, LB) and I/O adapters.

- `lib/rinha/infrastructure`
  - Concrete low-level implementations (storage/index/cache/model kernels).

- `lib/rinha/runtime`
  - OTP runtime composition and startup wiring.

## Bounded Contexts

- `Rinha.Domain.Fraud`
  - Core use case orchestration for scoring payloads.
  - Coordinates vectorization, model scoring, and decision rendering.

- `Rinha.Domain.Models.*`
  - `Hybrid`: orchestration between neural prior and IVF scan.
  - `Neural`: neural prior model access.
  - `IVF`: IVF/KNN model access.

- `Rinha.Domain.Vectorization`
  - Payload to fixed 16-lane vector conversion.

- `Rinha.Domain.Decision`
  - Maps fraud-neighbor counts (`0..5`) to API JSON decision payloads.

- `Rinha.Domain.ReferenceData`
  - Static data lifecycle and access (`normalization`, `mcc_risk`).

- `Rinha.Domain.Index`
  - IVF index lifecycle and bucket/centroid reads.

- `Rinha.Domain.Cache`
  - Bloom + ETS caching lifecycle and lookups.

- `Rinha.Domain.Cluster`
  - Erlang distribution introspection/state snapshots.

- `Rinha.Domain.Readiness`
  - Readiness state source of truth.

- `Rinha.Domain.Telemetry`
  - Profiling stats facade and throughput helper.

- `Rinha.Domain.Simulation`
  - Synthetic payload generation and simulation runs.

- `Rinha.Domain.Bootstrap`
  - API mode startup pipeline (load resources, init cache/index, warmup).

## Adapter Layer

- HTTP/API adapters:
  - `Rinha.Endpoint`
  - `Rinha.RawEndpoint`
  - `Rinha.FraudController`
  - `Rinha.DebugRouter`

- Load-balancer adapters:
  - `Rinha.LoadBalancerPlug`
  - `Rinha.LoadBalancer`

- CLI/task adapters:
  - `Mix.Tasks.Rinha.Simulate`

Adapters should call domain services and avoid direct access to low-level infra modules.

## Infrastructure Modules

Infrastructure modules remain in place and are consumed behind domain facades:

- `Rinha.Resources`
- `Rinha.BloomFilter`
- `Rinha.IvfStore`
- `Rinha.VectorTransformerV2`
- `Rinha.NeuralScorer`
- `Rinha.IvfScanner`
- `Rinha.KnnScanner`
- `Rinha.FraudSimulator`
- `Rinha.Profiler`

## Dependency Rules

- Domain modules may depend on infrastructure modules, but only through narrow facades when possible.
- Adapters must depend on domain modules, not on infrastructure internals.
- No legacy wrappers are kept; use domain modules directly.

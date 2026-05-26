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
  - Coordinates vectorization, KNN scoring, and decision rendering.

- `Rinha.Domain.Models.*`
  - `KNN`: nearest-neighbor fraud counting over the IVF index.

- `Rinha.Domain.Vectorization`
  - Payload to fixed 16-lane vector conversion.

- `Rinha.Domain.Decision`
  - Maps fraud-neighbor counts (`0..5`) to API JSON decision payloads.

- `Rinha.Domain.ReferenceData`
  - Static data lifecycle and access (`normalization`, `mcc_risk`).

- `Rinha.Domain.Index`
  - IVF index lifecycle and bucket/centroid reads.

- `Rinha.Domain.Cluster`
  - Erlang distribution introspection/state snapshots.

- `Rinha.Domain.Readiness`
  - Readiness state source of truth.

- `Rinha.Domain.Telemetry`
  - Profiling stats facade and throughput helper.

- `Rinha.Domain.Simulation`
  - Synthetic payload generation and simulation runs.

- `Rinha.Domain.Bootstrap`
  - API mode startup pipeline (validate dataset, load resources, init index, warmup).

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
- `Rinha.IvfStore`
- `Rinha.VectorTransformerV2`
- `Rinha.IvfScanner`
- `Rinha.KnnScanner`
- `Rinha.FraudSimulator`
- `Rinha.Profiler`

## Scoring Pipeline

- Payload enters via HTTP adapter and is passed to `Rinha.Domain.Fraud`.
- `Rinha.Domain.Vectorization` converts payload to a 16-lane signed int vector.
- `Rinha.Domain.Models.KNN` runs KNN counting through `Rinha.IvfScanner`.
- `Rinha.Domain.Decision` maps fraud count (`0..5`) to the final JSON response.

The implementation is correctness-first with official dataset compatibility:

- Official vectors are represented in 14 dimensions; runtime uses stride 16 with two zero pads for scan efficiency.
- Decision semantics remain `k=5` nearest neighbors and threshold `fraud_score >= 0.6` as deny.

## Dependency Rules

- Domain modules may depend on infrastructure modules, but only through narrow facades when possible.
- Adapters must depend on domain modules, not on infrastructure internals.
- No legacy wrappers are kept; use domain modules directly.

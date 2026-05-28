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

Call flow by module:

- `Rinha.RawEndpoint`
  - Reads raw body once.
  - Calls `Rinha.Domain.Fraud.response_for_payload/1` (local API mode) or `remote_score_binary/1` via LB RPC.

- `Rinha.Domain.Fraud`
  - `transform_payload/1` -> `Rinha.Domain.Vectorization.transform/1`
  - `score_vector/1` -> `Rinha.Domain.Models.KNN.score/1`
  - `response_for_neighbors/1` -> `Rinha.Domain.Decision.response_for/1`

- `Rinha.Domain.Models.KNN`
  - Resolves probe budget (`KNN_PROBES`, default 12)
  - Delegates to `Rinha.IvfScanner.score/2`

- `Rinha.IvfScanner`
  - Picks top centroids from `Rinha.Domain.Index.centroids/0`
  - Reads bucket slices from `Rinha.Domain.Index.bucket_slice/1`
  - Uses `Rinha.KnnScanner.scan_slice/3` + `Rinha.KnnScanner.merge_topk/1`
  - Counts fraud labels with `Rinha.KnnScanner.fraud_count/1`

- `Rinha.IvfStore`
  - Loads IVF metadata once at boot (`build/1`)
  - Serves `centroids/0` and `bucket_slice/1` from the `ivf_index.bin` file
  - Uses `iommap` mapped reads (`:iommap.region_binary/3`) for bucket vectors/labels
  - On mmap read failure, remaps the file and retries the bucket read once

## What Is Not Used

- Bloom filter cache: removed from this branch (no bloom module in runtime path).
- Neural prior/hybrid scorer: removed; KNN over IVF is the only scoring model.

The implementation is correctness-first with official dataset compatibility:

- Official vectors are represented in 14 dimensions; runtime uses stride 16 with two zero pads for scan efficiency.
- Decision semantics remain `k=5` nearest neighbors and threshold `fraud_score >= 0.6` as deny.

## Dependency Rules

- Domain modules may depend on infrastructure modules, but only through narrow facades when possible.
- Adapters must depend on domain modules, not on infrastructure internals.
- No legacy wrappers are kept; use domain modules directly.

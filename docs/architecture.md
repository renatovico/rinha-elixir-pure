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
  - Supports configurable scoring model via `SCORING_MODEL` env var (`xgb`, `knn`, or `nn`).

- `Rinha.Domain.Models.*`
  - `RandomForest`: pure-Elixir tree ensemble scorer for exported XGBoost models (default).
  - `NeuralNet`: optional MLP fraud classifier.
  - `KNN`: nearest-neighbor fraud counting over the IVF index.
  - `BorderlineCalibration`: optional KNN-specific correction for `n=3` quantization-boundary cases.

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
- Model scoring depends on `SCORING_MODEL` config (default: `:random_forest` / `xgb`):
  - `:random_forest` -> `Rinha.Domain.Models.RandomForest.score/1` (XGBoost tree ensemble)
  - `:nn` -> `Rinha.Domain.Models.NeuralNet.score/1` (neural network)
  - `:knn` -> `Rinha.Domain.Models.KNN.score/1` (k-nearest neighbors)
- `Rinha.Domain.Decision` maps fraud count (`0..5`) to the final JSON response.

Call flow by module:

- `Rinha.RawEndpoint`
  - Reads raw body once.
  - Calls `Rinha.Domain.Fraud.response_for_payload/1` (local API mode) or `remote_score_binary/1` via LB RPC.

- `Rinha.Domain.Fraud`
  - `transform_payload/1` -> `Rinha.Domain.Vectorization.transform/1`
  - `score_vector/1` -> `RandomForest.score/1` (default), `NeuralNet.score/1`, or `KNN.score/1`
  - `BorderlineCalibration.adjust/2` -> KNN-only, skipped for XGBoost/neural network
  - `response_for_neighbors/1` -> `Rinha.Domain.Decision.response_for/1`

### XGBoost Tree Ensemble (default)

- `Rinha.Domain.Models.RandomForest`
  - Evaluates compact exported XGBoost trees in pure Elixir.
  - Dequantizes int16 runtime vectors back to normalized floats.
  - Maps fraud probability to the `0..5` decision score.

- `Rinha.RandomForestStore`
  - Loads `priv/random_forest.bin` at boot.
  - Keeps tree node payloads as compact binaries in `persistent_term`.

- Training:
  - `MIX_ENV=preprocess mix rinha.train_xgb --rounds 1500 --depth 10 --eta 0.08 --threads 8 --eval-sample 100000 --output priv/random_forest.bin`

### Neural Network Model (optional)

- `Rinha.Domain.Models.NeuralNet`
  - MLP model exported to `priv/nn_weights.bin`.
  - Dequantizes int16 input to float, runs forward pass
  - Maps fraud probability to 0..5 score

- `Rinha.NeuralNetStore`
  - Loads weights from `priv/nn_weights.bin` at boot
  - Stores weights in persistent_term for fast access

### KNN Model (optional, via SCORING_MODEL=knn)

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

## Training Optional Neural Network

```bash
MIX_ENV=preprocess mix rinha.train_nn --epochs 20
```

Trains on `references.json.gz` dataset using EXLA if available.
Exports weights to `priv/nn_weights.bin`.

## What Is Not Used

- Bloom filter cache: removed from this branch (no bloom module in runtime path).

The implementation is correctness-first with official dataset compatibility:

- Official vectors are represented in 14 dimensions; runtime uses stride 16 with two zero pads for scan efficiency.
- Decision semantics remain `k=5` nearest neighbors and threshold `fraud_score >= 0.6` as deny.

## Dependency Rules

- Domain modules may depend on infrastructure modules, but only through narrow facades when possible.
- Adapters must depend on domain modules, not on infrastructure internals.
- No legacy wrappers are kept; use domain modules directly.

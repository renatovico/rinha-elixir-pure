# Rinha de Backend 2026 — Elixir

Real-time fraud-detection API submission for [Rinha de Backend
2026](https://github.com/zanfranceschi/rinha-de-backend-2026).

Pure-Elixir KNN scoring (k=5) over a 3-million-vector reference set, served
across a 2-instance Erlang cluster behind nginx. Hot path is an **IVF-flat**
index built offline with Nx+EXLA k-means; runtime is **zero NIFs, zero
EXLA** — every byte of the scan is plain BEAM bytecode running over
`:persistent_term`-stashed binaries.

## Stack

- **Elixir 1.19 / OTP 28** — release bundled in `debian:trixie-slim`
  (~80 MB image).
- **Phoenix 1.8 + Cowboy** — only used for the `/ready` and `/debug/*`
  routes and the Plug pipeline. The hot path (`POST /fraud-score`) is
  served by a custom `Plug` (`Rinha.RawEndpoint`) that bypasses the router.
- **Pure-Elixir IVF scanner** (`Rinha.IvfScanner`) — top-K probe over
  1024 k-means centroids, then hand-unrolled 16-lane `<<little-signed-16>>`
  pattern-match scan over each probed bucket. ~250× faster than full
  brute force at 100% recall on real-distribution queries.
- **Erlang distribution** — both nodes connect via `:net_kernel`; either
  node serves alone if its peer dies (`Rinha.ClusterConnector`).
- **`:persistent_term` storage** — all 99 MB of vectors + labels live in
  refcounted binaries shared across schedulers; zero GC pressure on the
  hot path.
- **nginx** — round-robin between two unix-socket upstreams (api1, api2).

## Architecture

```
              ┌─────────────────────┐
   :9999 ───► │   nginx (alpine)    │
              │   round-robin       │
              └──────────┬──────────┘
                         │ unix sockets
              ┌──────────┴──────────┐
              │                     │
       ┌──────▼──────┐       ┌──────▼──────┐
       │   api1      │◄─────►│   api2      │
       │ cpuset 0,1  │ erlang│ cpuset 2,3  │
       │ 0.65 CPU    │ dist  │ 0.65 CPU    │
       │ 160 MB RAM  │       │ 160 MB RAM  │
       └─────────────┘       └─────────────┘
              │                     │
              └─── pure Elixir ─────┘
              shared 99 MB + 99 MB
              {refs, ivf} bind-mounts
```

Both instances bind-mount `priv/references_v2.bin` (raw refs, used by
the bench oracle only) and `priv/ivf_index.bin` (the regrouped IVF
index, ~99 MB) read-only. The IVF index is what the production hot path
actually loads into `:persistent_term` — ~96 MB of vectors regrouped by
bucket + 32 KB of centroids + 4 KB of CSR offsets per node.

### Resource budget

| component | CPU | memory |
|-----------|----:|-------:|
| api1      | 0.45| 160 MB |
| api2      | 0.45| 160 MB |
| nginx     | 0.10|  30 MB |
| **total** | **1.00** | **350 MB** |

Matches the Rinha 2026 1.0 CPU + 350 MB envelope. Each API runs at
~150 MB RSS in steady state.

## How the inference works

1. `Rinha.VectorTransformerV2.transform/1` turns a request payload into
   a 16-int (`s16`) feature vector at compile-time-cached LUT speed
   (~2 µs per call).
2. The vector is passed to `Rinha.IvfScanner.score/1`. Two phases:
   - **Centroid scan** — squared-L2 distance from the query to all 1024
     centroids (32 KB binary scan, ~50 µs); pick the top-`P` nearest.
     `P=4` by default — enough for ≥99% recall on real-shape queries.
   - **Bucket scan** — for each probed centroid, brute-force scan its
     ~3000-ref bucket using `Rinha.KnnScanner.scan_slice/3` (a 16-lane
     hand-unrolled binary pattern match), maintain a sorted top-5.
3. Top-5 lists from each probed bucket are merged.
4. The number of fraud-labelled neighbours (0..5) maps to a precomputed
   JSON response in `Rinha.FraudScorer` (`fraud_score = n / 5`,
   `approved = score < 0.6`).

End-to-end: **~1 ms per query** at P=4 on a single 0.65-vCPU container.

## Why IVF (and why pure Elixir)

We started with EXLA-batched brute force across all 3M references; that
hit 2912.45 score on a single instance but couldn’t fit two of those
inside the 2×160 MB cluster budget (BEAM ~50 MB + persistent 96 MB +
per-call XLA buffers ≥ 48 MB).

Pure-Elixir brute force fit in memory (~155 MB RSS) but ran ~140 ms
per query on 0.65 vCPU — under load that meant 99.94% failure rate and
a `−6000` score (cuts triggered).

IVF-flat with K=1024 / P=4 gives the best of both:
- ~99 MB persistent (fits in budget twice)
- ~1 ms per query (fits in p99 budget with 1000× headroom)
- 100% recall vs brute force on real-distribution sample queries
- Zero NIFs, zero EXLA at runtime — pure BEAM bytecode

## Latest score

| metric | value |
|---|---:|
| **final score (best of 3 runs)** | **3489.63** |
| **final score (mean of 3 runs)** | **3374.20 ± 140** |
| failure rate | **0.04 %** |
| false positives | 3 |
| false negatives | 2 |
| http errors | 0 |
| p99 latency | 160–330 ms |
| dataset | 54 100 entries (44 % fraud, 56 % legit) |

Detection score = 2700 (out of 3000). p99 score varies 480–790
depending on saturation behaviour at 900 rps on a 0.45+0.45 CPU envelope.
No cuts triggered. Errors are deterministic — same 5 borderline payloads
fail each run; chasing them with adaptive rescue (P=4 then P=16 if
n ∈ {2,3,4}) cuts errors to 2 (FN=0) but doubles work per query and
drops final score under the tighter CPU budget.

## Quickstart

You'll need `mix`, `docker`, `k6`, and the source dataset at
`priv/resources/references.json.gz` (~48 MB gzipped, 3 M reference
vectors). The `.gz` file ships with the official Rinha 2026 repo at
[`zanfranceschi/rinha-de-backend-2026`](https://github.com/zanfranceschi/rinha-de-backend-2026)
under `resources/references.json.gz`. Copy or symlink it into this
project before running the preprocess step:

```bash
cp /path/to/rinha-de-backend-2026/resources/references.json.gz priv/resources/
```

Then:

```bash
# 1. Decode + quantize the reference vectors → priv/references_v2.bin
make preprocess

# 2. Train the IVF index (Nx+EXLA k-means K=2048) → priv/ivf_index.bin
make ivf-index

# 3. Run the full cluster (api1 + api2 + nginx)
make docker-up

# 4. k6 load test against the Rinha-style port (9999)
make docker-load

# 5. Or single-instance dev
make run            # port 4000
make load           # k6 load against :4000

# 6. Bench IVF recall vs brute force
make bench
```

## Make targets

```
$ make help
  help               Show this help
  deps               Fetch dependencies
  compile            Compile the project
  test               Run ExUnit tests
  preprocess         Generate priv/references_v2.bin from .json.gz
  ivf-index          Build priv/ivf_index.bin (k-means K=2048)
  bench              Bench IVF vs brute-force (--count, --probes)
  run                Start single dev instance (port 4000)
  smoke              k6 smoke test against single instance
  load               k6 load test against single instance
  docker-build       Build the prod image
  docker-up          Start the cluster (api1 + api2 + nginx)
  docker-down        Stop the cluster
  docker-stats       Live stats for the cluster
  docker-logs        Follow logs for the cluster
  docker-test        k6 smoke test against the cluster
  docker-load        k6 load test against the cluster (Rinha submission run)
  docker-cycle       Full cycle: rebuild → load test
  clean              Remove build artifacts
  distclean          Also remove generated binaries
```

## Tuning notes

- **`K=1024 / P=4`** in `Rinha.IvfScanner` — picked from the bench
  sweep. K=1024 gives ~3000 refs per bucket on average (3M / 1024); P=4
  gives ≥99% recall on real-distribution queries with ~12k candidate
  scans per request (250× less work than full 3M brute force).
- **Hand-unrolled 16-lane scan** — `Rinha.KnnScanner.scan_slice/3` uses
  a 16-tuple of named query bindings + a `<<little-signed-16>>` binary
  pattern-match clause. The BEAM compiles this into tight machine code
  that hits ~21 M rows/s on a single 0.65 vCPU, vs ~50 M rows/s for
  hand-written SIMD C — within an order of magnitude with zero NIFs.
- **`:persistent_term` for refs** — `:persistent_term.put({:rinha,
  :ivf_store}, payload)` once at boot; lookups are `:persistent_term.get/1`,
  effectively a const fetch. No GC scans of the 99 MB binary.
- **Erlang distribution** — `RELEASE_DISTRIBUTION=sname` + container
  hostnames `api1`/`api2` resolve trivially; `RINHA_PEER_NODE` env wires
  the bidirectional connection. Either node falls back to local-only
  serving if the peer dies.
- **`+S 2:2 +sbt tnnps +sbwt none ...`** in `rel/vm.args.eex` — pinned
  schedulers, busy-wait disabled (we're CPU-bound on cgroups, busy
  spinning steals from the cluster), `aobf` allocator strategy tuned for
  the 99 MB persistent binary.
- **`debian:trixie-slim`** runtime — alpine + gcompat can't resolve
  glibc 2.38+ `__isoc23_*` symbols pulled in by the BEAM, so we stay on
  glibc.
- **Hot path bypasses `Phoenix.Router`** — `Rinha.RawEndpoint` is mounted
  directly in the endpoint pipeline before `Plug.Parsers` and reads the
  request body itself with OTP 28's `:json.decode/1`.
- **Profiler** — `Rinha.Profiler` aggregates per-phase telemetry into
  log-scale `:counters` histograms; `GET /debug/profile` dumps live
  p50/p95/p99 for the centroid scan, bucket scan, and total IVF time.
- **Misclassifications are deterministic** — 3 FP + 2 FN out of 13.5k
  requests, same payloads each run. They sit on the boundary where the
  fraud:legit neighbour ratio is exactly 3:2 (`n=3`, `score=0.6`,
  `approved=false` flips on a single neighbour). Pushing them past the
  cut requires either a bigger reference set or a model change, not an
  IVF tuning knob.

## Submission

```json
{
  "participants": ["Renato Vico"],
  "social": ["https://github.com/renatovico"],
  "source-code-repo": "https://github.com/renatovico/rinha-de-backend-2026-elixir",
  "stack": ["elixir", "phoenix", "nginx", "docker"],
  "open_to_work": false
}
```

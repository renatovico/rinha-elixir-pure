# Architecture

This codebase follows a domain-first architecture with thin HTTP adapters.

## Folder Structure

- `lib/rinha/domain`
  - Business use-cases, scoring policies, and domain-facing ports.
- `lib/rinha/adapters`
  - HTTP transport adapters.
- `lib/rinha/infrastructure`
  - Concrete low-level implementations (resource loading, model store, vector transformer, profiler).
- `lib/rinha/runtime`
  - OTP startup wiring.

## Runtime Topology

- `api1` and `api2` run the same Elixir app (`Rinha.Endpoint` + `Rinha.RawEndpoint`) on port `4000`.
- HAProxy exposes port `9999` and forwards to `api1`/`api2` with HTTP health checks (`GET /ready`).
- No Erlang cluster mode and no Elixir load-balancer process are used.

## Scoring Pipeline

`Rinha.RawEndpoint` -> `Rinha.Domain.Fraud` -> `Rinha.Domain.Vectorization` -> `Rinha.Domain.Models.Axon` -> `Rinha.Domain.Decision`

- `Rinha.Domain.Vectorization`: payload -> 16-lane signed integer vector.
- `Rinha.Domain.Models.Axon`: Axon inference over `priv/model.axon`.
- `Rinha.Domain.Decision`: maps score bucket (`0..5`) to JSON response.

## Infrastructure Modules

- `Rinha.Resources`
- `Rinha.VectorTransformerV2`
- `Rinha.AxonStore`
- `Rinha.FraudSimulator`
- `Rinha.Profiler`

## Dependency Rules

- Adapters call domain services (not infrastructure internals directly).
- Domain orchestrates infrastructure usage through focused facades.

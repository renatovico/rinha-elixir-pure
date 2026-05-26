.PHONY: help deps compile test run smoke load debug-ready debug-profile debug-profile-reset debug-fixtures debug-score debug-simulate debug-cluster \
        docker-build docker-up docker-down docker-test docker-load \
        docker-stats docker-logs docker-cycle clean
.DEFAULT_GOAL := help

IMAGE     := renatoelias/rinha-elixir-pure:latest
BASE_URL  ?= http://localhost:4000
DEBUG_URL ?= $(BASE_URL)/debug
CLUSTER_URL ?= http://localhost:9999

# ── Help ─────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ── Dev (single instance) ────────────────────────────

deps: ## Fetch dependencies
	mix deps.get

compile: deps ## Compile the project
	mix compile

test: compile ## Run ExUnit tests
	mix test

run: compile ## Start single dev instance (port 4000)
	mix phx.server

# ── k6 (single instance, port 4000) ──────────────────

smoke: ## k6 smoke test against single instance
	k6 run -e BASE_URL=$(BASE_URL) test/k6/smoke.js

load: ## k6 load test against single instance
	k6 run -e BASE_URL=$(BASE_URL) test/k6/test.js

debug-ready: ## Check debug readiness endpoint
	curl -sS "$(DEBUG_URL)/ready"

debug-profile: ## Read debug profiler summary
	curl -sS "$(DEBUG_URL)/profile"

debug-profile-reset: ## Reset debug profiler counters
	curl -sS -X POST "$(DEBUG_URL)/profile/reset"

debug-fixtures: ## List available bundled fixtures
	curl -sS "$(DEBUG_URL)/fixtures"

debug-score: ## Score a bundled fixture (FIXTURE=legit|fraud|borderline)
	@if [ -z "$(FIXTURE)" ]; then \
		echo "Error: set FIXTURE=legit|fraud|borderline"; \
		exit 1; \
	fi
	curl -sS "$(DEBUG_URL)/fixtures/$(FIXTURE)"

debug-simulate: ## Run debug simulator (COUNT, BIAS, WARMUP optional)
	@count=$${COUNT:-1000}; \
	bias=$${BIAS:-0.33}; \
	warmup=$${WARMUP:-100}; \
	curl -sS -X POST "$(DEBUG_URL)/simulate" \
	  -H "content-type: application/json" \
	  -d "{\"count\":$${count},\"fraud_bias\":$${bias},\"warmup\":$${warmup}}"

debug-cluster: ## Check cluster status via LB debug endpoint
	curl -sS "$(CLUSTER_URL)/debug/cluster"

# ── Cluster (docker compose, port 9999) ──────────────

docker-build: ## Build the prod image
	docker compose build

docker-up: ## Start the cluster (api1 + api2 + lb)
	docker compose up -d --build
	@echo ""
	@echo "Cluster up: http://localhost:9999"
	@echo "  api1: cpuset 0,1  (:4000, cluster scorer)"
	@echo "  api2: cpuset 2,3  (:4000, cluster scorer)"
	@echo "  lb:    cpuset 0,2  (:9999, Erlang RPC load balancer)"

docker-down: ## Stop the cluster
	docker compose down

docker-stats: ## Live stats for the cluster
	docker stats --no-stream rinha_pure_api1 rinha_pure_api2 rinha_pure_lb

docker-logs: ## Follow logs for the cluster
	docker compose logs -f --tail 100

docker-test: docker-up ## k6 smoke test against the cluster
	@echo "Waiting for instances to become healthy..."
	@for i in $$(seq 1 60); do \
	  if curl -sf $(CLUSTER_URL)/ready > /dev/null 2>&1; then \
	    echo "Cluster ready after $${i}s"; break; \
	  fi; \
	  sleep 1; \
	done
	k6 run -e BASE_URL=$(CLUSTER_URL) test/k6/smoke.js

docker-load: docker-up ## k6 load test against the cluster (Rinha submission run)
	@echo "Waiting for instances to become healthy..."
	@for i in $$(seq 1 60); do \
	  if curl -sf $(CLUSTER_URL)/ready > /dev/null 2>&1; then \
	    echo "Cluster ready after $${i}s"; break; \
	  fi; \
	  sleep 1; \
	done
	k6 run -e BASE_URL=$(CLUSTER_URL) test/k6/test.js

docker-cycle: docker-down docker-up docker-load ## Full cycle: rebuild → load test
	docker compose down

# ── Cleanup ──────────────────────────────────────────

clean: ## Remove build artifacts
	rm -rf _build deps

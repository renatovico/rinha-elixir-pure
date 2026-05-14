.PHONY: help deps compile test preprocess ivf-index bench run smoke load \
        docker-build docker-up docker-down docker-test docker-load \
        docker-stats docker-logs docker-cycle clean
.DEFAULT_GOAL := help

REFS_GZ   ?= resources/references.json.gz
REFS_BIN  := priv/references_v2.bin
IVF_BIN   := priv/ivf_index.bin
IMAGE     := renatoelias/rinha-elixir:latest
BASE_URL  ?= http://localhost:4000
CLUSTER_URL ?= http://localhost:9999

IVF_K     ?= 2048
IVF_ITERS ?= 15
IVF_BATCH ?= 20000

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

preprocess: compile ## Generate priv/references_v2.bin from .json.gz
	@if [ ! -f "$(REFS_GZ)" ]; then \
		echo "Error: $(REFS_GZ) not found. Set REFS_GZ=path/to/references.json.gz"; \
		exit 1; \
	fi
	mix run --no-start priv/build_references.exs $(REFS_GZ) $(REFS_BIN)

ivf-index: $(REFS_BIN) ## Build priv/ivf_index.bin (k-means K=$(IVF_K))
	IVF_K=$(IVF_K) IVF_ITERS=$(IVF_ITERS) IVF_BATCH=$(IVF_BATCH) \
	  MIX_ENV=dev mix run --no-start priv/build_ivf_index.exs

bench: $(IVF_BIN) ## Bench IVF vs brute-force (--count, --probes)
	MIX_ENV=dev mix rinha.bench --count 200 --probes 1,2,4,8

run: compile $(REFS_BIN) $(IVF_BIN) ## Start single dev instance (port 4000)
	mix phx.server

$(REFS_BIN):
	$(MAKE) preprocess

$(IVF_BIN):
	$(MAKE) ivf-index

# ── k6 (single instance, port 4000) ──────────────────

smoke: ## k6 smoke test against single instance
	k6 run -e BASE_URL=$(BASE_URL) test/k6/smoke.js

load: ## k6 load test against single instance
	k6 run -e BASE_URL=$(BASE_URL) test/k6/test.js

# ── Cluster (docker compose, port 9999) ──────────────

docker-build: $(REFS_BIN) $(IVF_BIN) ## Build the prod image
	docker compose build

docker-up: $(REFS_BIN) $(IVF_BIN) ## Start the cluster (api1 + api2 + nginx)
	docker compose up -d --build
	@echo ""
	@echo "Cluster up: http://localhost:9999"
	@echo "  api1: cpuset 0,1  (unix:/run/sock/api1.sock)"
	@echo "  api2: cpuset 2,3  (unix:/run/sock/api2.sock)"
	@echo "  nginx: cpuset 0,2 (round-robin upstream)"

docker-down: ## Stop the cluster
	docker compose down

docker-stats: ## Live stats for the cluster
	docker stats --no-stream rinha_api1 rinha_api2 rinha_nginx

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

clean: ## Remove build artifacts (keeps references_v2.bin and source data)
	rm -rf _build deps

distclean: clean ## Also remove the generated references_v2.bin and ivf_index.bin
	rm -f $(REFS_BIN) $(IVF_BIN)

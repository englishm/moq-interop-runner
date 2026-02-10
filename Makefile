# Makefile for MoQT interop testing
#
# This is the moq-interop-runner - an implementation-neutral framework for
# testing interoperability between MoQT implementations.
#
# Usage:
#   make interop-list        # List registered implementations
#   make interop-remote      # Test all public relay endpoints
#   make interop-all         # Run full test matrix
#   make test RELAY_URL=...  # Test specific endpoint
#
# For local Docker-based testing, you need to provide images.
# See IMPLEMENTATIONS.md for how to register your implementation.

SHELL := /bin/bash

.PHONY: test test-verbose test-single test-external clean mlog-clean certs \
        interop-all interop-docker interop-remote interop-relay interop-client interop-list \
        relay-start relay-stop logs logs-relay logs-client \
        build-adapters build-moxygen-adapter build-impl build-moq-rs report help _ensure-certs

#############################################################################
# Image Configuration
#
# These can be overridden to test different implementations:
#   make test RELAY_IMAGE=ghcr.io/facebookexperimental/moqrelay:latest
#   make test CLIENT_IMAGE=my-test-client:dev
#############################################################################

# Default images - override these or provide your own
RELAY_IMAGE ?= moq-relay-ietf:latest
CLIENT_IMAGE ?= moq-test-client:latest

# For test-external (direct URL, not docker-compose)
RELAY_URL ?= https://relay:4443
TLS_DISABLE_VERIFY ?= false

#############################################################################
# Certificate Generation (following QUIC interop runner conventions)
#############################################################################

# Generate TLS certificates for testing
certs:
	@echo "Generating TLS certificates..."
	@chmod +x generate-certs.sh
	./generate-certs.sh ./certs

# Check if certs exist, generate if not
_ensure-certs:
	@if [ ! -f certs/cert.pem ] || [ ! -f certs/priv.key ]; then \
		echo "Generating TLS certificates..."; \
		chmod +x generate-certs.sh; \
		./generate-certs.sh ./certs; \
	fi

#############################################################################
# Test Targets
#############################################################################

# Run tests with configured images (requires Docker images to exist)
test: _ensure-certs mlog-clean
	@echo "Running interop tests..."
	@echo "  Relay:  $(RELAY_IMAGE)"
	@echo "  Client: $(CLIENT_IMAGE)"
	RELAY_IMAGE=$(RELAY_IMAGE) CLIENT_IMAGE=$(CLIENT_IMAGE) \
		docker compose -f docker-compose.test.yml up --abort-on-container-exit
	@echo ""
	@echo "Test results in mlog/"

test-verbose: _ensure-certs mlog-clean
	@echo "Running interop tests (verbose)..."
	@echo "  Relay:  $(RELAY_IMAGE)"
	@echo "  Client: $(CLIENT_IMAGE)"
	RELAY_IMAGE=$(RELAY_IMAGE) CLIENT_IMAGE=$(CLIENT_IMAGE) VERBOSE=1 \
		docker compose -f docker-compose.test.yml up --abort-on-container-exit

# Run a specific test
test-single:
	@echo "Running test: $(TESTCASE)"
	@echo "  Relay:  $(RELAY_IMAGE)"
	@echo "  Client: $(CLIENT_IMAGE)"
	RELAY_IMAGE=$(RELAY_IMAGE) CLIENT_IMAGE=$(CLIENT_IMAGE) \
		docker compose -f docker-compose.test.yml run --rm \
		-e TESTCASE=$(TESTCASE) \
		test-client

# Run against external relay URL (not using compose)
test-external:
	@echo "Running tests against $(RELAY_URL)..."
	@echo "  Client: $(CLIENT_IMAGE)"
	docker run --rm \
		--network host \
		-e RELAY_URL=$(RELAY_URL) \
		-e TLS_DISABLE_VERIFY=$(TLS_DISABLE_VERIFY) \
		$(CLIENT_IMAGE)

# Start relay only (for manual testing)
relay-start: _ensure-certs
	RELAY_IMAGE=$(RELAY_IMAGE) docker compose -f docker-compose.test.yml up -d relay
	@echo "Relay started on port 4443"

relay-stop:
	docker compose -f docker-compose.test.yml stop relay

# Clean up
clean:
	docker compose -f docker-compose.test.yml down -v --rmi local 2>/dev/null || true
	rm -rf mlog/ certs/ results/

mlog-clean:
	rm -rf mlog/
	mkdir -p mlog/relay mlog/client

# Show logs
logs:
	docker compose -f docker-compose.test.yml logs

logs-relay:
	docker compose -f docker-compose.test.yml logs relay

logs-client:
	docker compose -f docker-compose.test.yml logs test-client

#############################################################################
# Config-Driven Test Runner (reads from implementations.json)
#############################################################################

# Run all tests (Docker + remote) from implementations.json
interop-all: _ensure-certs
	@test -x ./run-interop-tests.sh || (echo "ERROR: run-interop-tests.sh not found or not executable" && exit 1)
	@./run-interop-tests.sh

# Run only Docker-based tests
interop-docker: _ensure-certs
	@./run-interop-tests.sh --docker-only

# Run only remote endpoint tests (optionally filter by relay: make interop-remote RELAY=moxygen)
interop-remote:
	@./run-interop-tests.sh --remote-only $(if $(RELAY),--relay $(RELAY))

# Run tests for specific relay implementation
interop-relay:
	@./run-interop-tests.sh --relay $(RELAY)

# Run tests for specific client implementation
interop-client:
	@./run-interop-tests.sh --client $(CLIENT)

# List available implementations
interop-list:
	@./run-interop-tests.sh --list

#############################################################################
# Adapter Builds
#
# These build adapter images that wrap upstream implementation images
# to conform to the interop testing conventions (e.g., /certs mount point).
#############################################################################

# Build all adapter images (reads build info from implementations.json)
build-adapters:
	@set -o pipefail; jq -r '.implementations | to_entries[] | .value.roles | to_entries[]? | select(.value.docker.build.dockerfile != null) | select(.value.docker.build.dockerfile | startswith("adapters/")) | "\(.value.docker.image)|\(.value.docker.build.dockerfile)|\(.value.docker.build.context)"' implementations.json | while IFS='|' read -r image dockerfile context; do \
		echo "Building adapter: $$image"; \
		docker build -t "$$image" -f "$$dockerfile" "$$context"; \
	done

# Build individual adapter (kept for convenience / backward compatibility)
build-moxygen-adapter:
	@echo "Building moxygen adapter image..."
	docker build -t moxygen-interop:latest -f adapters/moxygen/Dockerfile.relay adapters/moxygen/

#############################################################################
# Source Builds
#
# Build Docker images from source code. These are NEVER run automatically
# by test targets - users must explicitly opt-in.
#
# See builds/README.md for documentation.
#############################################################################

# Generic build target - requires IMPL parameter
build-impl:
	@if [ -z "$(IMPL)" ]; then \
		echo "Usage: make build-impl IMPL=<implementation>"; \
		echo "Available implementations:"; \
		ls -1 builds/ 2>/dev/null | grep -v README.md || echo "  (none)"; \
		exit 1; \
	fi
	@if [ ! -f "builds/$(IMPL)/build.sh" ]; then \
		echo "ERROR: No build definition for '$(IMPL)'"; \
		echo "Expected: builds/$(IMPL)/build.sh"; \
		exit 1; \
	fi
	@./builds/$(IMPL)/build.sh $(BUILD_ARGS)

# Convenience target for moq-rs
build-moq-rs:
	@./builds/moq-rs/build.sh $(BUILD_ARGS)

#############################################################################
# Report Generation
#############################################################################

report:
	@./generate-report.sh

#############################################################################
# Help
#############################################################################

help:
	@echo "MoQT Interop Runner"
	@echo ""
	@echo "This is an implementation-neutral framework for testing interoperability"
	@echo "between MoQT (Media over QUIC Transport) implementations."
	@echo ""
	@echo "Quick Start:"
	@echo "  make interop-list     List registered implementations"
	@echo "  make interop-remote   Test all public relay endpoints"
	@echo ""
	@echo "Interop Tests (config-driven from implementations.json):"
	@echo "  interop-all           Run all tests (Docker + remote endpoints)"
	@echo "  interop-docker        Run only Docker-based tests"
	@echo "  interop-remote        Run only remote endpoint tests (RELAY=x to filter)"
	@echo "  interop-relay         Test specific relay: make interop-relay RELAY=moxygen"
	@echo "  interop-client        Test specific client: make interop-client CLIENT=moq-rs"
	@echo "  interop-list          List available implementations"
	@echo ""
	@echo "Single Tests (requires Docker images):"
	@echo "  test                  Run tests with configured images"
	@echo "  test-verbose          Run tests with verbose output"
	@echo "  test-single           Run single test: make test-single TESTCASE=setup-only"
	@echo "  test-external         Test external relay: make test-external RELAY_URL=https://..."
	@echo ""
	@echo "Building Images:"
	@echo "  build-adapters        Build all adapter images"
	@echo "  build-impl            Build from source: make build-impl IMPL=moq-rs"
	@echo "  build-moq-rs          Convenience target for moq-rs"
	@echo ""
	@echo "  BUILD_ARGS examples:"
	@echo "    --local ~/git/moq-rs    Use local checkout"
	@echo "    --ref feature-branch    Build specific ref"
	@echo "    --target relay          Build only relay image"
	@echo ""
	@echo "Other:"
	@echo "  certs                 Generate TLS certificates"
	@echo "  relay-start           Start relay container (for manual testing)"
	@echo "  relay-stop            Stop relay container"
	@echo "  clean                 Remove containers, mlog, and certs"
	@echo "  report                Generate HTML report from results"
	@echo ""
	@echo "Image Configuration:"
	@echo "  RELAY_IMAGE           Relay Docker image (default: moq-relay-ietf:latest)"
	@echo "  CLIENT_IMAGE          Test client Docker image (default: moq-test-client:latest)"
	@echo ""
	@echo "Examples:"
	@echo "  make interop-remote                              # Test all public relays"
	@echo "  make interop-relay RELAY=moxygen                 # Test moxygen only"
	@echo "  make interop-client CLIENT=moq-rs               # Test moq-rs client only"
	@echo "  make test RELAY_IMAGE=moxygen-interop:latest     # Test with moxygen Docker"
	@echo "  make test-external RELAY_URL=https://example.com # Test specific URL"
	@echo "  make build-moq-rs BUILD_ARGS=\"--local ~/git/moq-rs\"  # Build from local"
	@echo ""
	@echo "See IMPLEMENTATIONS.md for how to add your implementation."

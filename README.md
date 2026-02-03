# MoQ Interop Runner

A framework for testing interoperability between MoQT (Media over QUIC Transport) implementations.

## Why Interoperability Testing?

The IETF standards process requires "multiple, independent, and interoperable implementations" before a specification can advance ([RFC 2026](https://datatracker.ietf.org/doc/html/rfc2026)). Interop testing catches ambiguities in specs that only surface when different teams interpret the same text differently, and builds confidence that implementations will work together in real deployments.

This project is modeled on the [QUIC Interop Runner](https://github.com/quic-interop/quic-interop-runner), which was instrumental during QUIC standardization.

## Non-Goals

**Reference compliance testing.** This project tests whether different MoQT implementations can successfully communicate with each other - interoperability, not compliance. We're not building a reference implementation that serves as the definitive arbiter of spec compliance. Interop testing happens *between* implementations - if two implementations agree and work together, that's what we care about.

**Adversarial/negative testing.** Our test cases follow scenarios that occur between valid MoQT implementations. We don't require test clients to produce malformed messages or violate the protocol to test error handling. That kind of negative testing requires purpose-built tools capable of representing illegal protocol states - not something we expect from production MoQT implementations.

**Browser-based implementations (for now).** The current Docker-based flow assumes CLI execution. Browser-only implementations (TypeScript/WebTransport) can't plug in directly today. Playwright-based automation is a potential future direction.

## Prerequisites

The following tools are required:

- **Docker** with buildx support (for building multi-platform images)
- **jq** (for parsing JSON configuration)
- **openssl** (for generating TLS certificates)
- **bash** (works with macOS default bash 3.2+)

## Overview

This project provides:

- **Implementation Registry** (`implementations.json`) - A catalog of MoQT implementations with their capabilities, Docker images, and public relay endpoints
- **Test Orchestration** - Scripts to run interop tests across implementation combinations
- **Test Specifications** (`docs/TEST-SPECIFICATIONS.md`) - Standardized test cases that any implementation can implement

The goal is to enable any MoQT implementation to verify interoperability with other implementations, using a shared set of test specifications.

## Quick Start

### Test Public Relays

The fastest way to get started is testing against public relay endpoints:

```bash
# List registered implementations
make interop-list

# Run tests against all public relays
make interop-remote

# Test a specific implementation
make interop-relay RELAY=moxygen
```

### Test with Docker

For Docker-based testing, you need both a relay image and a test client image. The example below uses moxygen's public relay image and moq-rs's test client (which implements the test cases defined in this framework):

```bash
# Build moq-rs test client (if you have moq-rs checked out)
# cd /path/to/moq-rs && docker build -f moq-test-client/docker/Dockerfile.test-client -t moq-test-client:latest .

# Run tests (moxygen relay, moq-rs client)
make test RELAY_IMAGE=ghcr.io/facebookexperimental/moqrelay:latest CLIENT_IMAGE=moq-test-client:latest
```

## Registered Implementations

| Implementation | Organization | Draft Versions | Roles | Public Endpoints |
|----------------|--------------|----------------|-------|------------------|
| moq-rs | Cloudflare | draft-14 | relay, client | `https://draft-14.cloudflare.mediaoverquic.com:443/moq` |
| moxygen | Meta | draft-12-14 | relay | `https://fb.mvfst.net:9448/moq-relay` |
| moqtransport | TUM | draft-13 | relay | (no persistent relay) |
| quiche-moq | Google | draft-14 | relay | `https://quichemoq.dev:443` |
| moqtail | OzU | draft-14 | relay | `https://relay.moqtail.dev` |
| libquicr | Cisco | draft-14 | relay | `https://us-west-2.relay.quicr.org:33437/relay` |
| imquic | Meetecho | draft-13-14 | relay | `https://lminiero.it:9000` |
| moq (moq-dev) | Luke Curley | draft-14 | relay | `https://cdn.moq.dev/anon` |

See [IMPLEMENTATIONS.md](./IMPLEMENTATIONS.md) for full details and how to add your implementation.

## Test Cases

Tests are organized by functional category:

| Test | Category | Description |
|------|----------|-------------|
| `setup-only` | Session | Connect, complete SETUP exchange, close gracefully |
| `announce-only` | Namespace | Announce namespace, receive OK, close |
| `publish-namespace-done` | Namespace | Announce, then send PUBLISH_NAMESPACE_DONE |
| `subscribe-error` | Subscription | Subscribe to non-existent track, expect error |
| `announce-subscribe` | Subscription | Publisher announces, subscriber subscribes |
| `subscribe-before-announce` | Subscription | Subscribe before publisher announces |

See [docs/tests/TEST-CASES.md](./docs/tests/TEST-CASES.md) for detailed specifications with protocol references.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Test Orchestrator                          │
│  (run-interop-tests.sh / Makefile)                              │
│  - Reads implementations.json                                    │
│  - Manages Docker containers or tests remote endpoints           │
│  - Collects results                                              │
└─────────────────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
┌─────────────────────┐            ┌─────────────────────┐
│   Test Client       │            │   Relay Under Test  │
│   (Docker image)    │───────────▶│   (Docker or remote)│
│                     │   MoQT     │                     │
│   Runs test cases,  │            │   Implementation    │
│   reports results   │            │   being tested      │
└─────────────────────┘            └─────────────────────┘
```

## Directory Structure

```
moq-interop-runner/
├── implementations.json       # Implementation registry
├── implementations.schema.json # JSON Schema for validation
├── IMPLEMENTATIONS.md         # How to add your implementation
├── run-interop-tests.sh       # Main test orchestration script
├── Makefile                   # Convenient test targets
├── docker-compose.test.yml    # Docker Compose for local testing
├── generate-certs.sh          # TLS certificate generation
├── generate-report.sh         # HTML report generation
├── adapters/                  # Adapter Dockerfiles for implementations
│   └── moxygen/               # Wraps moxygen image with /certs convention
├── builds/                    # Source-based Docker builds
│   └── moq-rs/                # Build moq-rs from source
└── docs/
    ├── TEST-SPECIFICATIONS.md      # Overview and links to detailed docs
    ├── TEST-CLIENT-INTERFACE.md    # CLI, env vars, output format spec
    ├── IMPLEMENTING-A-TEST-CLIENT.md # Guide for test client authors
    ├── DOCKER-TESTING.md           # Docker-based testing guide
    └── tests/
        └── TEST-CASES.md           # Detailed test case specifications
```

## Related Projects

### MoQT Implementations

- [moq-rs](https://github.com/cloudflare/moq-rs) - Cloudflare (Rust)
- [moxygen](https://github.com/facebookexperimental/moxygen) - Meta (C++)
- [quiche-moq](https://github.com/nicholasjackson/quiche-moq) - Google (C++)
- [libquicr](https://github.com/Quicr/libquicr) - Cisco (C++)
- [moqtransport](https://github.com/mengelbart/moqtransport) - TUM (Go)
- [moq](https://github.com/moq-dev/moq) - Luke Curley (Rust + TypeScript)
- [imquic](https://github.com/meetecho/imquic) - Meetecho (C)
- [moqtail](https://github.com/streaming-university/moqtail) - OzU (Python)

### Inspiration

- [quic-interop-runner](https://github.com/quic-interop/quic-interop-runner) - The QUIC interop testing framework that inspired this project

## Contributing

Contributions welcome! Key areas:

1. **Add your implementation** - See [IMPLEMENTATIONS.md](./IMPLEMENTATIONS.md)
2. **Propose new test cases** - Open an issue or PR to `docs/tests/TEST-CASES.md`
3. **Build a test client** - See [docs/IMPLEMENTING-A-TEST-CLIENT.md](./docs/IMPLEMENTING-A-TEST-CLIENT.md)
4. **Improve tooling** - Better reporting, CI integration, etc.

## Acknowledgments

The initial implementation of this framework was generously supported by [Cloudflare](https://cloudflare.com).

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT License ([LICENSE-MIT](LICENSE-MIT))

at your option.

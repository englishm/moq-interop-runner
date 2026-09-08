# MoQT Implementations Registry

This repository contains the configuration and adapters for running MoQT interop tests across multiple implementations.

## Ways to Participate

| Approach | Complexity | Description |
|----------|------------|-------------|
| **Remote endpoint** | Lowest | Register your public relay URL - no Docker needed |
| **Docker image** | Low | Provide a container image that follows our conventions (see below) |
| **Adapter** | Low | Wrap an existing Docker image to conform to conventions |
| **Build integration** | Medium | Source-based builds for reproducibility and testing specific commits |

Start wherever makes sense for your implementation. The goal is a growing matrix of implementations verifying compatibility with each other.

### Docker Image Conventions

For Docker-based testing, relay images should:

- **TLS certificates**: Read from `/certs/cert.pem` (certificate) and `/certs/priv.key` (private key)
- **Port**: Configurable via environment variable (we use `MOQT_PORT`, default varies by implementation)
- **Protocol**: Expose UDP for QUIC transport
- **Exit codes**: 0 for success, non-zero for failure

If your existing image doesn't follow these conventions, an **adapter** is a thin wrapper Dockerfile that maps your image's configuration to these expectations.

## Quick Start: Adding Your Implementation

### 1. Add entry to `implementations.json`

```json
"your-impl": {
  "name": "Your Implementation",
  "organization": "Your Org",
  "repository": "https://github.com/your/repo",
  "draft_versions": ["draft-14"],
  "notes": "Brief description of your implementation",
  "roles": {
    "relay": {
      "docker": {
        "image": "your-impl-interop:latest",
        "build": {
          "dockerfile": "adapters/your-impl/Dockerfile",
          "context": "adapters/your-impl"
        }
      },
      "remote": [
        {
          "url": "https://your-relay.example.com:443",
          "transport": "webtransport",
          "notes": "WebTransport endpoint"
        },
        {
          "url": "moqt://your-relay.example.com:443",
          "transport": "quic",
          "notes": "Raw QUIC endpoint"
        }
      ]
    }
  }
}
```

### 2. Create adapter (if needed)

If your Docker image doesn't follow the `/certs` mount convention, create an adapter:

```
adapters/your-impl/
├── Dockerfile
└── run_endpoint.sh   (optional, if you need CLI translation)
```

**Dockerfile pattern:**
```dockerfile
FROM your-upstream-image:latest

# Map /certs mount to your implementation's expected paths/env vars
ENV YOUR_CERT_PATH=/certs/cert.pem
ENV YOUR_KEY_PATH=/certs/priv.key

EXPOSE 4443/udp
```

### 3. Build and test

```bash
# Build your adapter
docker build -t your-impl-interop:latest -f adapters/your-impl/Dockerfile adapters/your-impl/

# Test against it
make test RELAY_IMAGE=your-impl-interop:latest
```

## Conventions

### Certificate Mount (`/certs`)

All relay images should read TLS certificates from:
- `/certs/cert.pem` - Certificate
- `/certs/priv.key` - Private key

The test harness generates these automatically via `make certs`.

### Environment Variables

Standard environment variables (optional but recommended):
- `MOQT_ROLE` - Role: `relay`, `client`, `publisher`, `subscriber`
- `MOQT_PORT` - Port to bind

### Roles

| Role | Description |
|------|-------------|
| `relay` | MoQT relay/server that routes between publishers and subscribers |
| `client` | Test client implementation that runs the interop test suite |

### Transport Types

Remote endpoints specify their transport type:

| Transport | Accepted URL Scheme | Description |
|-----------|---------------------|-------------|
| `webtransport` | `https://` or `moqt://` | WebTransport (`https://` remains a compatibility locator; draft 18 and later use canonical `moqt://`) |
| `quic` | `moqt://` | Native QUIC |

The `transport` field records the intended transport independently of the URL
scheme. See [Decision 003](docs/decisions/003-url-scheme-transport-selection.md)
for the migration plan.

Optional endpoint properties:
- `tls_disable_verify`: Set `true` for self-signed certificates
- `status`: `active` (default), `inactive`, or `untested`
- `notes`: Additional context about the endpoint

## Existing Adapters

| Implementation | Adapter | Notes |
|----------------|---------|-------|
| moq-rs | Native | Built with `/certs` support |
| moxygen | `adapters/moxygen/` | Maps env vars to moxygen CLI |

## File Structure

```
moq-interop-runner/
├── implementations.json       # Registry of all implementations
├── implementations.schema.json # JSON Schema for validation
├── IMPLEMENTATIONS.md         # This file
├── README.md                  # Project overview
├── run-interop-tests.sh       # Test runner with version matching
├── Makefile                   # Build and test commands
├── docker-compose.test.yml    # Test orchestration
├── generate-certs.sh          # TLS cert generation
├── adapters/
│   └── moxygen/
│       ├── Dockerfile         # Adapter for Meta's moxygen
│       └── run_endpoint.sh    # CLI translation wrapper
├── docs/
│   ├── TEST-SPECIFICATIONS.md # Test case specifications
│   └── DOCKER-TESTING.md      # Docker testing guide
└── results/                   # Test output (gitignored)
```

Note: The moq-rs Dockerfiles and build configuration live in `builds/moq-rs/` in this repository. The moq-test-client source code lives in the [moq-rs repository](https://github.com/cloudflare/moq-rs/tree/main/moq-test-client).

## Running Tests

Run `make help` to see all available commands. Common operations:

```bash
# List all implementations
./run-interop-tests.sh --list

# Run all tests
./run-interop-tests.sh

# Test specific relay
./run-interop-tests.sh --relay moxygen

# Test specific client against all compatible relays
./run-interop-tests.sh --client moq-rs

# Filter by transport
./run-interop-tests.sh --quic-only
./run-interop-tests.sh --webtransport-only

# Remote endpoints only (no Docker)
./run-interop-tests.sh --remote-only
```

# Docker-Based Interop Testing

> **This covers Docker-based testing workflows.** For public relay testing, see [Getting Started](./GETTING-STARTED.md). `make interop-remote` doesn't need relay images but does require a test client image.

This document describes how to run MoQT interop tests using Docker containers, enabling reproducible testing across different implementations.

## Quick Start

```bash
# List available implementations
make interop-list

# Test all public remote endpoints
make interop-remote

# Test with Docker images (requires building images first)
make test RELAY_IMAGE=moxygen-interop:latest CLIENT_IMAGE=moq-test-client:latest

# Run against a specific relay URL
make test-external RELAY_URL=https://other-relay:4443
```

## Architecture

```
┌──────────────────┐     ┌──────────────────┐
│  moq-relay       │     │  moq-test-client │
│  Container       │◄────│  Container       │
│                  │     │                  │
│  Port 4443       │     │  Runs tests      │
│  TLS enabled     │     │  Reports results │
└──────────────────┘     └──────────────────┘
         │                        │
         └────────┬───────────────┘
                  │
           ┌──────▼──────┐
           │   Shared    │
           │   Network   │
           │   + Volumes │
           └─────────────┘
```

## Docker Images

### moq-relay-ietf

The relay image runs the moq-relay-ietf binary with self-signed TLS certificates.

```bash
# Build using the interop runner's build system
make build-moq-rs BUILD_ARGS="--target relay"

# Or build directly with a local moq-rs checkout
./builds/moq-rs/build.sh --local /path/to/moq-rs --target relay
```

**Environment Variables**:
| Variable | Default | Description |
|----------|---------|-------------|
| `MOQT_ROLE` | `relay` | Role to run (only `relay` supported) |
| `MOQT_PORT` | `4443` | Port to listen on |
| `MOQT_CERT` | `/certs/cert.pem` | Path to TLS certificate |
| `MOQT_KEY` | `/certs/priv.key` | Path to TLS private key |
| `MOQT_MLOG_DIR` | `/mlog` | Directory for mlog output |

### moq-test-client

The test client image runs the test suite against a relay.

```bash
# Build using the interop runner's build system
make build-moq-rs BUILD_ARGS="--target client"

# Or build directly with a local moq-rs checkout
./builds/moq-rs/build.sh --local /path/to/moq-rs --target client
```

**Environment Variables**:
| Variable | Default | Description |
|----------|---------|-------------|
| `RELAY_URL` | `https://relay:4443` | Relay to test against |
| `TESTCASE` | (all) | Specific test to run |
| `TLS_DISABLE_VERIFY` | `0` | Set to `1` to skip TLS certificate verification |
| `VERBOSE` | `0` | Set to `1` for verbose output |

## Running Tests

### Self-Interop (moq-rs × moq-rs)

```bash
# Using docker compose
docker compose -f docker-compose.test.yml up --abort-on-container-exit

# Or using make
make test
```

### Cross-Implementation Testing

To test moq-rs client against another relay:

```bash
# Start the other relay (example: moxygen)
docker run -d --name moxygen-relay -p 4443:4443 moxygen:latest

# Run moq-rs test client against it
docker run --rm \
  --network host \
  -e RELAY_URL=https://localhost:4443 \
  -e TLS_DISABLE_VERIFY=1 \
  moq-test-client:latest
```

To test another client against moq-rs relay:

```bash
# Start moq-rs relay
docker run -d --name moq-relay -p 4443:4443 moq-relay-ietf:latest

# Run the other implementation's test client
docker run --rm \
  --network host \
  -e RELAY_URL=https://localhost:4443 \
  other-impl-test-client:latest
```

## Implementation Contract

For an implementation to participate in Docker-based interop testing, it should provide:

### Relay Image

```yaml
# What relay implementations should provide
image: impl-name-relay:latest
ports:
  - "4443:4443/udp"  # QUIC is UDP-based
environment:
  - MOQT_PORT=4443
  - MOQT_CERT=/certs/cert.pem
  - MOQT_KEY=/certs/priv.key
healthcheck:
  # Verify UDP port is listening (QUIC doesn't support HTTP health endpoints)
  test: ["CMD", "sh", "-c", "ss -uln | grep -q ':4443'"]
  interval: 1s
  timeout: 5s
  retries: 10
```

### Test Client Image

```yaml
# What test client implementations should provide
image: impl-name-test-client:latest
environment:
  - RELAY_URL=https://relay:4443
  - TESTCASE=setup-only  # or omit for all tests
  - TLS_DISABLE_VERIFY=1  # for self-signed certs
exit_code:
  # 0 = all tests passed
  # 1 = one or more tests failed
stdout:
  # Must include: MOQT_TEST_RESULT: SUCCESS or FAILURE
```

## Test Matrix

The ultimate goal is to test every client × relay combination across all implementations. This matrix grows more valuable as implementations add Docker support:

| Client \ Relay | moq-rs | moxygen | quiche-moq | libquicr | moqtransport | ... |
|----------------|--------|---------|------------|----------|--------------|-----|
| moq-rs         | ✓      | ?       | ?          | ?        | ?            |     |
| moxygen        | ?      | ✓       | ?          | ?        | ?            |     |
| quiche-moq     | ?      | ?       | ✓          | ?        | ?            |     |
| libquicr       | ?      | ?       | ?          | ✓        | ?            |     |
| moqtransport   | ?      | ?       | ?          | ?        | ✓            |     |
| ...            |        |         |            |          |              |     |

Each cell in this matrix represents a test: can this client successfully communicate with that relay according to the MoQT specification?

**Current status:** We're building out the infrastructure. Implementations can participate via remote endpoints immediately, and add Docker-based testing as capacity allows. See [IMPLEMENTATIONS.md](../IMPLEMENTATIONS.md) for how to add your implementation.

## Collecting Results

Test results are collected in multiple formats:

### Exit Code
- `0` = all tests passed
- `1` = one or more tests failed

### stdout
Human-readable results plus machine-parseable summary:
```
✓ setup-only (24 ms) [CID: abc123]
✓ announce-only (2011 ms) [CID: def456]
...
Results: 5 passed, 0 failed
MOQT_TEST_RESULT: SUCCESS
```

### mlog Files
qlog-format files in the mounted volume:
```
mlog/
  relay/
    abc123_server.mlog
    def456_server.mlog
  client/
    client.mlog
```

## Troubleshooting

### Connection Refused
- Ensure relay container is running and healthy
- Check network connectivity between containers
- Verify port mapping

### TLS Errors
- Use `TLS_DISABLE_VERIFY=1` for self-signed certs
- Or mount trusted certificates

### Timeout Errors
- Check relay logs for errors
- Increase test timeouts if needed
- Verify relay supports the test's required features

### Corporate Proxy / TLS Interception

If you're behind a corporate proxy that intercepts TLS, Docker builds may fail to fetch crates from crates.io with certificate errors.

**Solution**: Pass the proxy's CA certificate to the build. See the moq-rs repo's build documentation for details.

To find your CA certificate, check your IT documentation or export from your system's certificate store.

## Future Enhancements

- **CI Integration**: GitHub Actions workflow for automated testing
- **Results Dashboard**: Web interface showing test history
- **Performance Metrics**: Track timing across implementations
- **Regression Detection**: Alert on new failures

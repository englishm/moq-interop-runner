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

### Rebuilding published images

The manual **Rebuild All Docker Images** GitHub Actions workflow republishes every runner-owned `ghcr.io/englishm/moq-interop-runner-*` image consumed by `implementations.json`. It excludes images published by upstream projects and local-only adapter images. Run `python3 validate-image-publications.py` to verify that the registry consumers and publication workflows remain aligned.

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
| `MOQT_SCOPE_CONFIG` | (unset) | Optional CAT scope-config JSON, e.g. `/config/scope.json`. See below |

The same variables apply to the draft-18 relay image (`./builds/moq-rs-draft-18/build.sh --target relay`).

#### CAT token authorization (optional)

The moq-rs relay images are built with moq-rs's `auth-cat` feature when the source ref defines it. On its own the feature changes nothing: the relay enforces CAT (Common Access Token) bearer tokens only when you give it a scope-config file. Set `MOQT_SCOPE_CONFIG` to the file's path inside the container, and the entrypoint checks that the file exists and passes it as `--scope-config`. With `MOQT_SCOPE_CONFIG` unset, the relay runs without token checks, as before.

The `--scope-config` flag needs a moq-rs ref that includes the scope-config change ([cloudflare/moq-rs scope-config PRs](https://github.com/cloudflare/moq-rs/pulls?q=is%3Apr+scope-config)). Until those land, build from the PR branch with `--ref` (and `--repo` if the branch is on a fork). If the image's relay has no `--scope-config`, the entrypoint exits with an error instead of starting an unprotected relay. The moq-rs README is the full reference for the file format, reload behaviour and which token claims are checked.

Put the config and the issuer's public key in one directory and mount it at `/config`. A relative `pem_file` resolves against the config file's directory. The relay runs as uid 1000, so the files must be readable by that user.

```bash
mkdir -p cat
cp /path/to/issuer.pub.pem cat/issuer.pub.pem   # P-256 PUBLIC key (-----BEGIN PUBLIC KEY-----)
cat > cat/scope.json <<'JSON'
{
  "default": {
    "auth": {
      "keys": [{ "kid": "issuer-1", "alg": "ES256", "pem_file": "issuer.pub.pem" }],
      "issuers": ["https://issuer.example"],
      "audiences": ["moq-relay"]
    }
  }
}
JSON

./builds/moq-rs-draft-18/build.sh --target relay --ref <ref with --scope-config>
./generate-certs.sh   # if ./certs doesn't exist yet

docker run --rm -p 4443:4443/udp \
  -v "$PWD/certs:/certs:ro" \
  -v "$PWD/cat:/config:ro" \
  -e MOQT_SCOPE_CONFIG=/config/scope.json \
  moq-relay-ietf:latest
```

With only `default`, every connection path is enforced. Tokens must be ES256 CATs signed by that key, with `iss` in `issuers` and `aud` in `audiences`. To give one path its own policy, or leave it open with `"auth": null`, add a `"scopes": { "/path": { ... } }` entry. The file holds public keys only. The relay rejects a private key, and the signing key should never be mounted into the container.

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

#### Relay URL and transports

Clients reach a docker relay at `https://relay:4443` unless its registration sets
`roles.relay.docker.url`; the URL scheme selects the client's transport. A relay
that serves raw QUIC and WebTransport on one port can list both under
`roles.relay.docker.endpoints`. Each endpoint becomes its own run, with mode
`docker-<transport>`, in the relay's one column:

```json
"docker": {
  "image": "example-relay:latest",
  "endpoints": [
    { "url": "moqt://relay:4443", "transport": "quic" },
    { "url": "https://relay:4443", "transport": "webtransport" }
  ]
}
```

`endpoints` takes precedence over `url`.

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

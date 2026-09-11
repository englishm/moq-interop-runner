# Adapters

Thin wrappers that make existing Docker images compatible with the interop testing conventions.

## When to Use Adapters

**Adapters** are for implementations that already publish Docker images but don't follow the interop runner's conventions. This applies to both **relay** and **client** images.

An adapter is typically just a Dockerfile that:
1. Inherits from the upstream image (`FROM upstream-image:latest`)
2. Sets environment variables to map our conventions to theirs
3. Optionally adds a wrapper script if CLI translation is needed

For most cases, adapters are simpler than [builds](../builds/README.md) (which compile from source).

## Conventions

### Relay Conventions

The interop runner expects relay images to follow:

| Convention | Description |
|------------|-------------|
| `/certs/cert.pem` | TLS certificate path |
| `/certs/priv.key` | TLS private key path |
| `MOQT_PORT` | Port to listen on (default: 4443) |
| Exit code 0 | Success |
| Exit code non-zero | Failure |

### Client Conventions

The interop runner expects client images to follow:

| Convention | Description |
|------------|-------------|
| `RELAY_URL` | Relay locator (`https://` for legacy WebTransport clients; `moqt://` for native QUIC or draft 18 and later WebTransport) |
| `TESTCASE` | Specific test to run (optional; runs all if not set) |
| `TLS_DISABLE_VERIFY=1` | Skip TLS certificate verification |
| TAP version 14 on stdout | Machine-parseable test output |
| Exit code 0 | All tests passed |
| Exit code 1 | One or more tests failed |

See [TEST-CLIENT-INTERFACE.md](../docs/TEST-CLIENT-INTERFACE.md) for the full client interface specification.

### When Do You Need an Adapter?

If an upstream image uses different environment variable names, certificate paths, or CLI conventions, an adapter bridges the gap.

## Directory Structure

```
adapters/
├── README.md              # This file
└── moxygen/
    ├── Dockerfile.relay   # Wraps upstream moxygen relay image
    └── run_endpoint.sh    # Optional CLI translation script
```

## Example: moxygen Adapter

Moxygen's official image expects certificates via environment variables, not the `/certs` mount. The adapter maps our convention to theirs:

```dockerfile
FROM ghcr.io/facebookexperimental/moqrelay:latest-amd64

# Map our /certs convention to moxygen's expected env vars
ENV CERT_FILE=/certs/cert.pem
ENV KEY_FILE=/certs/priv.key
ENV MOQ_PORT=4443

EXPOSE 4443/udp
```

## Adding an Adapter

### Requirements

Any approach is valid as long as the resulting image(s) satisfy the [Relay Conventions](#relay-conventions) and/or [Client Conventions](#client-conventions) above. Register each image in `implementations.json` with a `build` section so `make build-adapters` can discover it.

The steps are always:

1. Create a directory under `adapters/` matching the implementation name
2. Add one or more Dockerfiles that inherit from the upstream image
3. Map environment variables or add wrapper scripts as needed
4. Register in `implementations.json` with a `build.dockerfile` path starting with `adapters/`

### Choose an approach

| Approach | When to use | Dockerfiles |
|----------|-------------|-------------|
| **[Single-role adapters](#single-role-adapters)** | Upstream publishes separate relay and client images | One `Dockerfile.relay` and/or `Dockerfile.client` per role |
| **[Combined image — separate Dockerfiles](#option-a-separate-adapter-dockerfiles-per-role)** | Upstream ships one image with both binaries; you want per-role control | One `Dockerfile.relay` + `Dockerfile.client`, both `FROM` the same upstream |
| **[Combined image — dispatch shim](#option-b-entrypoint-dispatch-shim)** | Upstream ships one image with both binaries; you want the simplest adapter | One `Dockerfile` + an `entrypoint.sh` that switches on `MOQT_ROLE` |

These are common patterns, not an exhaustive list — anything that produces convention-compliant images will work.

---

### Single-role adapters

The most common case: the upstream image serves a single role and just needs convention mapping.

**Relay example** — map certificate paths:

```dockerfile
# Dockerfile.relay
FROM ghcr.io/example/moq-relay:latest

ENV CERT_FILE=/certs/cert.pem
ENV KEY_FILE=/certs/priv.key
ENV MOQ_PORT=4443
```

**Client example** — map environment variable names:

```dockerfile
# Dockerfile.client
FROM ghcr.io/example/moq-test-client:latest

# Map interop runner conventions to upstream env vars
ENTRYPOINT ["sh", "-c", "TARGET_URL=$RELAY_URL SKIP_TLS_VERIFY=$TLS_DISABLE_VERIFY exec /usr/local/bin/moq-test-client"]
```

**Registration** — each role gets its own entry:

```json
"your-impl": {
  "roles": {
    "relay": {
      "docker": {
        "image": "your-impl-interop:latest",
        "build": {
          "dockerfile": "adapters/your-impl/Dockerfile.relay",
          "context": "adapters/your-impl"
        },
        "upstream_image": "original-image:latest"
      }
    },
    "client": {
      "docker": {
        "image": "your-impl-test-client:latest",
        "build": {
          "dockerfile": "adapters/your-impl/Dockerfile.client",
          "context": "adapters/your-impl"
        },
        "upstream_image": "original-client-image:latest"
      }
    }
  }
}
```

---

### Combined relay+client images

Some implementations ship a single Docker image containing both the relay and a test client binary. There are two ways to adapt these.

#### Option A: Separate adapter Dockerfiles per role

Thin Dockerfiles that each `FROM` the same upstream image and set the appropriate entrypoint. Use this when you need different environment setup or dependencies per role.

```dockerfile
# Dockerfile.relay
FROM ghcr.io/example/moq-combined:latest
ENTRYPOINT ["moq-server", "--relay"]
```

```dockerfile
# Dockerfile.client
FROM ghcr.io/example/moq-combined:latest
ENTRYPOINT ["moq-test-client"]
```

Each produces a separate tagged image:

```json
"your-impl": {
  "roles": {
    "relay": {
      "docker": {
        "image": "your-impl-relay:latest",
        "build": {
          "dockerfile": "adapters/your-impl/Dockerfile.relay",
          "context": "adapters/your-impl"
        }
      }
    },
    "client": {
      "docker": {
        "image": "your-impl-client:latest",
        "build": {
          "dockerfile": "adapters/your-impl/Dockerfile.client",
          "context": "adapters/your-impl"
        }
      }
    }
  }
}
```

#### Option B: Entrypoint dispatch shim

A single adapter with a dispatch script that switches on `MOQT_ROLE`. This is a good fit when the upstream image already contains both binaries and you want the simplest possible adapter — for example, an implementation whose main Docker image is designed for relay deployment but also happens to include a test client binary.

```dockerfile
FROM ghcr.io/example/moq-combined:latest
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

Example dispatch script:

```bash
#!/bin/sh
# entrypoint.sh — dispatches based on MOQT_ROLE
# Adapt binary names and flags to match your implementation.
set -e

MOQT_PORT="${MOQT_PORT:-4443}"
MOQT_CERT="${MOQT_CERT:-/certs/cert.pem}"
MOQT_KEY="${MOQT_KEY:-/certs/priv.key}"

case "$MOQT_ROLE" in
  relay)
    # Replace with your relay binary and flags
    exec your-relay-binary --cert "$MOQT_CERT" --key "$MOQT_KEY" --port "$MOQT_PORT"
    ;;
  client)
    # Replace with your test client binary; forward TESTCASE and TLS_DISABLE_VERIFY
    exec your-test-client --url "$RELAY_URL" \
      ${TESTCASE:+--test "$TESTCASE"} \
      ${TLS_DISABLE_VERIFY:+--skip-verify}
    ;;
  *)
    echo "Unknown role: $MOQT_ROLE" >&2
    exit 127
    ;;
esac
```

The relay defaults match the interop runner's conventions; the client branch should forward `TESTCASE` and `TLS_DISABLE_VERIFY` as appropriate for your binary's CLI.

Register the single image under both roles:

```json
"your-impl": {
  "roles": {
    "relay": {
      "docker": {
        "image": "your-impl-interop:latest",
        "build": {
          "dockerfile": "adapters/your-impl/Dockerfile",
          "context": "adapters/your-impl"
        }
      }
    },
    "client": {
      "docker": {
        "image": "your-impl-interop:latest",
        "build": {
          "dockerfile": "adapters/your-impl/Dockerfile",
          "context": "adapters/your-impl"
        }
      }
    }
  }
}
```

## Building Adapters

```bash
# Build all adapters (reads build info from implementations.json)
make build-adapters

# Build a specific adapter directly
make build-moxygen-adapter

# Or with docker build
docker build -t moxygen-interop:latest -f adapters/moxygen/Dockerfile.relay adapters/moxygen/
```

`make build-adapters` discovers all adapter builds from `implementations.json` — any entry whose `build.dockerfile` starts with `adapters/` is built automatically. Adding a new adapter only requires creating the directory and registering it in `implementations.json`; no Makefile changes are needed.

## Adapters vs Builds

| Approach | When to Use | Works For |
|----------|-------------|-----------|
| **Adapters** | Upstream publishes working Docker images; you just need convention mapping | Relays and clients |
| **Builds** | You need to compile from source, test specific commits, or no upstream image exists | Relays and clients |

Adapters are simpler and faster since they reuse existing images. Use builds when you need source-level control. Both approaches work for any role (relay, client, etc.).

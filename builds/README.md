# Builds Framework

Build Docker images from source code for MoQ implementations.

## When to Use Builds

**Builds** compile implementations from source, providing:
- Reproducibility via pinned commits
- Ability to test unreleased code or specific branches
- Local development workflows

Builds can produce images for any role (relay, client, or both). For most cases, **adapters** (wrapping existing Docker images) or **remote endpoints** (testing against public relays) are simpler. Use builds when you need source-level control.

Builds are opt-in and require explicit invocation - they don't run automatically during tests.

## Directory Structure

```
builds/
├── README.md           # This file
└── moq-rs/
    ├── config.json     # Source repo, refs, targets
    ├── build.sh        # Entry point script
    ├── Dockerfile.*    # Docker build files
    └── .sources/       # gitignored - cloned repos
```

## Usage

### Direct Invocation

```bash
# Build from default ref
./builds/moq-rs/build.sh

# Build from specific branch/tag
./builds/moq-rs/build.sh --ref feature-branch

# Use local checkout (for development)
./builds/moq-rs/build.sh --local ~/git/moq-rs

# Build specific target only
./builds/moq-rs/build.sh --target client
```

### Makefile Integration

```bash
# Build implementation using defaults
make build-impl IMPL=moq-rs

# Build with custom arguments
make build-moq-rs BUILD_ARGS="--local ~/git/moq-rs"
```

## Security Considerations

Builds execute arbitrary code from external repositories. Important safeguards:

- **Never run automatically** - Test targets do not trigger builds
- **Explicit opt-in required** - Users must invoke build commands directly
- **Review before running** - Inspect build definitions for unfamiliar implementations

## Adding a Build for Your Implementation

1. Create a directory under `builds/` matching your implementation name
2. Create `config.json` with:
   - Repository URL
   - Default ref (branch/tag)
   - Build targets (client, server, etc.)
3. Create `build.sh` entry point script
4. Create `Dockerfile.*` for each target

### Example config.json

```json
{
  "name": "moq-impl",
  "description": "Description of your implementation",
  "repository": "https://github.com/example/moq-impl.git",
  "default_ref": "main",
  "targets": {
    "relay": {
      "dockerfile": "Dockerfile.relay",
      "image_name": "moq-relay",
      "context": ".sources/moq-impl"
    },
    "client": {
      "dockerfile": "Dockerfile.client",
      "image_name": "moq-test-client",
      "context": ".sources/moq-impl"
    }
  }
}
```

## moqxr Publisher And moqy Subscriber Client

The `moqxr` client image includes moqxr for publishing and moqy for media
subscription. Build it from local checkouts with a draft-22 moq5 revision:

```bash
./builds/moqxr/build.sh --local ../moqxr \
  --moq5-local /path/to/draft-22-moq5
```

The script uses sibling `../moqy` and the picoquic/picotls checkouts under
`../moq5/.deps/picoquic-refresh` by default. Override these with
`--moqy-local`, `--picoquic-local`, and `--picotls-local` when needed. It stages
clean Git revisions for Docker and builds `moqxr-interop-client:latest`.

The image exposes `announce-only` and `publish-subscribe-media` through the
standard TAP client interface. The media case needs a relay that accepts
draft 22 and namespace publication under `moq-test/interop`. moqy currently
provides catalog-driven media subscription, not the raw request/response
control needed for `subscribe-error` or `rendezvous-timeout`.

Run the registered Red5 draft-22 endpoints with:

```bash
./run-interop-tests.sh --remote-only --relay red5-moq-relay \
  --client moqxr --target-version draft-22
```

## Provenance Tracking

Each build captures metadata for reproducibility:

| Field | Description |
|-------|-------------|
| `commit` | Full commit hash |
| `dirty` | Whether working tree had uncommitted changes |
| `timestamp` | Build time (ISO 8601) |
| `ref` | Branch/tag used |

This information is:
- Printed to stdout during build
- Saved to `.last-build.json` in the build directory

Use provenance data to reproduce test results or debug regressions against specific code versions.

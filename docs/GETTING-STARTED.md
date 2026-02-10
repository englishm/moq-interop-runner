# Getting Started

This is the MoQ Interop Runner — a framework for automated interoperability testing between MoQT implementations. It replaces the manual testing process (ad-hoc commands, visual inspection, spreadsheet tracking) with a standard set of test cases, machine-parseable results, and a growing client x relay test matrix.

## Prerequisites

- **Docker** with buildx support
- **jq** (for parsing JSON configuration)
- **openssl** (for generating TLS certificates)
- **bash** (macOS default bash 3.2+ works)

## Run Your First Interop Test

Clone the repo and look around:

```bash
git clone https://github.com/englishm/moq-interop-runner.git
cd moq-interop-runner

# See what's registered
make interop-list
```

`make interop-list` shows every registered implementation, its supported draft versions, roles, and endpoints. No building required — this just reads `implementations.json`.

### Build the test client

Before you can run tests, you need a test client Docker image. Currently moq-rs is the only implementation with a test client, and it's built from source:

```bash
make build-moq-rs BUILD_ARGS="--target client"
```

This clones the moq-rs repo and builds the `moq-test-client` Docker image. **Expect it to take a few minutes** the first time (it's compiling Rust). Subsequent builds are faster thanks to Docker layer caching.

> **Why isn't this pre-built?** Build targets under `builds/` are intentionally opt-in. They pull external source code and run it, so we don't want that happening automatically or by surprise. The trade-off is this extra step up front. The `builds/` setup is also useful when you're iterating on local code changes — see `make build-moq-rs BUILD_ARGS="--local /path/to/moq-rs"`.

### Run the tests

```bash
make interop-remote
```

This runs the test client against every public relay endpoint registered in `implementations.json` and prints TAP-format results as tests complete. It only tests remote endpoints — no relay Docker images are pulled or built.

To narrow to a single relay's remote endpoints:

```bash
make interop-remote RELAY=moxygen
```

Run `make help` to see all available commands — it's the quickest way to discover what the runner can do.

## Verify Your Implementation Entry

**This is the single fastest way to contribute.** Every registered implementation has an entry in `implementations.json`. If your implementation is listed, please check that your entry is accurate — especially heading into the hackathon.

Here's what each field means and what to check:

```json
"your-impl": {
  "name": "Your Implementation",
  "organization": "Your Org",
  "repository": "https://github.com/your/repo",
  "draft_versions": ["draft-14"],
  "notes": "Brief description",
  "roles": {
    "relay": {
      "remote": [
        {
          "url": "https://your-relay.example.com:443/path",
          "transport": "webtransport",
          "tls_disable_verify": true,
          "notes": "Optional context"
        }
      ]
    }
  }
}
```

| Field | What to check |
|-------|---------------|
| `name` | Display name — is this how you want your implementation identified in reports? |
| `organization` | Who maintains it — correct org/person? |
| `repository` | Link to your source repo — still accurate? |
| `draft_versions` | **Most important.** Array of MoQT draft versions your implementation currently supports (format: `draft-NN`). If you've added draft-16 support or dropped older versions, update this. The runner uses this to decide which client/relay pairs to test. |
| `notes` | Brief description — anything important reviewers should know? |
| `roles` | Which roles your implementation supports. Most implementations start as `relay` only. If you've built a test client, add a `client` role (see [Issue #13](https://github.com/englishm/moq-interop-runner/issues/13)). |
| `remote[].url` | Your public endpoint URL. `https://` for WebTransport, `moqt://` for raw QUIC. Is this endpoint still running? Has the port or path changed? |
| `remote[].transport` | `webtransport` or `quic` — does this match the URL scheme? |
| `remote[].tls_disable_verify` | Set to `true` if your endpoint uses a self-signed certificate. If you've switched to a CA-signed cert, you can remove this. |
| `remote[].status` | Optional. Set to `"inactive"` to temporarily exclude an endpoint from test runs without removing it. Omit or set to `"active"` for live endpoints. |

### Currently registered implementations

| Key | Organization | Draft Versions | Roles | Endpoints |
|-----|-------------|----------------|-------|-----------|
| `moq-rs` | Cloudflare | draft-14 | relay, client | QUIC + WebTransport |
| `moxygen` | Meta | draft-12, 13, 14 | relay | QUIC + WebTransport |
| `moq-dev-moq` | Luke Curley | draft-14 | relay | WebTransport |
| `moqtransport` | TUM | draft-13 | relay | (no endpoints) |
| `quiche-moq` | Google | draft-14 | relay | WebTransport |
| `moqtail` | OzU | draft-14 | relay | WebTransport |
| `imquic` | Meetecho | draft-13, 14 | relay | QUIC + WebTransport |
| `libquicr` | Cisco | draft-14 | relay | QUIC + WebTransport |

If anything above is out of date, open a PR updating `implementations.json` or let [@englishm](https://github.com/englishm) know.

## Choose Your Path

Different ways to engage, roughly ordered by time investment:

| I want to... | Time | Where to start |
|--------------|------|----------------|
| Verify my implementation entry is accurate | 5 min | [See above](#verify-your-implementation-entry) |
| Run tests against my public relay | 5 min | [Test Your Relay](#test-your-relay) below |
| Register my implementation for the first time | 15 min | [Add Your Implementation](#add-your-implementation) below |
| Build a test client for my MoQT stack | 2-4 hours | [Build a Test Client](#build-a-test-client) below |
| Propose or spec new test cases | Varies | [docs/tests/TEST-CASES.md](./tests/TEST-CASES.md) |

## Test Your Relay

If your implementation is already registered with remote endpoints:

```bash
make interop-remote RELAY=your-impl
```

If your relay isn't registered yet, you can still test it directly by URL:

```bash
make test-external RELAY_URL=https://your-relay:4443 TLS_DISABLE_VERIFY=true
```

## Add Your Implementation

To register a new implementation (or add endpoints to an existing one):

1. **Edit `implementations.json`** — add your entry using the field reference above
2. **Validate** — `python3 -m json.tool implementations.json > /dev/null`
3. **Test** — `make interop-relay RELAY=your-impl`
4. **Open a PR**

The minimal entry for a relay with a public endpoint:

```json
"your-impl": {
  "name": "Your Implementation",
  "organization": "Your Org",
  "repository": "https://github.com/your/repo",
  "draft_versions": ["draft-14"],
  "roles": {
    "relay": {
      "remote": [
        {
          "url": "https://your-relay.example.com:443",
          "transport": "webtransport"
        }
      ]
    }
  }
}
```

See [IMPLEMENTATIONS.md](../IMPLEMENTATIONS.md) for the full guide including Docker images, adapters, and multiple transport types.

## Build a Test Client

Adding a test client for your implementation expands the interop matrix from "does moq-rs work against your relay?" to "does *your* client work against *every* relay?"

The process:

1. **Implement the interface** — [TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md) defines the contract (env vars, TAP output, exit codes)
2. **Follow the guide** — [IMPLEMENTING-A-TEST-CLIENT.md](./IMPLEMENTING-A-TEST-CLIENT.md) walks through building a test client with pseudocode examples
3. **Package as Docker** — the runner executes clients as containers
4. **Register** — add a `client` role to your `implementations.json` entry

[Issue #13](https://github.com/englishm/moq-interop-runner/issues/13) has a detailed walkthrough of the full process including Docker image options (pre-built registry image, adapter, or source build).

You don't need to implement every test case to start — even just `setup-only` is valuable. Use the TAP `SKIP` directive for tests you haven't implemented yet.

## Further Reading

| Document | What it covers |
|----------|---------------|
| [TEST-CASES.md](./tests/TEST-CASES.md) | Test case definitions with protocol references |
| [TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md) | Interface specification for test clients (reference) |
| [IMPLEMENTING-A-TEST-CLIENT.md](./IMPLEMENTING-A-TEST-CLIENT.md) | Guide for building a compatible test client |
| [DOCKER-TESTING.md](./DOCKER-TESTING.md) | Docker-based testing workflows |
| [VERSION-MATCHING.md](./VERSION-MATCHING.md) | How the runner pairs clients and relays by draft version |
| [IMPLEMENTATIONS.md](../IMPLEMENTATIONS.md) | Full guide to adding implementations, adapters, Docker conventions |

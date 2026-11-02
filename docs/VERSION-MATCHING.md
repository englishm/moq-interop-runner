# Version Matching and Test Planning

The interop runner tests every eligible (client, relay) pair. This document describes how it decides which pairs to test, predicts what version they will negotiate, and organizes the results.

For the design rationale behind this approach, see [Decision 002: Version Selection Strategy](decisions/002-version-selection-strategy.md).

## The core idea

The runner cannot control MoQT version negotiation — implementations negotiate on the wire. In practice, two implementations that share at least one draft version are expected to negotiate the newest one both support (a prediction, not a guarantee — see [Decision 002](decisions/002-version-selection-strategy.md) for caveats). The runner uses this prediction for labeling and classification, not as a directive.

The report places a run at the version its client reported negotiating, when the log has one: TAP YAML `sessions.*.moqt_version` ([TAP YAML Metadata](TAP-YAML-METADATA.md)), or the legacy `negotiated_version: draft-NN`. `summary.json` records these as `negotiated_versions`. Runs whose client reports nothing keep the prediction, shown in italics; a negotiated version that differs from the prediction is underlined.

## Inputs

- **`current_target`** from `implementations.json` (e.g., `"draft-14"`), overridable with `--target-version`
- **`implementations`** registry, where each entry has:
  - `draft_versions`: array of supported versions (format: `draft-NN`)
  - `roles`: which roles the implementation supports (`client`, `relay`, or both)
  - Per-role endpoint configuration (Docker images, remote URLs)

## Algorithm

### 1. Compute predicted version

For each (client, relay) pair:

```
shared = intersection(client.draft_versions, relay.draft_versions)
if shared is empty → skip pair
predicted_version = max(shared)    # newest shared draft
```

See `compute_negotiated_version()` in `run-interop-tests.sh`.

### 2. Classify relative to target

Each pair's predicted version is classified:

| Predicted vs. Target | Classification | Terminal display |
|----------------------|----------------|------------------|
| Equal                | `at`           | `at-target`      |
| Greater              | `ahead`        | `ahead`          |
| Less                 | `behind`       | `behind`         |

See `classify_version()` in `run-interop-tests.sh`.

### 3. Expand to endpoints

Each pair is expanded into one or more runnable tests based on the relay's endpoints:

- **Docker**: if the relay has `roles.relay.docker.image`
- **Remote**: one test per entry in `roles.relay.remote[]`, labeled `remote-quic` or `remote-webtransport` by transport type

Inactive endpoints (`"status": "inactive"`) are skipped. The plan is endpoint-level — a pair with both QUIC and WebTransport remote endpoints produces two runs.

See `list_endpoints()` in `run-interop-tests.sh`.

### 4. Filter

Filters narrow the plan without changing version computation:

| Filter | Effect | Scope |
|--------|--------|-------|
| `--only-at-target` | Keep only pairs classified `at` | Pair-level |
| `--only-ahead-of-target` | Keep only pairs classified `ahead` | Pair-level |
| `--only-behind-target` | Keep only pairs classified `behind` | Pair-level |
| `--relay NAME` | Restrict to one relay | Pair-level |
| `--client NAME` | Restrict to one client | Pair-level |
| `--docker-only` | Drop remote endpoints | Endpoint-level |
| `--remote-only` | Drop Docker endpoints | Endpoint-level |
| `--transport TYPE` | Keep only remote endpoints matching TYPE | Endpoint-level |
| `--quic-only` | Shorthand for `--transport quic` | Endpoint-level |
| `--webtransport-only` | Shorthand for `--transport webtransport` | Endpoint-level |

Classification filters, `--relay`, and `--client` apply before endpoint expansion. Transport filters apply during expansion. Only one `--only-*` flag is allowed. `--docker-only` and `--remote-only` are mutually exclusive.

Note: transport filters (`--transport`, `--quic-only`, `--webtransport-only`) only affect remote endpoints. Docker tests still run unless `--remote-only` is also set.

### 5. Sort and execute

Runs are sorted: at-target first, then ahead, then behind. Within each classification, order follows the client × relay iteration order.

`--dry-run` shows the full plan with per-endpoint detail and exits without running tests.

## Output

Each test result is recorded in `summary.json` with:

```json
{
  "client": "moq-rs",
  "relay": "moxygen",
  "version": "draft-14",
  "classification": "at",
  "mode": "remote-webtransport",
  "target": "https://moxygen.example.com:443/moq",
  "status": "pass",
  "exit_code": 0
}
```

The report generator uses `classification` to color version badges and group results. See `generate-report.sh`.

## Worked example

Using the current `implementations.json` registry:

| Implementation | Roles | Draft Versions |
|----------------|-------|----------------|
| moq-rs | client, relay | draft-14 |
| moxygen | relay | draft-14, draft-13, draft-12 |
| moq-dev-rs | relay | draft-14 |
| moqtransport | relay | draft-13 |
| quiche-moq | relay | draft-14 |
| moqtail | relay | draft-14 |
| imquic | relay | draft-14, draft-13 |
| libquicr | relay | draft-14 |

**Target: draft-14. Only client: moq-rs (draft-14).**

| Pair | Shared | Predicted | Classification |
|------|--------|-----------|----------------|
| moq-rs → moq-rs | draft-14 | draft-14 | at |
| moq-rs → moxygen | draft-14 | draft-14 | at |
| moq-rs → moq-dev-rs | draft-14 | draft-14 | at |
| moq-rs → moqtransport | ∅ | — | skipped |
| moq-rs → quiche-moq | draft-14 | draft-14 | at |
| moq-rs → moqtail | draft-14 | draft-14 | at |
| moq-rs → imquic | draft-14 | draft-14 | at |
| moq-rs → libquicr | draft-14 | draft-14 | at |

**Result:** 7 pairs, all at-target. moqtransport is skipped — it only supports draft-13, which moq-rs does not.

Each pair then expands to its endpoints. If moq-rs has a Docker relay and moxygen has two remote endpoints (QUIC + WebTransport), those become 3 separate runs.

## Hypothetical example

Suppose moxygen and imquic add client roles and a new implementation arrives at draft-15:

| Implementation | Roles | Draft Versions |
|----------------|-------|----------------|
| moq-rs | client, relay | draft-14 |
| moxygen | **client**, relay | draft-15, draft-14, draft-13 |
| imquic | **client**, relay | draft-15, draft-14, draft-13 |
| moqtransport | relay | draft-13 |

With target draft-14:

- **moq-rs → moqtransport**: no shared version, skipped
- **moxygen → moqtransport**: shared draft-13, predicted draft-13, classified **behind**
- **imquic → moqtransport**: shared draft-13, predicted draft-13, classified **behind**
- **moxygen → imquic**: shared {draft-15, draft-14, draft-13}, predicted draft-15, classified **ahead**
- **imquic → moxygen**: shared {draft-15, draft-14, draft-13}, predicted draft-15, classified **ahead**
- All other pairs share draft-14 as their newest → classified **at**

Running `--only-at-target` would test only the at-target pairs. The default runs everything: at-target pairs first, then ahead, then behind.

## Data model

### Version format

All versions use the format `draft-NN` (e.g., `draft-14`). The schema enforces the pattern `^draft-\d+$`. The runner validates this at startup for both `--target-version` and all `draft_versions` entries in the config. Versions are compared by extracting the numeric suffix.

### Per-endpoint version override (schema only)

The schema defines an optional `draft_version` field on individual endpoints. The runner ignores it. Version matching uses only the implementation-level `draft_versions` array. This field exists as a placeholder for potential future per-endpoint version support.

## Key functions

All defined in `run-interop-tests.sh`:

| Function | Purpose |
|----------|---------|
| `compute_negotiated_version` | Newest shared draft version for a pair |
| `classify_version` | `at` / `ahead` / `behind` relative to target |
| `list_endpoints` | Enumerate runnable endpoints for a relay |
| `format_classification` | Color-coded terminal display |
| `run_test` | Execute one endpoint test and record result |

## What changed from the previous algorithm

The previous version (documented in earlier commits of this file) used a 3-phase approach: target-version pairs first, then fallback for behind implementations, then forward for ahead implementations, with pair-level deduplication across phases. The current approach replaces all of that with a single pass: compute newest-shared for every pair, classify, filter, sort, execute. See [Decision 002](decisions/002-version-selection-strategy.md) for the rationale.

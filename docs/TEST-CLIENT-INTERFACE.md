# MoQT Test Client Interface Specification

> **This is reference material.** It defines the exact contract test clients must follow. For a guided walkthrough of building a test client, see [IMPLEMENTING-A-TEST-CLIENT.md](./IMPLEMENTING-A-TEST-CLIENT.md).

This document defines the interface that MoQT test clients MUST implement to be compatible with the moq-interop-runner framework.

## Command Line Interface

Test clients SHOULD support the following command-line interface:

```bash
moq-test-client [OPTIONS]

Options:
  -r, --relay <URL>           Relay URL (default: https://localhost:4443)
  -t, --test <NAME>           Run specific test (omit to run all)
  -l, --list                  List available tests
  -v, --verbose               Verbose output
      --tls-disable-verify    Disable TLS certificate verification
```

### URL Schemes

- `https://` - WebTransport over HTTP/3
- `moqt://` - Raw QUIC with ALPN `moq-00`

## Environment Variable Interface

For containerized testing, the following environment variables are supported:

| Variable | Required | Description |
|----------|----------|-------------|
| `RELAY_URL` | Yes | Relay URL (`https://` for WebTransport, `moqt://` for raw QUIC) |
| `TESTCASE` | No | Specific test to run (runs all if not set) |
| `TLS_DISABLE_VERIFY` | No | Set to `1` to skip certificate verification |
| `VERBOSE` | No | Set to `1` for verbose output |
| `MOQT_DRAFT` | No | Confine the client to advertise **only** this draft (e.g. `draft-16`), forcing the negotiated version. When unset, the client uses its default version behavior. |

Environment variables take precedence over command-line defaults but not over explicit command-line arguments.

### Version Confinement (`MOQT_DRAFT`)

The version-pinned interop matrix ([ADR 003](./decisions/003-version-pinned-matrix.md))
tests each implementation against a specific draft, so a result on draft-D's page
genuinely exercises draft D. The harness supplies the target draft to every
container as `MOQT_DRAFT=draft-NN`.

A multi-version **client** SHOULD honor `MOQT_DRAFT` by advertising **only** that
draft in its SETUP. The capability almost always already exists in the
implementation core (a supported-versions list, a pin flag); the step that matters
is for the **interop client** to read `MOQT_DRAFT` and apply it. Reference
mappings (see [version-confinement-audit.md](./version-confinement-audit.md)):

| Client | Maps `MOQT_DRAFT` to |
|--------|----------------------|
| moqx | `MOQX_MOQT_VERSIONS=<NN>` |
| moq-dev-rs | `MOQ_CLIENT_VERSION=moq-transport-<NN>` |
| aiomoqt | `DRAFT=<NN>` |

A registration may instead interpolate the value declaratively
(`${MOQT_DRAFT_NUM}` = the bare number) without changing the client — see ADR 003.

A client that cannot confine to `MOQT_DRAFT` can still be tested at the version it
negotiates. To keep the matrix sound, a client SHOULD report the **actual
negotiated draft** in its run header (`# Draft: draft-NN`), and the harness places
the result by that reported version — never the intended one.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All requested tests passed |
| 1 | One or more tests failed |
| 127 | Test or role not supported by this client |

## Output Format

Test clients MUST output valid [TAP version 14](https://testanything.org/tap-version-14-specification.html) to stdout. See [Decision 001](./decisions/001-tap-output-format.md) for rationale.

TAP is both human-readable and machine-parseable, so there is no separate "machine-parseable" output mode. The harness parses TAP directly.

### Required Elements

Every test run MUST include:

1. **Version line**: `TAP version 14`
2. **Plan**: `1..N` where N is the number of test points
3. **Test points**: One per test case, `ok N - name` or `not ok N - name`

### Run-Level Comments

TAP comment lines (starting with `#`) can appear anywhere in the output and are ignored by harnesses but visible to humans reading the output directly. Test clients SHOULD include identifying information about the test run as comments between the version line and the plan:

```tap
TAP version 14
# moq-test-client v0.1.0
# Relay: https://relay.example.com:4443
# Draft: draft-14
1..3
ok 1 - setup-only
...
```

This preserves the human-readable "header" without affecting test counts or harness behavior.

### Minimal Example

```tap
TAP version 14
# moq-test-client v0.1.0
# Relay: https://relay.example.com:4443
1..3
ok 1 - setup-only
ok 2 - announce-only
not ok 3 - subscribe-error
```

### Skipped Tests

Use the `SKIP` directive for tests the client does not implement:

```tap
TAP version 14
1..3
ok 1 - setup-only
ok 2 - announce-only
ok 3 - publish-namespace-done # SKIP not implemented
```

The harness counts skipped tests separately from passes and failures.

### YAML Diagnostics

YAML diagnostic blocks after test points are OPTIONAL but encouraged, especially for failures. They provide structured metadata the harness can use for richer reporting.

```tap
TAP version 14
1..4
ok 1 - setup-only
  ---
  duration_ms: 24
  connection_id: 84ee7793841adcadd926a1baf1c677cc
  ...
ok 2 - announce-only
  ---
  duration_ms: 31
  connection_id: a1b2c3d4e5f6789
  ...
not ok 3 - subscribe-error
  ---
  duration_ms: 2001
  expected: SUBSCRIBE_ERROR
  received: timeout
  connection_id: def789
  ...
ok 4 - announce-subscribe
  ---
  duration_ms: 145
  publisher_connection_id: abc12345
  subscriber_connection_id: def67890
  ...
```

YAML blocks MUST be indented 2 spaces relative to the test point they follow. Common fields:

| Field | Description |
|-------|-------------|
| `duration_ms` | Test duration in milliseconds |
| `connection_id` | QUIC connection ID for mlog correlation (single-connection tests) |
| `expected` | What the test expected |
| `received` | What actually happened |

#### Connection ID Conventions

Connection IDs in YAML diagnostics enable correlation with relay-side mlog/qlog traces. The naming convention depends on the test topology:

- **Single-connection tests** use `connection_id`:
  ```yaml
  connection_id: 84ee7793841adcadd926a1baf1c677cc
  ```

- **Multi-connection tests** use `<role>_connection_id`, where `<role>` is the logical role defined by the test case (e.g., `publisher`, `subscriber`):
  ```yaml
  publisher_connection_id: abc12345
  subscriber_connection_id: def67890
  ```

The expected roles for each test case are documented in [TEST-CASES.md](./tests/TEST-CASES.md). Implementations SHOULD name connections by role rather than by connection order to avoid fragile positional coupling — the output code should not need to know which role connects first.

Future tests with multiple connections in the same role (e.g., two subscribers) SHOULD use numbered suffixes: `subscriber_1_connection_id`, `subscriber_2_connection_id`.

**Partial failure**: Connection IDs are best-effort. If a test fails partway through, include whatever connection IDs were successfully captured before the failure. For example, if the publisher connects but the subscriber fails:

```tap
not ok 5 - announce-subscribe
  ---
  duration_ms: 3001
  publisher_connection_id: abc12345
  message: "subscriber connection failed"
  ...
```

### Subtests

Subtests are OPTIONAL. They are useful for multi-step tests where intermediate visibility helps debugging:

```tap
TAP version 14
1..2
ok 1 - setup-only
# Subtest: announce-subscribe
    1..4
    ok 1 - publisher connected
    ok 2 - publisher announced namespace
    ok 3 - subscriber connected
    ok 4 - subscriber received object
ok 2 - announce-subscribe
```

The harness determines pass/fail from the correlated test point at the parent level. Subtests are indented 4 spaces.

### Bail Out

If a fatal error makes further testing pointless (e.g., relay is unreachable), use `Bail out!`:

```tap
TAP version 14
1..5
ok 1 - setup-only
Bail out! Relay connection refused
```

The harness MUST treat a bail out as a failed test run.

### List Output

When `--list` is specified, output one test identifier per line (not TAP format):

```
setup-only
announce-only
publish-namespace-done
subscribe-error
announce-subscribe
subscribe-before-announce
```

This enables the runner to discover which tests a client supports.

## Timeout Handling

Test clients MUST implement timeouts to prevent hanging:

- Individual tests SHOULD timeout after their specified duration (see test case specs)
- If no timeout is specified, default to 5 seconds
- On timeout, report the test as failed with a clear message in the YAML diagnostics

## Error Reporting

When tests fail, include diagnostic context via YAML blocks:

```tap
not ok 2 - announce-only
  ---
  duration_ms: 2001
  expected: PUBLISH_NAMESPACE_OK
  received: timeout
  message: "no response after 2000 ms"
  connection_id: 84ee7793841adcadd926a1baf1c677cc
  ...
```

For protocol errors:

```tap
not ok 3 - subscribe-error
  ---
  duration_ms: 45
  expected: SUBSCRIBE_ERROR
  received: SUBSCRIBE_OK
  message: "unexpected success"
  connection_id: 84ee7793841adcadd926a1baf1c677cc
  ...
```

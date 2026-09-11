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

The current runner accepts both `https://` and `moqt://` relay URLs because
implementations span several generations of the protocol:

- Through MoQT draft 17, `https://` identifies a WebTransport endpoint and
  `moqt://` identifies a native QUIC endpoint.
- Beginning with draft 18, `moqt://` is the canonical URI scheme for both
  transports. A client can offer native MoQT ALPNs and `h3` on QUIC; selecting
  `h3` leads the client to derive an `https://` URI and establish WebTransport.

Many current clients still use the URI scheme as their transport selector. The
runner therefore continues to accept `https://` as a legacy WebTransport
locator, including for implementations of newer drafts that have not adopted
the unified URI behavior. New draft 18 and later integrations should use
`moqt://`. A planned runner interface will constrain native QUIC or
WebTransport independently of the URI; until then, adapters may translate the
canonical URI to the locator a client expects. See
[Decision 003](./decisions/003-url-scheme-transport-selection.md) for the
migration plan.

## Environment Variable Interface

For containerized testing, the following environment variables are supported:

| Variable | Required | Description |
|----------|----------|-------------|
| `RELAY_URL` | Yes | Relay locator; accepted schemes and compatibility behavior are described above |
| `TESTCASE` | No | Specific test to run (runs all if not set) |
| `TLS_DISABLE_VERIFY` | No | Set to `1` to skip certificate verification |
| `VERBOSE` | No | Set to `1` for verbose output |

Environment variables take precedence over command-line defaults but not over explicit command-line arguments.

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

YAML diagnostic blocks after test points are OPTIONAL but encouraged, especially
for failures. They are the preferred place for structured metadata because they
do not interfere with TAP parsing.

[TAP YAML Metadata](./TAP-YAML-METADATA.md) defines additional common
field names. All fields remain optional, and the runner ignores unknown fields.

```tap
TAP version 14
1..4
ok 1 - setup-only
  ---
  duration_ms: 24
  sessions:
    client:
      moqt_version: "moqt-18"
      transport: "quic"
      quic_initial_destination_connection_id: "84ee7793841adcadd926a1baf1c677cc"
  ...
ok 2 - announce-only
  ---
  duration_ms: 31
  sessions:
    publisher:
      quic_initial_destination_connection_id: "a1b2c3d4e5f67890"
  ...
not ok 3 - subscribe-error
  ---
  duration_ms: 2001
  message: "timed out waiting for REQUEST_ERROR"
  sessions:
    subscriber:
      quic_initial_destination_connection_id: "def7890123456789"
  ...
ok 4 - announce-subscribe
  ---
  duration_ms: 145
  sessions:
    publisher:
      quic_initial_destination_connection_id: "abc1234567890def"
    subscriber:
      quic_initial_destination_connection_id: "def6789012345abc"
  ...
```

YAML blocks MUST be indented 2 spaces relative to the test point they follow.
Each prose specification linked from the [test catalog](./tests/README.md)
defines its logical session roles. Use those names as keys under `sessions`
rather than identifying sessions by connection order. If a test has two roles
of the same kind, its specification assigns distinct names such as
`subscriber_1` and `subscriber_2`.

**Partial failure**: QUIC Initial Destination Connection IDs are best-effort.
Include whatever IDs were captured before the failure and omit the field for
non-QUIC sessions or when the implementation does not expose it. For example,
if the publisher connects but the subscriber fails:

```tap
not ok 5 - announce-subscribe
  ---
  duration_ms: 3001
  message: "subscriber connection failed"
  sessions:
    publisher:
      quic_initial_destination_connection_id: "abc1234567890def"
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
rendezvous-timeout
announce-subscribe
subscribe-before-announce
```

This enables the runner to discover which tests a client supports.

## Timeout Handling

Test clients MUST implement timeouts to prevent hanging:

- Individual tests SHOULD timeout after their specified duration (see test case specs)
- If no timeout is specified, default to 5 seconds
- On timeout, report the test as failed. A client MAY include a clear message in
  optional YAML diagnostics.

## Error Reporting

When tests fail, clients SHOULD include diagnostic context. Optional YAML blocks
are the preferred way to provide structured details:

```tap
not ok 2 - announce-only
  ---
  duration_ms: 2001
  message: "timed out waiting for REQUEST_OK after 2000 ms"
  sessions:
    publisher:
      quic_initial_destination_connection_id: "84ee7793841adcadd926a1baf1c677cc"
  ...
```

For protocol errors:

```tap
not ok 3 - subscribe-error
  ---
  duration_ms: 45
  message: "received SUBSCRIBE_OK instead of REQUEST_ERROR"
  sessions:
    subscriber:
      quic_initial_destination_connection_id: "84ee7793841adcadd926a1baf1c677cc"
  ...
```

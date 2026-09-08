# Decision: TAP as the Test Client Output Format

**Date:** 2026-02-06

## Problem

The moq-interop-runner needs a standardized output format for test clients. Without one, every test client author invents their own output, making it difficult for the harness to parse results and for humans to compare behavior across implementations.

## Goals

These aren't formal requirements -- they're the properties we want the format to have:

1. **Useful outside the harness.** Test clients should be valuable standalone tools. A developer debugging their relay should be able to point a test client at it and get clear, readable output without needing the full interop runner infrastructure.

2. **Streaming.** Results should appear as tests complete, not batched at the end. This matters both for CI (seeing progress) and for manual debugging (knowing which test is hanging).

3. **Human-readable.** Someone running a test client in a terminal should be able to understand the output without piping it through a formatter.

4. **Machine-parseable.** The harness needs to reliably extract pass/fail/skip status and optional metadata from test client output.

5. **Extensible metadata.** We want a path toward richer output (connection IDs, timing, mlog file paths) without breaking basic consumers or requiring all implementations to support everything at once.

6. **Low implementation burden.** Test client authors shouldn't need to write significant output formatting code. Ideally they can use an existing library.

## Decision

We use [TAP version 14](https://testanything.org/tap-version-14-specification.html) (Test Anything Protocol) as the required output format for MoQT test clients.

## Alternatives Considered

### Custom format (previous approach)

The earlier spec defined a custom format with checkmarks and a final `MOQT_TEST_RESULT: SUCCESS` line.

```
✓ setup-only (24 ms)
✗ subscribe-error (timeout)
MOQT_TEST_RESULT: SUCCESS
```

Simple, but no ecosystem support, no standard for failure details, and limited extensibility.

### JSON Lines

```json
{"test": "setup-only", "status": "pass", "duration_ms": 24}
{"test": "subscribe-error", "status": "fail", "error": "timeout"}
```

Fully structured and easy to aggregate, but less human-readable and no established standard to point people at. Every consumer would need custom parsing logic.

### JUnit XML

Excellent CI integration, but batch-only (can't stream results), verbose, and XML parsing is heavier than text parsing. Poor fit for a standalone debugging tool.

## Rationale

TAP hits all the goals well:

- **Standalone utility.** TAP output reads naturally in a terminal. A developer can run `moq-test-client -r https://some-relay:4443` and immediately see which tests pass and which fail, with optional detail on failures. No special tooling required to understand the output.

- **Streaming by design.** Each test point is a single line emitted as the test completes. A human watching a terminal or a CI system tailing logs sees progress in real time.

- **YAML diagnostics.** TAP14 supports optional YAML blocks after any test point.
  This provides extensible session, timing, and failure context without
  complicating the base format. Basic parsers that don't understand YAML still
  work fine.

- **SKIP and TODO directives.** `SKIP` maps directly to "this test client doesn't implement this test case." `TODO` could represent known issues. The harness can distinguish "not implemented" from "failed" without inventing custom conventions.

- **Ecosystem.** TAP parsers exist in Rust, Go, C, Python, JavaScript, and many other languages. Test client authors can often use an existing library. CI systems like GitHub Actions and Jenkins have TAP support.

- **Subtests.** TAP14 supports nested subtests. We don't require them, but implementations that want to report sub-steps of complex tests (e.g., "publisher connected", "subscriber received object") can do so in a standard way. This makes test clients more useful as debugging tools.

## What This Means in Practice

### For test client implementers

- Output valid TAP version 14 to stdout
- Each test case = one test point (`ok N - test-name` or `not ok N - test-name`)
- Use `# SKIP reason` for unimplemented tests
- YAML diagnostics are optional but encouraged for failure context
- Subtests are optional; useful for multi-step tests where intermediate visibility helps
- Exit 0 if all tests pass, non-zero otherwise

### For the test harness

- Parse TAP from test client stdout
- Aggregate results across client/relay pairs into existing JSON/HTML reports
- The harness itself does not need to produce TAP (it has its own reporting)

### Required granularity

Test results are required at the **test case level** (one TAP test point per test case). We don't require finer granularity because different implementations may have difficulty breaking the same test into identical sub-steps while also producing intermediate output.

Subtests are fully optional. Implementations that find them useful for debugging are encouraged to use them, but the harness will not depend on their presence.

## Example Output

Minimal:

```tap
TAP version 14
1..3
ok 1 - setup-only
ok 2 - announce-only
not ok 3 - subscribe-error
```

With diagnostics:

```tap
TAP version 14
1..3
ok 1 - setup-only
  ---
  duration_ms: 24
  sessions:
    client:
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
```

With optional subtests:

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

Skipped tests:

```tap
TAP version 14
1..3
ok 1 - setup-only
ok 2 - announce-only
ok 3 - publish-namespace-done # SKIP not implemented
```

## Future Directions

These are ideas, not commitments. The currently optional common YAML field names
are documented in [TAP-YAML-METADATA.md](../TAP-YAML-METADATA.md); TAP output
without YAML remains valid and sufficient for the current basic interop report.

- **Output linting.** A tool that validates test client TAP output against the spec and any MoQT-specific conventions. Could catch issues before they surface as mysterious harness failures.

- **mlog correlation.** YAML diagnostics can include mlog file paths. Future work could correlate TAP results with qlog/mlog events for deeper analysis.

## References

- [TAP Version 14 Specification](https://testanything.org/tap-version-14-specification.html)
- [TAP Producers by Language](https://testanything.org/producers.html)
- [TAP Consumers](https://testanything.org/consumers.html)

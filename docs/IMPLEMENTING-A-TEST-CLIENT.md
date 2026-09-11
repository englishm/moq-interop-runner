# Implementing a MoQT Test Client

> **This is a how-to guide for test client authors.** If you just want to run existing tests against your relay, see [Getting Started](./GETTING-STARTED.md). For the exact interface specification, see [TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md).

This guide explains how to implement a test client for your MoQT stack that's compatible with the moq-interop-runner framework.

## Why Standardized Test Cases?

Most MoQT implementations already have CLI tools (moq-rs has `moq-pub`/`moq-sub`/`moq-clock`, moxygen has `moqtest_client`, etc.), but each exercises different scenarios with different output. The goal here is **multiple implementations of the *same* test cases** — standard identifiers (`setup-only`, `announce-subscribe`, ...) with precise success criteria so we can automate the full client x relay matrix with machine-parseable results instead of ad-hoc commands and manual spreadsheet tracking.

If you already have a MoQT implementation, building a test client mostly means
wiring your existing protocol logic to scenarios in the
[test catalog](./tests/README.md).

## Overview

A test client is a standalone executable that:

1. Connects to a MoQT relay
2. Executes one or more test cases
3. Reports results in a standard format

The test client handles both test execution AND result validation - it determines whether each test passed or failed.

## Interface Requirements

Your test client MUST implement the interface defined in [TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md):

- Parse command line arguments or environment variables
- Output results in the expected format
- Return appropriate exit codes

## Test Case Implementation

For each test case you support, follow the prose specification linked from the
[test catalog](./tests/README.md). Existing tests remain collected in
[TEST-CASES.md](./tests/TEST-CASES.md).

### Example: `setup-only`

```python
def test_setup_only(relay_url):
    """Verify basic connection and SETUP exchange."""
    start = time.now()
    
    try:
        # 1. Connect to relay
        conn = connect(relay_url, timeout=2.0)
        
        # 2. Send CLIENT_SETUP
        conn.send_client_setup(supported_versions=[DRAFT_14])
        
        # 3. Receive SERVER_SETUP
        msg = conn.recv(timeout=2.0)
        if msg.type != SERVER_SETUP:
            return TestResult.fail(
                f"Expected SERVER_SETUP, got {msg.type}",
                duration=time.now() - start,
                sessions={"client": {
                    "quic_initial_destination_connection_id": conn.initial_dcid
                }}
            )
        
        # 4. Close gracefully
        conn.close()
        
        return TestResult.pass(
            duration=time.now() - start,
            sessions={"client": {
                "quic_initial_destination_connection_id": conn.initial_dcid
            }}
        )
        
    except Timeout:
        return TestResult.fail(
            "Timeout waiting for SERVER_SETUP",
            duration=time.now() - start
        )
    except Exception as e:
        return TestResult.fail(
            str(e),
            duration=time.now() - start
        )
```

### Example: `subscribe-error`

This test expects an error response - the test passes when the relay returns SUBSCRIBE_ERROR:

```python
def test_subscribe_error(relay_url):
    """Verify relay returns error for non-existent track."""
    start = time.now()
    
    try:
        conn = connect(relay_url)
        conn.send_client_setup(supported_versions=[DRAFT_14])
        conn.recv_server_setup()
        
        # Subscribe to a namespace that doesn't exist
        conn.send_subscribe(
            namespace="nonexistent/namespace",
            track="test-track"
        )
        
        msg = conn.recv(timeout=2.0)
        
        if msg.type == SUBSCRIBE_ERROR:
            # This is the EXPECTED outcome - test passes!
            conn.close()
            return TestResult.pass(
                duration=time.now() - start,
                sessions={"subscriber": {
                    "quic_initial_destination_connection_id": conn.initial_dcid
                }}
            )
        elif msg.type == SUBSCRIBE_OK:
            # Unexpected success
            return TestResult.fail(
                "Expected SUBSCRIBE_ERROR, got SUBSCRIBE_OK",
                duration=time.now() - start,
                sessions={"subscriber": {
                    "quic_initial_destination_connection_id": conn.initial_dcid
                }}
            )
        else:
            return TestResult.fail(
                f"Unexpected message type: {msg.type}",
                duration=time.now() - start,
                sessions={"subscriber": {
                    "quic_initial_destination_connection_id": conn.initial_dcid
                }}
            )
            
    except Timeout:
        return TestResult.fail(
            "Timeout waiting for SUBSCRIBE_ERROR",
            duration=time.now() - start
        )
```

### Example: `announce-subscribe` (Multi-Connection)

Some tests require multiple concurrent connections:

```python
def test_announce_subscribe(relay_url):
    """Verify relay routes subscription to publisher."""
    start = time.now()
    
    namespace = "moq-test/interop"
    track = "test-track"
    
    try:
        # Publisher connection
        pub = connect(relay_url)
        pub.send_client_setup(supported_versions=[DRAFT_14])
        pub.recv_server_setup()
        
        # Publisher announces namespace
        pub.send_publish_namespace(namespace)
        msg = pub.recv(timeout=2.0)
        if msg.type != PUBLISH_NAMESPACE_OK:
            return TestResult.fail(
                f"Publisher: expected PUBLISH_NAMESPACE_OK, got {msg.type}"
            )
        
        # Subscriber connection
        sub = connect(relay_url)
        sub.send_client_setup(supported_versions=[DRAFT_14])
        sub.recv_server_setup()
        
        # Subscriber subscribes
        sub.send_subscribe(namespace, track)
        msg = sub.recv(timeout=2.0)
        
        if msg.type == SUBSCRIBE_OK:
            pub.close()
            sub.close()
            return TestResult.pass(
                duration=time.now() - start,
                sessions={
                    "publisher": {
                        "quic_initial_destination_connection_id": pub.initial_dcid
                    },
                    "subscriber": {
                        "quic_initial_destination_connection_id": sub.initial_dcid
                    },
                }
            )
        else:
            return TestResult.fail(
                f"Subscriber: expected SUBSCRIBE_OK, got {msg.type}"
            )
            
    except Timeout:
        return TestResult.fail("Timeout", duration=time.now() - start)
```

## Output Formatting

Test clients output [TAP version 14](https://testanything.org/tap-version-14-specification.html). See [TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md) for the full specification.

### Main Entry Point

```python
def main():
    args = parse_args()  # or parse environment variables

    tests_to_run = get_tests(args.test)  # specific test or all

    # TAP header and run-level comments
    print("TAP version 14")
    print(f"# {CLIENT_NAME} v{CLIENT_VERSION}")
    print(f"# Relay: {args.relay_url}")
    print(f"1..{len(tests_to_run)}")

    failed = 0
    for i, test in enumerate(tests_to_run, 1):
        result = run_test(test, args.relay_url)
        print(format_tap_result(i, result))
        if not result.passed:
            failed += 1

    sys.exit(1 if failed > 0 else 0)


def format_tap_result(number, result):
    """Format a test result as a TAP test point with optional YAML diagnostics."""
    status = "ok" if result.passed else "not ok"
    line = f"{status} {number} - {result.name}"

    # Add SKIP directive if applicable
    if result.skipped:
        line += f" # SKIP {result.skip_reason}"
        return line

    # Use a YAML library so arbitrary diagnostic strings are escaped safely.
    metadata = {}
    if result.duration_ms is not None:
        metadata["duration_ms"] = result.duration_ms
    if result.sessions:
        metadata["sessions"] = result.sessions
    if not result.passed and result.message:
        metadata["message"] = result.message

    if metadata:
        rendered = yaml.safe_dump(metadata, sort_keys=False).rstrip()
        line += "\n  ---\n"
        line += textwrap.indent(rendered, "  ")
        line += "\n  ..."

    return line
```

## Timeouts

Each test case specifies a timeout. Implement timeouts at multiple levels:

1. **Connection timeout**: How long to wait for initial connection
2. **Message timeout**: How long to wait for each expected message
3. **Test timeout**: Overall timeout for the entire test

Don't let tests hang indefinitely - always fail with a clear timeout message.

## TLS Configuration

When `--tls-disable-verify` is set (or `TLS_DISABLE_VERIFY=1`), disable certificate verification. This is necessary for testing with self-signed certificates in containerized environments.

## QUIC Connection ID Extraction

Include the client's QUIC Initial Destination Connection ID under the logical
session role when the QUIC stack exposes it. APIs differ by stack; use the
Destination Connection ID from the client's first QUIC Initial packet, not a
process-local connection handle. Omit the field for non-QUIC sessions or when
the value is unavailable. Encode the bytes as lowercase hexadecimal without
separators or a `0x` prefix:

```python
# Pseudocode; use the equivalent API in your QUIC stack.
cid = connection.initial_destination_connection_id()
```

In TAP output, the connection ID appears in the YAML diagnostics:

```tap
ok 1 - setup-only
  ---
  duration_ms: 24
  sessions:
    client:
      quic_initial_destination_connection_id: "84ee7793841adcadd926a1baf1c677cc"
  ...
```

For multi-connection tests, include both IDs:

```tap
ok 2 - announce-subscribe
  ---
  duration_ms: 156
  sessions:
    publisher:
      quic_initial_destination_connection_id: "abc1234567890def"
    subscriber:
      quic_initial_destination_connection_id: "def6789012345abc"
  ...
```

## Docker Considerations

When containerizing your test client:

1. **Entry point**: Parse `RELAY_URL`, `TESTCASE`, `TLS_DISABLE_VERIFY` from environment
2. **DNS resolution**: The relay hostname must be resolvable within the Docker network
3. **Exit code**: Ensure your container exits with the correct code (0 or 1)

Example Dockerfile pattern:

```dockerfile
FROM rust:1.75 as builder
WORKDIR /app
COPY . .
RUN cargo build --release --bin moq-test-client

FROM debian:bookworm-slim
COPY --from=builder /app/target/release/moq-test-client /usr/local/bin/
ENTRYPOINT ["moq-test-client"]
```

## Example Implementation

See [moq-test-client](https://github.com/cloudflare/moq-rs/tree/main/moq-test-client) in the moq-rs repository for a complete Rust implementation.

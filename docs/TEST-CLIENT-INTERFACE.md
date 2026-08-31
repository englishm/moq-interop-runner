# MoQT Test Client Interface Specification

> **This is reference material.** It defines the test-client contract. For implementation guidance, see [IMPLEMENTING-A-TEST-CLIENT.md](./IMPLEMENTING-A-TEST-CLIENT.md).

## Command-Line Interface

Test clients SHOULD provide the following equivalent command-line interface:

```text
test-client [OPTIONS]

Options:
  -r, --relay <URL>           Relay URL
  -t, --test <ID>             Select one semantic test ID
  -l, --list                  List supported semantic test IDs
  -v, --verbose               Emit verbose diagnostics
      --tls-disable-verify    Disable TLS certificate verification
```

`moqt://` selects native QUIC. `https://` selects WebTransport over HTTP/3. Draft and protocol negotiation still follow the selected test and registered endpoint; clients MUST NOT infer a fixed ALPN from the URL scheme alone.

Explicit command-line arguments take precedence over environment variables. The client MUST use the relay URL exactly as supplied except for parsing required to establish the indicated transport.

## Environment Variables

Containerized clients use this interface:

| Variable | Required | Description |
|----------|----------|-------------|
| `RELAY_URL` | Yes | Relay URL used by every logical session in the invocation |
| `TESTCASE` | No | Exact semantic test ID; when omitted, run all tests supported by the client |
| `TLS_DISABLE_VERIFY` | No | Set to `1` to disable certificate verification |
| `VERBOSE` | No | Set to `1` for verbose diagnostics |

## Invocation and Image Model

The runner registers and invokes one client image. No separate publisher image or publisher registry role is required.

One client invocation owns and coordinates all logical roles needed by its selected tests. For a publisher/subscriber data-plane test, that invocation MUST establish both logical MoQT sessions against the same `RELAY_URL`. The roles MAY run in one process or in coordinated subprocesses within the same image.

The current runner starts the client image once for each client/relay endpoint run without setting `TESTCASE` or calling `--list`, so the client runs all tests it supports. The `--list` and `TESTCASE` interfaces also support direct and per-case invocation.

## Semantic Test IDs

Test IDs are defined by the test specifications. Their spelling MUST be identical across `--list`, `TESTCASE`, and the corresponding TAP test-point name. Clients MUST use them directly.

`--list` outputs one supported semantic test ID per line, without TAP framing. A selected known test that the client does not support MUST produce a TAP `SKIP` point under that exact ID. An ID absent from the test specifications is unknown and MUST exit `127`.

When `TESTCASE` is omitted, the invocation runs all semantic tests supported by the client.

## Data-Plane Test Contract

This section applies to the seven tests defined in [tests/DATA-PLANE.md](./tests/DATA-PLANE.md).

### Run-Scoped Track

Each test run MUST create a fresh 128-bit Run ID with a cryptographically secure random generator and represent it as exactly 32 lowercase hexadecimal characters. Generation failure MUST fail the test; clients MUST NOT fall back to a timestamp, counter, process ID, or fixed value. Both roles MUST use this Full Track Name:

- Track Namespace tuple: `("moq-interop", <semantic-test-id>)`
- Track Name: `<run-id>`

The tuple components are MoQT namespace fields, not a path string. The random Track Name isolates concurrent runs and stale relay state within the test's namespace.

### Rendezvous

The client MUST coordinate the roles in this order:

1. Establish the subscriber session and send an exact-track `SUBSCRIBE` for the run-scoped Full Track Name with a bounded rendezvous timeout.
2. Confirm that the complete `SUBSCRIBE` request has been flushed to the transport before allowing publication to begin. Waiting only for local request construction is insufficient.
3. Establish the publisher session and send direct `PUBLISH` for the same Full Track Name.
4. Require a successful PUBLISH response and record its effective Forward State. An omitted `FORWARD` parameter has effective value `1`.
5. If the PUBLISH response had Forward State `0`, continue processing the PUBLISH request stream concurrently with the subscriber wait, require `REQUEST_UPDATE` to set Forward State `1`, and respond successfully to that update. Do not wait for `SUBSCRIBE_OK` before acknowledging the update.
6. Independently require `SUBSCRIBE_OK`.
7. Do not publish Objects until the publisher's effective Forward State is `1` and the subscriber has received `SUBSCRIBE_OK`.

A rejection, a non-success PUBLISH response, failure to reach effective Forward State `1`, failure to receive `SUBSCRIBE_OK`, an Object sent while Forward State is `0`, or expiry of a bounded wait fails the test.

### Fixtures and Verification

The selected fixture vector supplies the expected data. It identifies its revision and algorithm-qualified digest and describes subgroup streams, Object coordinates, per-subgroup Object order, payload bytes, and terminal state. The digest covers `target_draft`, `normative_source`, `schema_digest`, common vector rules, and the selected test after omitting its `vector_digest` member, serialized as compact UTF-8 JSON with object keys recursively sorted in lexical order and no trailing line terminator.

The publisher fixture MUST consume the explicit vector selected for the run. The verifier MUST independently compare subscriber-side decoded observations directly with that same vector. It MUST NOT obtain expected values from publisher output, publisher logs, a publisher generator, or a generator/lattice traversal shared with the publisher.

Objects are ordered within a subgroup stream. There is no required global order between different subgroup streams; a verifier MUST accept any cross-stream interleaving that preserves each subgroup's order and matches the vector.

### Completion

The publisher MUST:

1. Close every opened subgroup stream with FIN after writing its vector objects.
2. Send `PUBLISH_DONE`/`TRACK_ENDED` with Stream Count equal to the exact number of subgroup streams opened for that publication.
3. Finish the PUBLISH request stream after `PUBLISH_DONE`/`TRACK_ENDED`.

The subscriber MUST use Stream Count to retain completion state until every counted subgroup stream has closed and has been verified. `PUBLISH_DONE`/`TRACK_ENDED` can be observed before one or more counted subgroup streams because control and data streams are independently delivered; this ordering is not a failure. It MUST also require FIN after PUBLISH_DONE on the SUBSCRIBE request stream's response direction.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Every executed test passed or was skipped |
| `1` | One or more executed tests failed |
| `127` | The selected semantic test ID is unknown |

## TAP Output

Test clients MUST write valid [TAP version 14](https://testanything.org/tap-version-14-specification.html) to stdout. TAP is the machine-readable and human-readable result format.

Every run MUST include:

1. `TAP version 14`
2. A plan, `1..N`
3. One `ok N - <semantic-test-id>` or `not ok N - <semantic-test-id>` point per reported test

Known unsupported tests use TAP `SKIP`:

```tap
TAP version 14
1..1
ok 1 - publish-to-pending-subscription # SKIP not supported
```

Run-level comments MAY identify the invocation:

```tap
TAP version 14
# Relay: https://relay.example.test:4443
# Target draft: draft-18
1..1
ok 1 - setup-only
```

### YAML Diagnostics

YAML diagnostic blocks are OPTIONAL generally. Successful executed tests defined in [tests/DATA-PLANE.md](./tests/DATA-PLANE.md) MUST include a diagnostic block. Failed data-plane tests include every field captured before failure; skipped tests do not require diagnostics. Blocks MUST be indented two spaces relative to the test point.

#### Connection ID Conventions

Single-session tests use `connection_id`. Tests with multiple logical sessions use `<role>_connection_id`, such as `publisher_connection_id` and `subscriber_connection_id`, regardless of connection order. A failure reports every connection ID captured before it occurred.

Data-plane diagnostics MUST include:

| Field | Meaning |
|-------|---------|
| `publisher_connection_id` | Publisher-role QUIC connection ID |
| `subscriber_connection_id` | Subscriber-role QUIC connection ID |
| `run_id` | Fresh 128-bit Run ID as 32 lowercase hexadecimal characters |
| `target_draft` | Draft targeted by the test invocation |
| `publisher_negotiated_draft` | Draft negotiated by the publisher session |
| `subscriber_negotiated_draft` | Draft negotiated by the subscriber session |
| `vector_revision` | Selected vector revision, copied verbatim |
| `vector_digest` | Selected algorithm-qualified vector digest, copied verbatim |

Failures SHOULD also report `duration_ms`, `expected`, `received`, and a concise `message`. On partial failure, include every diagnostic value captured before the failure.

```tap
TAP version 14
1..1
ok 1 - subscribe-one-subgroup-per-group
  ---
  publisher_connection_id: abc12345
  subscriber_connection_id: def67890
  run_id: 0123456789abcdef0123456789abcdef
  target_draft: draft-18
  publisher_negotiated_draft: draft-18
  subscriber_negotiated_draft: draft-18
  vector_revision: 1
  vector_digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  ...
```

## Timeouts and Fatal Errors

Every connection, protocol wait, role rendezvous, and complete test MUST have a finite timeout. Use the timeout specified by the semantic test; where none is specified, use five seconds. A timeout is a failed TAP point with diagnostic context.

If a run-level failure makes further testing impossible, the client MAY emit `Bail out!` and MUST exit with code `1`.

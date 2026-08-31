# MoQT Interoperability Test Cases

> **This is the reference specification for test cases.** To propose new test cases, open a PR against this file. To implement these tests in your MoQT stack, see [IMPLEMENTING-A-TEST-CLIENT.md](../IMPLEMENTING-A-TEST-CLIENT.md).

This document defines interoperability test cases for Media over QUIC Transport (MoQT). These specifications are designed to be implementation-neutral and precise enough that any MoQT implementation can build a compatible test client.

**Target Draft**: `draft-18`
**Identifier Semantics Reviewed For**: `draft-18`

**Protocol Reference**: [draft-ietf-moq-transport-18](https://www.ietf.org/archive/id/draft-ietf-moq-transport-18.html)

> **Note**: Section references (e.g., "MoQT-18 §10.3") refer to the draft version above. Message names use the current draft-18 terminology. Where the draft defines request-specific aliases such as `PUBLISH_NAMESPACE_OK`, those aliases refer to a `REQUEST_OK` response.

## Test Case Format

Each test case follows this structure:

- **Heading**: The test identifier (machine-readable name used in CLI and results)
- **Protocol References**: Relevant MoQT draft sections
- **Procedure**: Step-by-step behavior
- **Success Criteria**: What constitutes a pass
- **Diagnostic Roles**: For multi-connection tests, the named roles for connection ID reporting (see [Connection ID Conventions](../TEST-CLIENT-INTERFACE.md#connection-id-conventions))
- **mlog Events**: Suggested qlog/mlog events for validation (optional)

---

## Category: Session Establishment

### `setup-only`

**Protocol References**: MoQT-18 §3.3 (Session initialization), §10.3 (SETUP)

**Procedure**:

1. Connect to relay via WebTransport (or raw QUIC)
2. Send SETUP on the control stream
3. Receive the peer's SETUP message
4. Close connection gracefully

**Success Criteria**:

- Peer SETUP received successfully
- Connection closes without error

**Timeout**: 2 seconds

**mlog Events** (relay-side, suggested):

```json
{"name":"moqt:control_message_parsed","data":{"message_type":"client_setup",...}}
{"name":"moqt:control_message_created","data":{"message_type":"server_setup",...}}
```

---

## Category: Namespace Publishing

### `announce-only`

**Protocol References**: MoQT-18 §6.2 (Publishing Namespaces), §10.15 (PUBLISH_NAMESPACE), §10.5 (REQUEST_OK / `PUBLISH_NAMESPACE_OK` alias)

**Procedure**:

1. Connect and complete SETUP exchange
2. Send PUBLISH_NAMESPACE for test namespace
3. Wait for REQUEST_OK (`PUBLISH_NAMESPACE_OK`)
4. Close connection gracefully

**Test Namespace**: `moq-test/interop`

**Success Criteria**:

- REQUEST_OK (`PUBLISH_NAMESPACE_OK`) received
- No error response

**Timeout**: 2 seconds after sending PUBLISH_NAMESPACE

**mlog Events** (relay-side, suggested):

```json
{"name":"moqt:control_message_parsed","data":{"message_type":"publish_namespace",...}}
{"name":"moqt:control_message_created","data":{"message_type":"publish_namespace_ok",...}}
```

---

### `publish-namespace-done`

**Protocol References**: MoQT-18 §6.2 (Publishing Namespaces), §10.15 (PUBLISH_NAMESPACE), §10.5 (REQUEST_OK / `PUBLISH_NAMESPACE_OK` alias), §3.3.2 (Request Cancellation and Rejection)

**Procedure**:

1. Connect and complete SETUP exchange
2. Send PUBLISH_NAMESPACE for test namespace
3. Wait for REQUEST_OK (`PUBLISH_NAMESPACE_OK`)
4. Withdraw the namespace by cancelling the request stream
5. Close connection gracefully

**Test Namespace**: `moq-test/interop`

**Success Criteria**:

- REQUEST_OK (`PUBLISH_NAMESPACE_OK`) received
- Request stream cancelled cleanly to withdraw the namespace
- Clean disconnection

**Timeout**: 2 seconds after sending PUBLISH_NAMESPACE

---

## Category: Subscriptions

### `subscribe-error`

**Protocol References**: MoQT-18 §5.1 (Subscriptions), §10.7 (SUBSCRIBE), §10.6 (REQUEST_ERROR)

**Procedure**:

1. Connect and complete SETUP exchange
2. Send SUBSCRIBE for non-existent namespace/track
3. Expect REQUEST_ERROR response
4. Close connection gracefully

**Test Namespace**: `nonexistent/namespace`  
**Test Track**: `test-track`

**Success Criteria**:

- REQUEST_ERROR received (this is the expected behavior)
- Exit code 0 (the error was expected and correctly handled)

**Timeout**: 2 seconds

**mlog Events** (relay-side, suggested):

```json
{"name":"moqt:control_message_parsed","data":{"message_type":"subscribe",...}}
{"name":"moqt:control_message_created","data":{"message_type":"subscribe_error",...}}
```

---

### `announce-subscribe`

**Protocol References**: MoQT-18 §5.1 (Subscriptions), §6.2 (Publishing Namespaces), §10.7-10.8 (SUBSCRIBE/SUBSCRIBE_OK), §10.15 (PUBLISH_NAMESPACE), §10.5 (REQUEST_OK / `PUBLISH_NAMESPACE_OK` alias)

**Topology**: Two concurrent connections (publisher + subscriber)

**Publisher Procedure**:

1. Connect and complete SETUP exchange
2. Send PUBLISH_NAMESPACE for test namespace
3. Wait for REQUEST_OK (`PUBLISH_NAMESPACE_OK`)
4. Wait for subscription or timeout

**Subscriber Procedure**:

1. Connect and complete SETUP exchange
2. Send SUBSCRIBE for test namespace/track
3. Wait for SUBSCRIBE_OK or REQUEST_ERROR

**Test Namespace**: `moq-test/interop`  
**Test Track**: `test-track`

**Success Criteria**:

- Both connections complete SETUP
- Publisher receives REQUEST_OK (`PUBLISH_NAMESPACE_OK`)
- Subscriber receives SUBSCRIBE_OK (relay routes subscription to publisher)

**Timeout**: 3 seconds total

**Diagnostic Roles**: `publisher`, `subscriber` — report as `publisher_connection_id` and `subscriber_connection_id` in YAML diagnostics

---

### `subscribe-before-announce`

**Protocol References**: MoQT-18 §5.1 (Subscriptions), §6.2 (Publishing Namespaces), §10.7 (SUBSCRIBE), §10.6 (REQUEST_ERROR), §10.15 (PUBLISH_NAMESPACE), §10.5 (REQUEST_OK / `PUBLISH_NAMESPACE_OK` alias)

**Topology**: Two connections, subscriber connects first

**Subscriber Procedure**:

1. Connect and complete SETUP exchange
2. Send SUBSCRIBE for test namespace/track (publisher hasn't announced yet)
3. Wait for response

**Publisher Procedure** (starts 500ms after subscriber):

1. Connect and complete SETUP exchange
2. Send PUBLISH_NAMESPACE for test namespace
3. Wait for REQUEST_OK (`PUBLISH_NAMESPACE_OK`)

**Test Namespace**: `moq-test/interop`  
**Test Track**: `test-track`

**Success Criteria**:

- Subscriber's SUBSCRIBE eventually succeeds (once publisher announces), **OR**
- Subscriber receives REQUEST_ERROR (relay doesn't buffer pending subscriptions)

Either outcome is valid; the test checks for graceful handling.

**Timeout**: 3.5 seconds total

**Diagnostic Roles**: `publisher`, `subscriber` — report as `publisher_connection_id` and `subscriber_connection_id` in YAML diagnostics (regardless of connection order)

---

## Category: Track Publishing

These tests exercise the **PUBLISH flow**: a publisher sends a `PUBLISH` message directly naming a specific track, and the relay responds with `PUBLISH_OK`. This is distinct from the `PUBLISH_NAMESPACE` + `SUBSCRIBE` flow used in earlier tests, where a publisher announces an entire namespace and the relay routes incoming `SUBSCRIBE` requests back to that publisher. In the PUBLISH flow, the publisher establishes the track directly; the relay matches any arriving `SUBSCRIBE` for that track to the active publisher and routes data accordingly.

Each run generates a fresh 128-bit Run ID encoded as 32 lowercase hexadecimal characters. The Full Track Name is unique to the run:

- Track Namespace: `("moq-interop", <test-id>, <run-id>)`
- Track Name: `test`

Publisher and subscriber roles use the same Full Track Name and report the Run ID in diagnostics. A fixed track name must not be reused across runs because stale state or a concurrent run could satisfy the test.

The two tests below are new runner-owned semantic specifications. Their presence does not claim that any implementation currently exposes or passes them.

### `publish-without-subscriber`

**Protocol References**: MoQT-18 §5.1 (Subscriptions), §9.5 (Publisher Interactions), §10.2.12 (FORWARD), §10.5 (REQUEST_OK / `PUBLISH_OK` alias), §10.10 (PUBLISH), §10.11 (PUBLISH_DONE), §11.4 (Streams)

**Procedure**:

1. Connect to relay and complete SETUP exchange
2. Send PUBLISH naming the test track (no subscriber is present)
3. Wait for REQUEST_OK (`PUBLISH_OK`) and record its effective Forward State; an omitted FORWARD parameter means 1
4. If Forward State is 1, write Group 0, Subgroup 0, Object 0 with payload `publish-without-subscriber`, then close the subgroup stream with FIN; if it is 0, send no track data
5. Close the track with PUBLISH_DONE/TRACK_ENDED and an accurate Stream Count: 1 if a subgroup stream was opened, otherwise 0
6. Finish the request stream after PUBLISH_DONE and wait for the PUBLISH sequence to complete

**Test ID**: `publish-without-subscriber`

**Success Criteria**:

- REQUEST_OK (`PUBLISH_OK`) received within timeout
- The publisher honors the returned Forward State
- PUBLISH_DONE/TRACK_ENDED carries the exact Stream Count and is followed by request-stream FIN

> **Note**: No subscriber is present; the relay must accept the PUBLISH and the accompanying data without error. Whether the relay buffers or discards data when no subscriber exists is implementation-defined.

**Timeout**: 10 seconds

**mlog Events** (relay-side, suggested):

```json
{"name":"moqt:control_message_parsed","data":{"message_type":"publish",...}}
{"name":"moqt:control_message_created","data":{"message_type":"publish_ok",...}}
{"name":"moqt:data_stream_closed","data":{"type":"subgroup","reason":"publisher_done",...}}
```

---

### `publish-to-pending-subscription`

**Protocol References**: MoQT-18 §5.1 (Subscriptions), §9.5 (Publisher Interactions), §10.2.6 (RENDEZVOUS_TIMEOUT), §10.2.12 (FORWARD), §10.5 (REQUEST_OK / `PUBLISH_OK` alias), §10.7 (SUBSCRIBE), §10.8 (SUBSCRIBE_OK), §10.10 (PUBLISH), §10.11 (PUBLISH_DONE), §11.4 (Streams)

**Topology**: Two concurrent connections (publisher + subscriber)

**Subscriber Procedure**:

1. Connect to relay and complete SETUP exchange
2. Send SUBSCRIBE for the test namespace and track with RENDEZVOUS_TIMEOUT set to 5000 ms
3. After the SUBSCRIBE bytes have been sent, keep the request pending while the publisher connects

**Publisher Procedure**:

1. Connect to relay and complete SETUP exchange
2. Send PUBLISH naming the same test track
3. Wait for REQUEST_OK (`PUBLISH_OK`) with effective Forward State 1; an omitted FORWARD parameter means 1
4. Require the subscriber to receive SUBSCRIBE_OK
5. Write Group 0, Subgroup 0, Object 0 with payload `publish-to-pending-subscription`
6. Close the subgroup stream with FIN
7. Send PUBLISH_DONE/TRACK_ENDED with Stream Count 1, then finish the request stream

**Subscriber Completion**:

1. Receive exactly Group 0, Subgroup 0, Object 0
2. Verify the exact expected payload
3. Require PUBLISH_DONE/TRACK_ENDED with Stream Count 1; it may arrive before the subgroup stream, but retain subscription state until the one counted stream closes

**Test ID**: `publish-to-pending-subscription`

**Success Criteria**:

- Publisher receives PUBLISH_OK
- PUBLISH_OK has Forward State 1 before the publisher sends data
- Subscriber receives SUBSCRIBE_OK (relay correctly maps the SUBSCRIBE to the active PUBLISH track)
- Subscriber receives exactly one object with the expected payload
- The publisher sends PUBLISH_DONE/TRACK_ENDED with Stream Count 1 only after closing its subgroup stream, then finishes its request stream
- The subscriber processes exactly one counted subgroup stream and the exact payload even if PUBLISH_DONE arrives first

**Timeout**: 10 seconds

**Diagnostic Roles**: `publisher`, `subscriber` — report as `publisher_connection_id` and `subscriber_connection_id` in YAML diagnostics

**mlog Events** (relay-side, suggested):

```json
{"name":"moqt:control_message_parsed","data":{"message_type":"publish",...}}
{"name":"moqt:control_message_created","data":{"message_type":"publish_ok",...}}
{"name":"moqt:control_message_parsed","data":{"message_type":"subscribe",...}}
{"name":"moqt:control_message_created","data":{"message_type":"subscribe_ok",...}}
{"name":"moqt:data_stream_opened","data":{"type":"subgroup",...}}
```

---

## Future Test Cases

This section outlines potential future test cases. The actual test definitions will be added as implementations mature and working group consensus develops.

### Data Flow Tests

| Identifier | Description | Key Protocol References |
|------------|-------------|------------------------|
| `single-object` | Publisher sends 1 object via PUBLISH_NAMESPACE + SUBSCRIBE flow, subscriber receives it | §5.1 (Subscriptions), §11 (Data Streams and Datagrams) |
| `single-group` | Publisher sends group of N objects | §2.3 (Groups) |
| `multiple-groups` | Publisher sends 3 groups, subscriber receives all | §2.3 (Groups) |
| `late-subscriber` | Subscriber joins mid-stream | §5.1 (Subscriptions) |

### Message Flow Patterns

MoQT supports two primary publisher-subscriber rendezvous patterns, each exercised by separate test categories in this suite:

- **PUBLISH_NAMESPACE + SUBSCRIBE flow** (Category: Subscriptions): Publisher announces namespace availability via `PUBLISH_NAMESPACE`; relay routes incoming `SUBSCRIBE` requests to the publisher. Tests: `announce-only`, `publish-namespace-done`, `announce-subscribe`, `subscribe-before-announce`.
- **PUBLISH + SUBSCRIBE flow** (Category: Track Publishing): Publisher directly publishes a specific track via `PUBLISH`; the relay matches any incoming `SUBSCRIBE` for that track to the active publisher. Tests: `publish-without-subscriber`, `publish-to-pending-subscription`.

### Test Client Support

This specification does not maintain a prose capability matrix. Evolving support claims belong in machine-readable conformance profiles with pinned implementation provenance and evidence. Run-specific observations belong in result artifacts. Test clients still declare available tests through `--list`; `TESTCASE` selects one test and exit code `127` signals an unsupported test.

---

## Validation Approaches

### Current: Test Client Self-Validation

Test clients currently implement both test execution and result validation. The test client:
1. Performs the protocol operations
2. Checks responses against expected values
3. Reports PASS/FAIL

### Future: mlog-Based Validation

An alternative approach uses standardized mlog (qlog for MoQT) output:
1. Test client performs protocol operations and logs mlog events
2. Relay logs mlog events  
3. Separate validator component analyzes combined mlog output
4. Validator determines PASS/FAIL based on expected event sequences

This approach could enable more sophisticated validation (e.g., verifying relay internal behavior) and reduce test client complexity. See the mlog event suggestions in each test case for the types of events that would be useful.

---

## References

- [draft-ietf-moq-transport-18](https://www.ietf.org/archive/id/draft-ietf-moq-transport-18.html) - MoQT Protocol Specification
- [RFC 2026 §4](https://www.rfc-editor.org/rfc/rfc2026#section-4) - IETF interoperability testing requirements
- [QUIC Interop Runner](https://github.com/quic-interop/quic-interop-runner) - Inspiration for this framework

# MoQT Interoperability Test Cases

> **This is the reference specification for test cases.** To propose new test cases, open a PR against this file. To implement these tests in your MoQT stack, see [IMPLEMENTING-A-TEST-CLIENT.md](../IMPLEMENTING-A-TEST-CLIENT.md).

This document defines interoperability test cases for Media over QUIC Transport (MoQT). These specifications are designed to be implementation-neutral and precise enough that any MoQT implementation can build a compatible test client.

**Protocol Reference**: [draft-ietf-moq-transport-14](https://www.ietf.org/archive/id/draft-ietf-moq-transport-14.html)

> **Note**: Section references (e.g., "MoQT-14 §9.3") refer to the draft version above. These will be updated as the protocol evolves.

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

**Protocol References**: MoQT-14 §3.3 (Session initialization), §9.3 (CLIENT_SETUP and SERVER_SETUP)

**Procedure**:

1. Connect to relay via WebTransport (or raw QUIC)
2. Send CLIENT_SETUP with supported versions
3. Receive SERVER_SETUP with selected version
4. Close connection gracefully

**Success Criteria**:

- SERVER_SETUP received with compatible version
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

**Protocol References**: MoQT-14 §6.2 (Publishing Namespaces), §9.23 (PUBLISH_NAMESPACE), §9.24 (PUBLISH_NAMESPACE_OK)

**Procedure**:

1. Connect and complete SETUP exchange
2. Send PUBLISH_NAMESPACE for test namespace
3. Wait for PUBLISH_NAMESPACE_OK
4. Close connection gracefully

**Test Namespace**: `moq-test/interop`

**Success Criteria**:

- PUBLISH_NAMESPACE_OK received
- No error response

**Timeout**: 2 seconds after sending PUBLISH_NAMESPACE

**mlog Events** (relay-side, suggested):

```json
{"name":"moqt:control_message_parsed","data":{"message_type":"publish_namespace",...}}
{"name":"moqt:control_message_created","data":{"message_type":"publish_namespace_ok",...}}
```

---

### `publish-namespace-done`

**Protocol References**: MoQT-14 §6.2 (Publishing Namespaces), §9.26 (PUBLISH_NAMESPACE_DONE)

**Procedure**:

1. Connect and complete SETUP exchange
2. Send PUBLISH_NAMESPACE for test namespace
3. Wait for PUBLISH_NAMESPACE_OK
4. Send PUBLISH_NAMESPACE_DONE (unpublish)
5. Close connection gracefully

**Test Namespace**: `moq-test/interop`

**Success Criteria**:

- PUBLISH_NAMESPACE_OK received
- PUBLISH_NAMESPACE_DONE sent without error
- Clean disconnection

**Timeout**: 2 seconds after sending PUBLISH_NAMESPACE

---

## Category: Subscriptions

### `subscribe-error`

**Protocol References**: MoQT-14 §5.1 (Subscriptions), §9.7 (SUBSCRIBE), §9.9 (SUBSCRIBE_ERROR)

**Procedure**:

1. Connect and complete SETUP exchange
2. Send SUBSCRIBE for non-existent namespace/track
3. Expect SUBSCRIBE_ERROR response
4. Close connection gracefully

**Test Namespace**: `nonexistent/namespace`  
**Test Track**: `test-track`

**Success Criteria**:

- SUBSCRIBE_ERROR received (this is the expected behavior)
- Exit code 0 (the error was expected and correctly handled)

**Timeout**: 2 seconds

**mlog Events** (relay-side, suggested):

```json
{"name":"moqt:control_message_parsed","data":{"message_type":"subscribe",...}}
{"name":"moqt:control_message_created","data":{"message_type":"subscribe_error",...}}
```

---

### `announce-subscribe`

**Protocol References**: MoQT-14 §5.1 (Subscriptions), §6.2 (Publishing Namespaces), §9.7-9.8 (SUBSCRIBE/SUBSCRIBE_OK), §9.23-9.24 (PUBLISH_NAMESPACE/PUBLISH_NAMESPACE_OK)

**Topology**: Two concurrent connections (publisher + subscriber)

**Publisher Procedure**:

1. Connect and complete SETUP exchange
2. Send PUBLISH_NAMESPACE for test namespace
3. Wait for PUBLISH_NAMESPACE_OK
4. Wait for subscription or timeout

**Subscriber Procedure**:

1. Connect and complete SETUP exchange
2. Send SUBSCRIBE for test namespace/track
3. Wait for SUBSCRIBE_OK or SUBSCRIBE_ERROR

**Test Namespace**: `moq-test/interop`  
**Test Track**: `test-track`

**Success Criteria**:

- Both connections complete SETUP
- Publisher receives PUBLISH_NAMESPACE_OK
- Subscriber receives SUBSCRIBE_OK (relay routes subscription to publisher)

**Timeout**: 3 seconds total

**Diagnostic Roles**: `publisher`, `subscriber` — report as `publisher_connection_id` and `subscriber_connection_id` in YAML diagnostics

---

### `subscribe-before-announce`

**Protocol References**: MoQT-14 §5.1 (Subscriptions), §6.2 (Publishing Namespaces)

**Topology**: Two connections, subscriber connects first

**Subscriber Procedure**:

1. Connect and complete SETUP exchange
2. Send SUBSCRIBE for test namespace/track (publisher hasn't announced yet)
3. Wait for response

**Publisher Procedure** (starts 500ms after subscriber):

1. Connect and complete SETUP exchange
2. Send PUBLISH_NAMESPACE for test namespace
3. Wait for PUBLISH_NAMESPACE_OK

**Test Namespace**: `moq-test/interop`  
**Test Track**: `test-track`

**Success Criteria**:

- Subscriber's SUBSCRIBE eventually succeeds (once publisher announces), **OR**
- Subscriber receives SUBSCRIBE_ERROR (relay doesn't buffer pending subscriptions)

Either outcome is valid; the test checks for graceful handling.

**Timeout**: 3.5 seconds total

**Diagnostic Roles**: `publisher`, `subscriber` — report as `publisher_connection_id` and `subscriber_connection_id` in YAML diagnostics (regardless of connection order)

---

## Future Test Cases

This section outlines potential future test cases. The actual test definitions will be added as implementations mature and working group consensus develops.

### Data Flow Tests

| Identifier | Description | Key Protocol References |
|------------|-------------|------------------------|
| `single-object` | Publisher sends 1 object, subscriber receives it | §10 (Data Streams) |
| `single-group` | Publisher sends group of N objects | §2.3 (Groups) |
| `multiple-groups` | Publisher sends 3 groups, subscriber receives all | §2.3 (Groups) |
| `late-subscriber` | Subscriber joins mid-stream | §5.1 (Subscriptions) |

### Alternative Flow Patterns

Different use cases may require different message flow patterns:

- **PUBLISH_NAMESPACE + SUBSCRIBE flow**: Publisher announces availability, subscriber requests specific track
- **SUBSCRIBE_NAMESPACE + PUBLISH flow**: Subscriber expresses interest in namespace prefix, publisher sends tracks

As moq-rs and other implementations add support for both patterns, we should develop test cases that exercise each.

### Test Client Capability Matrix

As the test suite grows, different test clients may support different subsets of tests. A capability matrix could help:

| Test Client | `setup-only` | `announce-only` | `publish-namespace-done` | `subscribe-error` | `announce-subscribe` | `subscribe-before-announce` |
|-------------|--------------|-----------------|--------------------------|-------------------|----------------------|-----------------------------|
| moq-test-client (moq-rs) | Yes | Yes | Yes | Yes | Yes | Yes |
| implementation-b | Yes | Yes | No | Yes | No | No |

The mechanism for declaring and discovering these capabilities is TBD - potentially via a `--list` command that outputs supported test identifiers.

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

- [draft-ietf-moq-transport-14](https://www.ietf.org/archive/id/draft-ietf-moq-transport-14.html) - MoQT Protocol Specification
- [RFC 2026 §4](https://www.rfc-editor.org/rfc/rfc2026#section-4) - IETF interoperability testing requirements
- [QUIC Interop Runner](https://github.com/quic-interop/quic-interop-runner) - Inspiration for this framework

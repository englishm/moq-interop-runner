# MoQT Data-Plane Interoperability Tests

**Target Draft**: `draft-18`

**Identifier Semantics Reviewed For**: `draft-18`

**Protocol Reference**: [draft-ietf-moq-transport-18](https://www.ietf.org/archive/id/draft-ietf-moq-transport-18.html)

**Normative Source Revision**: [`cb2e772fd8ca8cbe7550b1765c269be89fb1c886`](https://github.com/moq-wg/moq-transport/tree/cb2e772fd8ca8cbe7550b1765c269be89fb1c886)

This document defines seven tests for subscribed Object delivery through a relay. The machine-readable fixtures in [`vectors/data-plane.json`](vectors/data-plane.json) provide the exact Object and stream data for each test.

Each test entry carries its own revision and `sha256:` digest, and the vector file records the SHA-256 digest of its schema. A test digest is computed over an object containing `target_draft`, `normative_source`, `schema_digest`, `common`, and the selected `test`, with `vector_digest` omitted from the selected test. Serialize compact UTF-8 JSON with object keys recursively sorted in lexical order and no trailing line terminator before hashing. The publisher and verifier use the same identified vector through independent consumption paths.

Changing a test or any common rule covered by its digest requires increasing that test's revision and the suite revision.

## Common Protocol References

All seven tests exercise MoQT-18 §2.1 (Objects), §2.2 (Subgroups), §2.4.2 (Malformed Tracks), §3.3 (Session initialization), §5.1 (Subscriptions), §5.1.1 (Subscription State Management), §7 (Priorities), §9.4 (Subscriber Interactions), §9.5 (Publisher Interactions), §9.7 (Relay Object Handling), §10.2.6 (RENDEZVOUS_TIMEOUT), §10.2.12 (FORWARD), §10.5 (REQUEST_OK / `PUBLISH_OK`), §10.6 (REQUEST_ERROR), §10.7 (SUBSCRIBE), §10.8 (SUBSCRIBE_OK), §10.10 (PUBLISH), §10.11 (PUBLISH_DONE), §11.1 (Track Alias), §11.2 and §11.2.1 (Objects and Object Header), §11.4.2 (Subgroup Header), and §11.4.3 (Closing Subgroup Streams).

Tests concerned with Group layout additionally exercise §2.3 (Groups) and §2.3.1 (Group IDs). The sparse-ID test additionally exercises §12.8 (Prior Group ID Gap) and §12.9 (Prior Object ID Gap). The Object Properties test additionally exercises §1.4.3 (Key-Value-Pair Structure), §2.5 (Properties), §11.2.1.2 (Object Properties), and §15.8 (Properties).

## Run-Scoped Track Identity

Before opening either role's session, the test coordinator uses a cryptographically secure random generator to produce a fresh 128-bit Run ID encoded as exactly 32 lowercase hexadecimal characters. Generation failure fails the test; a timestamp, counter, process ID, or fixed fallback is not allowed.

- Track Namespace fields: `("moq-interop", "<test-id>")`
- Track Name: `<run-id>`

Namespace fields and the Track Name are the indicated ASCII byte strings. Publisher and subscriber use the same Full Track Name. The random Track Name isolates concurrent runs and stale relay state within the test's namespace. Track aliases are scoped to their respective sessions and are not compared across the two sessions.

## Common Dual-Role Direct-PUBLISH Procedure

Each test uses two independent sessions to the same relay: one subscriber and one publisher.

#### Subscriber

1. Connect, complete SETUP, and require the negotiated draft to equal the vector's `target_draft`.
2. Send SUBSCRIBE for the run-scoped Full Track Name with `RENDEZVOUS_TIMEOUT=5000` milliseconds and `FORWARD=1`. Send no subscription filter and no other parameters.
3. Keep the request pending while the publisher connects.
4. Require exactly one SUBSCRIBE_OK. Record its Track Alias for matching incoming subgroup streams. Validate any Track Properties according to the target draft, but do not require them to be empty or compare them with the Object vector.
5. Do not initiate FETCH and do not cancel the subscription.
6. Receive and validate the Objects and subgroup streams against the selected vector. Retain subscription state after PUBLISH_DONE until the declared number of streams have been processed.
7. Require PUBLISH_DONE with status `TRACK_ENDED` and the vector's exact Stream Count, validate its reason phrase, and then require FIN on the SUBSCRIBE request stream's response direction. The relay's diagnostic reason phrase is not compared with the publisher fixture's reason.

#### Publisher

1. Begin connecting no later than 250 milliseconds after the subscriber finishes flushing the complete SUBSCRIBE request, then complete SETUP and require the negotiated draft to equal the vector's `target_draft`.
2. Send PUBLISH for the same Full Track Name with a Track Alias not already in use in that session, `FORWARD=1`, no other parameters, and empty Track Properties. No Object has yet been published, so do not include LARGEST_OBJECT.
3. Require exactly one REQUEST_OK (`PUBLISH_OK`) and record its effective Forward State. An omitted FORWARD parameter has value 1. Require empty Track Properties.
4. If the PUBLISH response had Forward State 0, continue processing that request stream concurrently with the subscriber wait, require a REQUEST_UPDATE that sets Forward State 1, and send REQUEST_UPDATE_OK without waiting for SUBSCRIBE_OK.
5. Independently wait until the subscriber role has received SUBSCRIBE_OK. Emit no Object until SUBSCRIBE_OK has arrived and the publisher's effective Forward State is 1.
6. Emit every Object row in the selected vector. Use the stated Group ID, Subgroup ID, Object ID, Publisher Priority, status, forwarding preference, payload, and Object Properties. Every subgroup starts on its own unidirectional stream with the vector's FIRST_OBJECT value. Publisher Priority is carried explicitly in each subgroup header.
7. Close each subgroup stream with its vector-declared terminal after its vector-declared final Object.
8. After every subgroup stream has been closed, send the vector-declared PUBLISH_DONE, including its publisher reason, and the PUBLISH request-stream terminal.

#### Relay-Visible Result

The subscriber must receive exactly the vector-declared Objects. Group ID, Subgroup ID, Object ID, Publisher Priority, status, forwarding preference, payload bytes, and Object Properties must match. The subscriber must process exactly the vector-declared subgroup streams and terminal conditions.

Each Object row's `fixture_emit_at_ms` is the publisher fixture's emission schedule relative to its first Object. This schedule is not an assertion about arrival time, latency, or arrival order.

## Allowed Ordering

- PUBLISH_OK and SUBSCRIBE_OK may be received in either order across the two sessions.
- When PUBLISH_OK has Forward State 0, REQUEST_UPDATE to Forward State 1 may arrive before or after SUBSCRIBE_OK.
- No publisher Object is emitted until SUBSCRIBE_OK has arrived and effective Forward State is 1.
- Objects on one subgroup stream are observed in stream order. Objects on different subgroup streams or in different Groups may arrive in any order.
- PUBLISH_DONE may arrive at the subscriber before some or all subgroup streams or their FINs. The subscriber waits for the exact Stream Count.
- On each request stream, PUBLISH_DONE precedes that stream's FIN.
- A subgroup FIN follows that subgroup's declared final Object and no later Object appears on that stream.

No test asserts packet order, cross-stream arrival order, or the relative arrival time of data and PUBLISH_DONE.

## Fail-Closed Outcomes

A test fails on any of the following:

- SETUP failure, negotiation of a draft other than the vector target, session closure, request-stream reset, subgroup-stream reset, or timeout before successful completion
- REQUEST_ERROR, more than one response to a request, or a response for the wrong Full Track Name
- failure to reach effective Forward State 1, an unsuccessful REQUEST_UPDATE, or any Object sent while Forward State is 0
- any unexpected, duplicate, missing, or malformed Object
- any mismatch in Group ID, Subgroup ID, Object ID, Publisher Priority, status, forwarding preference, payload, or Object Properties
- a Datagram, FETCH response, End of Group Object, or End of Track Object
- a subgroup stream ending before or after its declared final Object, or ending without FIN
- PUBLISH_DONE before the publisher has closed every subgroup stream it will open
- missing PUBLISH_DONE, a status other than `TRACK_ENDED`, an invalid reason phrase, an incorrect Stream Count, or a missing request-stream FIN
- fewer or more processed subgroup streams than PUBLISH_DONE declares

The subscriber does not pass early after receiving the expected Object rows; it passes only after all terminal conditions are satisfied and no extra data has appeared.

## Timing

- Each SETUP exchange must complete within 2 seconds of opening its session.
- Let `T0` be the time at which the subscriber finishes flushing the complete SUBSCRIBE request to the transport. The publisher starts connecting by `T0 + 250 ms`.
- PUBLISH_OK, SUBSCRIBE_OK, and any required transition to Forward State 1 must complete by `T0 + 5 s`.
- The fixture schedules the first Object only after SUBSCRIBE_OK has arrived and effective Forward State is 1, then schedules later rows at their vector-declared offsets.
- The complete test, including all stream FINs, PUBLISH_DONE, and request-stream FIN, must finish by `T0 + 10 s`.
- Vector cadence is fixture scheduling only. Subscriber arrival timestamps are not checked.

## Test Cases

### `subscribe-one-subgroup-per-group`

**Additional Protocol References**: MoQT-18 §2.3, §2.3.1

Publish one subgroup in each of two Groups.
Exact Object rows and terminal conditions are defined by the selected vector.

### `subscribe-one-subgroup-per-object`

Publish three Objects in Group 0, assigning each Object to a distinct Subgroup whose ID equals the Object ID.
Exact Object rows and terminal conditions are defined by the selected vector.

### `subscribe-two-subgroups-per-group`

Publish two interleaved Subgroups in Group 0. Each subgroup is internally ascending even though its Object IDs are not contiguous.
Exact Object rows and terminal conditions are defined by the selected vector.

### `subscribe-nonzero-start-group`

**Additional Protocol References**: MoQT-18 §2.3, §2.3.1

Begin the Track at a nonzero Group ID. No earlier Group is published in this run. Exact Object rows and terminal conditions are defined by the selected vector.

### `subscribe-nonzero-start-object`

Begin a Group at a nonzero Object ID without publishing earlier Objects in that Group. Exact Object rows and terminal conditions are defined by the selected vector.

### `subscribe-sparse-group-object-ids`

**Additional Protocol References**: MoQT-18 §2.3, §2.3.1, §12.8, §12.9

Publish noncontiguous Group IDs and noncontiguous Object IDs in each Group. Exact Object rows and terminal conditions are defined by the selected vector.

No Object carries Prior Group ID Gap or Prior Object ID Gap. Missing identifiers are not asserted to be nonexistent, and neither the subscriber nor the test result infers their existence or nonexistence.

### `subscribe-object-properties`

**Additional Protocol References**: MoQT-18 §1.4.3, §2.5, §11.2.1.2, §15.8

Publish normal Objects with application-specific Properties. Property types are in ascending order and use the value form selected by type parity: even types carry integers and odd types carry byte strings. The selected vector defines the exact types, values, Object rows, and terminal conditions.

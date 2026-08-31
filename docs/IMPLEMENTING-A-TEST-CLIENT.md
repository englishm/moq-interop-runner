# Implementing a MoQT Test Client

> **This is an implementation guide.** The client interface is [TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md), and test procedures are defined in [tests/TEST-CASES.md](./tests/TEST-CASES.md).

Build one client image whose invocation executes tests and validates their results. The runner does not require or register a separate publisher role.

## Invocation Model

Treat one invocation as the test coordinator. It owns every logical MoQT session needed by the selected test and emits one TAP stream for the invocation.

For data-plane tests, create logical publisher and subscriber sessions against the same `RELAY_URL`. They can share a process or run as subprocesses inside the image. Keep coordination and result aggregation in the invoking client so only one image lifecycle and one TAP producer are visible to the runner.

The current runner invokes that image once per client/relay endpoint without first using `--list` to schedule individual cases. With no `TESTCASE`, run all supported tests. Still implement exact-ID `--list` and `TESTCASE` behavior so direct and future per-case invocations have the same semantics.

## Identifier Handling

Use the semantic IDs from the test specifications unchanged:

- Print the same ID from `--list` that `TESTCASE` accepts.
- Use that exact ID as the TAP test-point name.
- Use the specified ID directly without translating it.
- Exit `127` for an unknown selected ID.
- Emit `ok ... # SKIP` for a known test the client does not support.

## Data-Plane Run State

Create isolated state for each data-plane test:

- Generate a fresh 128-bit Run ID with a cryptographically secure random generator and encode it as exactly 32 lowercase hexadecimal characters. Fail rather than substituting a predictable value if secure generation is unavailable.
- Construct Track Namespace `("moq-interop", <semantic-test-id>)` as a tuple of namespace fields.
- Use the 32-character lowercase hexadecimal Run ID as the ASCII Track Name.
- Load the selected fixture vector, including its revision and digest.
- Record publisher and subscriber connection IDs, target draft, and each role's negotiated draft.

Do not flatten the namespace tuple into a path unless the selected protocol encoding requires that representation. Publish the Objects described by the selected vector.

## Subscriber-First Coordination

Use an explicit synchronization point between the logical roles:

1. Complete the subscriber SETUP exchange.
2. Send exact-track `SUBSCRIBE` with a bounded rendezvous timeout.
3. Flush the complete request to the transport.
4. Signal the publisher role only after that flush completes.
5. Complete the publisher SETUP exchange and direct `PUBLISH` the identical Full Track Name.
6. Require a successful PUBLISH response and record its effective Forward State; omitted `FORWARD` means `1`.
7. Start or continue the bounded wait for subscriber `SUBSCRIBE_OK`.
8. If the effective Forward State is `0`, process the relay's `REQUEST_UPDATE` concurrently with the subscriber wait, require it to set Forward State `1`, and send the successful update response without waiting for `SUBSCRIBE_OK`.
9. Only after Forward State is `1` and `SUBSCRIBE_OK` has arrived, drive the publication from the selected vector.

Bound every step. A local queue insertion is not proof that `SUBSCRIBE` was flushed, and an arbitrary sleep is not a synchronization mechanism.

## Publishing the Vector

The publisher fixture reads each subgroup and Object from the selected vector.

For each vector subgroup:

- Write each object exactly as specified and in that subgroup's vector order.
- Permit subgroup streams to progress independently; no global order exists across streams.
- Close the subgroup stream with FIN after its final object.

After every opened subgroup stream is finished, send `PUBLISH_DONE`/`TRACK_ENDED` with Stream Count equal to the number of opened subgroup streams, then finish the PUBLISH request stream.

## Independent Verification

Build expected state directly from the selected vector before processing subscriber observations. Decode subscriber-side protocol and data-stream observations into actual state, then compare:

- Full Track Name
- subgroup and object coordinates and order within each subgroup
- Publisher Priority, status, forwarding preference, FIRST_OBJECT, and END_OF_GROUP
- payload bytes
- Object Properties
- subgroup FIN
- PUBLISH_DONE status and valid reason phrase
- exact Stream Count
- SUBSCRIBE request-stream response FIN

Keep expected-state construction separate from publisher output and generation. Shared decoding and byte-comparison utilities are acceptable.

Compare each subgroup independently. Cross-stream arrival order is irrelevant. If `PUBLISH_DONE`/`TRACK_ENDED` arrives before data streams, retain the subscription and terminal metadata until every counted stream closes, then perform the final comparison. Separately, the publisher role verifies that its PUBLISH request stream sent FIN after PUBLISH_DONE.

## TAP and Diagnostics

Emit one TAP point per executed test. Successful executed data-plane points include YAML diagnostics for:

- `publisher_connection_id`
- `subscriber_connection_id`
- `run_id`
- `target_draft`
- `publisher_negotiated_draft`
- `subscriber_negotiated_draft`
- `vector_revision`
- `vector_digest`

Failed data-plane points include all values captured before failure. Skipped points do not require diagnostics. Add concise expected/received details for response, timeout, stream-count, FIN, ordering, coordinate, or payload mismatches.

## Implementation Checklist

Before packaging the image, verify:

- One invocation coordinates both roles against the same `RELAY_URL`.
- Subscriber request flush gates direct PUBLISH.
- PUBLISH succeeds, any Forward State `0` transition is handled through `REQUEST_UPDATE`, effective Forward State reaches `1`, and subscriber receives `SUBSCRIBE_OK` before Objects are sent.
- Publisher and verifier read the same vector separately.
- Verification imposes order only within each subgroup.
- Every subgroup stream ends at its vector-declared Object, the publisher sends PUBLISH_DONE and FIN on its PUBLISH request direction, and the subscriber observes the exact Stream Count plus FIN on the SUBSCRIBE response direction.
- Semantic IDs are identical in `--list`, `TESTCASE`, and TAP.
- Unknown IDs exit `127`; known unsupported cases use TAP `SKIP`.
- Role connection IDs, Run ID, draft values, and vector identity appear in diagnostics.
- Every wait is bounded and every failure produces one unambiguous result.

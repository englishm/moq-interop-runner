# Basic Subgroup Delivery

| Attribute | Value |
|-----------|-------|
| Identifier | `data-subgroup-basic` |
| Status | Proposal |
| Proposed placement | First data-plane core level |
| Specification revision | 1 |

## Purpose

This test verifies that a relay routes a namespace-based subscription and
delivers a finite track containing multiple groups and objects without loss,
duplication, or corruption. It is the baseline for later tests that vary stream
mapping or object numbering.

## Protocol References

- [MoQT draft 18](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-18): subscriptions, publishing namespaces, subgroup streams, and PUBLISH_DONE
- [MoQT Test](https://datatracker.ietf.org/doc/html/draft-afrind-moq-test): deterministic publisher behavior that informed the canonical case

## Roles And Preconditions

The test client operates one publisher session and one subscriber session
through the relay under test. Both sessions negotiate the current MoQT interop
target draft and support subgroup stream delivery.

The roles follow the [normal publisher-first publication
flow](./README.md#normal-publication-flow). They use a run-unique Full Track
Name with these components:

- Track Namespace: `("moq-interop", "data-subgroup-basic", "<run-id>")`
- Track Name: `track`

Each quoted component is a non-empty UTF-8 byte string. `<run-id>` follows the
collision-resistance requirement in the shared conventions.

## Canonical Case

The publisher generates this deterministic case:

| Parameter | Value |
|-----------|-------|
| Forwarding mode | One subgroup per group |
| Start group | `0` |
| Start object | `0` |
| Last group | `2` |
| Last object | `4` |
| Objects per group | `5` |
| Size of object 0 | `64` bytes |
| Size of objects greater than 0 | `32` bytes |
| Group increment | `1` |
| Object increment | `1` |

The case is specified directly rather than encoded as a MoQT Test Track
Namespace, avoiding a dependency on how a particular MoQT Test revision encodes
default tuple fields. Payload, priority, pacing, and optional parameters use the
shared defaults.

## Procedure

1. Complete publisher SETUP and publish the canonical Track Namespace with
   PUBLISH_NAMESPACE.
2. Wait for REQUEST_OK before starting the subscriber role.
3. Complete subscriber SETUP and send SUBSCRIBE for the run-unique Full Track
   Name without RENDEZVOUS_TIMEOUT.
4. Accept the matching upstream SUBSCRIBE at the publisher and confirm that both
   upstream and downstream subscriptions become established.
5. Generate all objects in the canonical case, using subgroup ID 0 in each
   group and effective Publisher Priority 128, and close each subgroup stream
   cleanly.
6. Send upstream PUBLISH_DONE with status TRACK_ENDED and Stream Count 3.
7. Drain downstream streams using the shared Stream Count rule and verify the
   complete expected object set.

## Success Criteria

The test passes when:

- PUBLISH_NAMESPACE receives REQUEST_OK;
- the relay receives SUBSCRIBE_OK from the upstream publisher, and the
  downstream subscriber receives SUBSCRIBE_OK from the relay;
- the subscriber receives exactly 15 data objects at groups 0 through 2 and
  object IDs 0 through 4;
- each group uses subgroup ID 0 with effective Publisher Priority 128;
- every object has the expected payload length and bytes;
- no data object is missing, additional, duplicated, or corrupt;
- upstream PUBLISH_DONE reports TRACK_ENDED and Stream Count 3;
- downstream PUBLISH_DONE reports TRACK_ENDED; and
- downstream draining completes according to the shared Stream Count rule,
  including streams or objects that arrive after downstream PUBLISH_DONE.

## Failure And Timeout Behavior

A request error, session failure, malformed object, incomplete stream set, or
expired shared deadline fails the test.

## Diagnostics

The client should report `publisher` and `subscriber` session metadata when
available. Optional TAP YAML may also identify the implementation version,
specification revision, total test duration, and the first missing or unexpected
object.

# Basic Subgroup Delivery

| Attribute | Value |
|-----------|-------|
| Identifier | `data-subgroup-basic` |
| Status | Proposal |
| Proposed placement | First data-plane core level |
| Specification revision | 2 |

## Purpose

This test verifies that a relay routes a subscription to the publisher of a
matching namespace prefix and delivers a finite track containing multiple
groups and objects without loss, duplication, or corruption. It is the baseline
for later tests that vary stream mapping or object numbering.

## Protocol References

- [MoQT draft 18](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-18): subscriptions, publishing namespaces, Namespace Prefix Matching, subgroup streams, and PUBLISH_DONE
- [MoQT Test](https://datatracker.ietf.org/doc/html/draft-afrind-moq-test): Track Namespace encoding of the canonical case and the publisher behavior it selects

## Roles And Preconditions

The test client operates one publisher session and one subscriber session
through the relay under test. Both sessions negotiate the current MoQT interop
target draft and support subgroup stream delivery.

The roles follow the [normal publisher-first publication
flow](./README.md#normal-publication-flow) and the shared [MoQT Test
namespace](./README.md#moqt-test-namespace) layout:

- Published namespace (routing prefix):
  `("moq-test", "data-subgroup-basic", "<run-id>")`
- Subscribed Track Namespace: the routing prefix followed by the canonical
  tuple below (19 fields)
- Track Name: `track`

Each quoted component is a non-empty UTF-8 byte string. `<run-id>` follows the
collision-resistance requirement in the shared conventions.

## Canonical Case

The canonical MoQT Test tuple is:

```text
moq-test-00/0/0/0/2/4/5/64/32/2/1/1/0/-1/-1/0
```

Field by field:

| Field | Parameter | Value |
|-------|-----------|-------|
| 0 | Protocol | `moq-test-00` |
| 1 | Forwarding preference | `0` (one subgroup per group) |
| 2 | Start group | `0` |
| 3 | Start object | `0` |
| 4 | Last group in track | `2` |
| 5 | Last object in track | `4` |
| 6 | Objects per group | `5` |
| 7 | Size of object 0 | `64` bytes |
| 8 | Size of objects greater than 0 | `32` bytes |
| 9 | Object frequency | `2` ms |
| 10 | Group increment | `1` |
| 11 | Object increment | `1` |
| 12 | End of Group markers | `0` (none) |
| 13 | Test integer extension | `-1` (none) |
| 14 | Test variable extension | `-1` (none) |
| 15 | Publisher delivery timeout | `0` (none) |

This yields groups 0 through 2, each carrying object IDs 0 through 4 on subgroup
0. Object 0 of each group is 64 bytes and objects 1 through 4 are 32 bytes.
Payload and priority use the shared defaults.

## Procedure

1. Complete publisher SETUP and send PUBLISH_NAMESPACE for the routing prefix.
2. Wait for REQUEST_OK before starting the subscriber role.
3. Complete subscriber SETUP and send SUBSCRIBE for the 19-field Track Namespace
   and Track Name `track`, without RENDEZVOUS_TIMEOUT.
4. Accept the matching upstream SUBSCRIBE at the publisher, derive the object
   set from the tuple that follows the routing prefix, and confirm that both
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
- the upstream SUBSCRIBE arrives at the publisher that sent the run's routing
  prefix, carrying the full 19-field Track Namespace;
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

## Revision History

- Revision 2: Encode the canonical case as a MoQT Test tuple below a
  `("moq-test", "data-subgroup-basic", "<run-id>")` routing prefix. The publisher
  publishes only the prefix and derives objects from the subscribed tuple.
  Revision 1 used the three-field namespace
  `("moq-interop", "data-subgroup-basic", "<run-id>")` and listed the case only
  in prose. The object set is unchanged.
- Revision 1: Initial proposal.

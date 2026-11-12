# MPEG-TS Carriage Integrity

| Attribute | Value |
|-----------|-------|
| Identifier | `ts-carriage-integrity` |
| Status | Proposal |
| Proposed placement | Media profile, MPEG-TS |
| Specification revision | 1 |

## Purpose

This test verifies that a relay delivers a published MPEG-2 transport stream
to a subscriber unaltered: every non-null packet, in order, with nothing
lost, duplicated, reordered or corrupted, and a stream a decoder accepts. A
packaging may drop null packets, which are stuffing. It is the
baseline the other MPEG-TS scenarios vary.

## Protocol References

- [MoQT draft 18](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-18)
  and later: publishing namespaces, subscriptions, objects and groups
- [ISO/IEC 13818-1](https://www.iso.org/standard/91403.html) and the
  packaging, as fixed in the [format notes](./mpeg-ts.md)

## Roles And Preconditions

The test client operates one `publisher` session and one `subscriber`
session through the relay under test, using the shared [fixture, packaging and
oracle](./mpeg-ts.md). The published namespace is
`("moq-test", "ts-carriage-integrity", "<run-id>")`, with `<run-id>` as in
the data-plane [test identity](../data-plane/README.md#test-identity). Track
Names are the packaging's.

## Procedure

1. Complete publisher SETUP, send PUBLISH_NAMESPACE for the namespace and
   wait for REQUEST_OK. Publish the packaging's description track, if it has
   one.
2. Complete subscriber SETUP. Subscribe to the description track, if there is
   one, then to the TS track, with the [common subscription
   stimulus](../data-plane/README.md#common-subscription-stimulus), and wait
   until the subscription is established.
3. Begin publishing the fixture at time T0, as the
   [packaging](./mpeg-ts.md#packaging) requires; it ends at T0 + 20 s, and
   the publisher then ends the track.
4. Record every object received on the TS track until the track has ended
   and its data streams have drained (the end of the track may arrive
   before the last of them), or until T0 + 30 s, whichever comes first, and
   [reassemble](./mpeg-ts.md#reassembly) them. Then close the subscriber,
   then the publisher: a publisher that closes as soon as it has ended the
   track can cut off the tail itself.
5. Verify with `check-ts.py --fixture fixture.ts --received received.ts
   --objects objects.txt`, adding `--catalog-expected` and
   `--catalog-received` where the packaging has a description track.

## Success Criteria

The test passes when:

- `catalog`: the description track, where the packaging has one, arrives as
  published;
- `byte-identical`: the non-null packets received are the fixture's, byte for
  byte, from its first random access point or earlier to its end;
- `ordering`: groups and objects arrive in order, with no gap or duplicate;
- `decode`: the stream decodes from its first random access point with the
  frame counts the fixture predicts;
- `packet-alignment`, `transport-errors`, `continuity`, `psi-unchanged` and
  `group-starts` pass.

Permitted variation: dropped null packets; packets before the fixture's first
random access point; object sizes and group boundaries within the
[packaging rules](./mpeg-ts.md#packaging); objects of adjacent groups
interleaving in time; and timing within the deadlines.

## Failure And Timeout Behavior

A request error or session failure before delivery is complete, or delivery
not complete by T0 + 30 s (fixture end plus 10 s), fails the test. Delivery
is complete when `received.ts` runs to the fixture's end, as
`byte-identical` requires. How the track ended (an end of track, an error,
or nothing by T0 + 30 s) is reported as `track_end` and not graded: relays
pass on the end of a track differently by implementation and draft. A
stream that loses,
duplicates, reorders or corrupts packets fails on the corresponding check.
The test takes about 30 s.

## Diagnostics

The client reports one test point, `ts-carriage-integrity`, preceded by a
subtest block with the checks in the order the [format
notes](./mpeg-ts.md#oracle) list them, in the area's [TAP
output](./README.md#tap-output) shape. The TAP YAML should carry
`media_format`, `ts_packaging`, `join_offset_ms`, `track_end`, the shared
counts, `first_group` and `last_group`, `publisher` and `subscriber` session
metadata, the fields `check-ts.py` prints, and `first_mismatch` when a check
fails.

## Revision History

- Revision 1: Initial proposal.

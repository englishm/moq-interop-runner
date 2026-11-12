# MPEG-TS Late Subscriber

| Attribute | Value |
|-----------|-------|
| Identifier | `ts-late-subscriber` |
| Status | Proposal |
| Proposed placement | Media profile, MPEG-TS |
| Specification revision | 1 |

## Purpose

This test verifies that a subscriber joining a live transport stream part-way
through receives a stream a decoder can start on: from the group in progress
at the join or the next one, an unbroken tail of what was published, in
order, decodable from its first random access point. It is the join a viewer
or a downstream distribution hop makes, and one a relay serves from its
cache.

## Protocol References

- [MoQT draft 18](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-18)
  and later: subscriptions and groups as join points
- [ISO/IEC 13818-1](https://www.iso.org/standard/91403.html) and the
  packaging, as fixed in the [format notes](./mpeg-ts.md)

## Roles And Preconditions

As [`ts-carriage-integrity`](./ts-carriage-integrity.md), with the namespace
`("moq-test", "ts-late-subscriber", "<run-id>")`.

## Procedure

1. Complete publisher SETUP, send PUBLISH_NAMESPACE for the namespace and
   wait for REQUEST_OK. Publish the packaging's description track, if it has
   one.
2. Begin publishing the fixture at time T0, as the
   [packaging](./mpeg-ts.md#packaging) requires; it ends at T0 + 20 s, and
   the publisher then ends the track.
3. Before T0 + 8.5 s, complete subscriber SETUP and subscribe to the
   description track, if there is one. At T0 + 8.5 s, subscribe to the TS
   track with the [common subscription
   stimulus](../data-plane/README.md#common-subscription-stimulus). Note G,
   the highest Group ID the publisher has opened when the subscriber sends
   SUBSCRIBE for the TS track, and G′, the highest it has opened when
   SUBSCRIBE_OK arrives. The fixture has a random access point every second
   from T0 and a group starts only at one, so no group boundary is within
   0.5 s of the join; with a packaging that opens a group at each, the join
   is halfway through one. G′ is G unless the subscription takes that long
   to establish.
4. Record every object received on the TS track until the track has ended
   and its data streams have drained (the end of the track may arrive
   before the last of them), or until T0 + 30 s, whichever comes first, and
   [reassemble](./mpeg-ts.md#reassembly) them. Then close the subscriber,
   then the publisher: a publisher that closes as soon as it has ended the
   track can cut off the tail itself.
5. Verify with `check-ts.py --fixture fixture.ts --received received.ts
   --objects objects.txt --late-join`, adding `--catalog-expected` and
   `--catalog-received` where the packaging has a description track.

## Success Criteria

The test passes when:

- `catalog`: the description track, where the packaging has one, arrives as
  published;
- `byte-identical`: the non-null packets received are an unbroken tail of the
  fixture's, running to its end and containing a random access point;
- `ordering`: groups and objects arrive in order, with no gap or duplicate;
- `decode`: the stream decodes from its first random access point with the
  frame counts the fixture predicts;
- `packet-alignment`, `transport-errors`, `continuity`, `psi-unchanged` and
  `group-starts` pass;
- `join-point`: the lowest Group ID received is at least G and at most
  G′ + 1, the group after the one open when the subscription was established.
  This check is specific to the scenario; the client computes it and reports
  it as its own subtest.

Permitted variation: whether the stream starts with the group in progress at
the join, whole or part-way through (for example, a relay that delivers the
latest object, or a draft-20 and later subscription fill), or with the next
group; dropped null packets; object sizes and group boundaries within the
[packaging rules](./mpeg-ts.md#packaging); objects of adjacent groups
interleaving in time; and timing within the deadlines.

## Failure And Timeout Behavior

A request error or session failure before delivery is complete, or delivery
not complete by T0 + 30 s (fixture end plus 10 s), fails the test. Delivery
is complete as in
[`ts-carriage-integrity`](./ts-carriage-integrity.md#failure-and-timeout-behavior),
and `track_end` is likewise a diagnostic. A stream that skips or
repeats a group fails `ordering` or `byte-identical`, and one that starts
before G or after G′ + 1 fails `join-point`. The test takes about 30 s.

## Diagnostics

The client reports one test point, `ts-late-subscriber`, preceded by a
subtest block with the checks in the order the [format
notes](./mpeg-ts.md#oracle) list them, then `join-point`, in the area's [TAP
output](./README.md#tap-output) shape. The TAP YAML should carry
`media_format`, `ts_packaging`, `join_offset_ms`, `track_end`, `join_group`
and `join_group_ok` (G and G′), the shared counts, `first_group` and
`last_group`, `publisher` and `subscriber` session metadata, the fields
`check-ts.py` prints, and `first_mismatch` when a check fails.

## Revision History

- Revision 1: Initial proposal.

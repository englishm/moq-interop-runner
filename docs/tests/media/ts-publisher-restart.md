# MPEG-TS Publisher Restart

| Attribute | Value |
|-----------|-------|
| Identifier | `ts-publisher-restart` |
| Status | Proposal |
| Proposed placement | Media profile, MPEG-TS |
| Specification revision | 1 |

## Purpose

This test verifies that a subscriber recovers when the publisher's process
restarts mid-stream. The publisher's session ends without PUBLISH_DONE and a
new session publishes the same namespace a second later. A relay must accept
the new publisher, though the old session may not have been reaped yet, and
the subscriber must reach its track. Run on loopback through one relay, two TS
implementations lost 14 s and 43 s of the stream here, and the runs found two
defects on the way.

## Protocol References

As [`ts-carriage-integrity`](./ts-carriage-integrity.md#protocol-references).

## Roles And Preconditions

As
[`ts-carriage-integrity`](./ts-carriage-integrity.md#roles-and-preconditions),
with the namespace `("moq-test", "ts-publisher-restart", "<run-id>")`. The
test client opens a second `publisher` session for the restart.

## Procedure

1. As `ts-carriage-integrity` steps 1 to 3, publishing from T0.
2. At T0 + 8 s the publisher closes its QUIC connection abruptly (no
   PUBLISH_DONE, no GOAWAY). At T0 + 9 s a new publisher session completes
   SETUP, sends PUBLISH_NAMESPACE for the same namespace, and publishes the
   fixture from its first random access point at or after 9 s to its end.
3. The subscriber, subscribed before T0, records objects as in
   `ts-carriage-integrity`. When its subscription ends or errors, it
   subscribes again at once, as often as needed, until the track ends or
   T0 + 40 s.
4. Verify with `check-ts.py --fixture fixture.ts --received received.ts
   --objects objects.txt --restart-at 8`.

## Success Criteria

The test passes when:

- `byte-identical`: the received stream is the fixture from its start to some
  point at or before 8 s, then from the restarted publisher's first random
  access point to the end, each part an unbroken run (`--restart-at` allows
  one gap at the restart);
- `recovery`: the first object of the second part arrives within 5 s of the
  new publisher's PUBLISH_NAMESPACE;
- `ordering`, `packet-alignment`, `transport-errors` and `psi-unchanged` pass
  within each part.

Permitted variation: the subscription surviving the restart without a new
SUBSCRIBE; a relay sending PUBLISH_DONE or an error on the old subscription;
the relay sending PUBLISH_NAMESPACE to the new publisher, which must not end
its session.

## Failure And Timeout Behavior

No second part by T0 + 40 s fails the test. A new publisher session the relay
refuses or ends fails it, with the request error as a diagnostic.

## Diagnostics

As `ts-carriage-integrity`, with the test point `ts-publisher-restart`, adding
`recovery_ms`, the number of subscriptions the subscriber made, and how each
ended.

## Revision History

- Revision 1: Initial proposal.

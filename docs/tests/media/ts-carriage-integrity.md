# MPEG-TS Carriage Integrity

| Attribute | Value |
|-----------|-------|
| Identifier | `ts-carriage-integrity` |
| Status | Proposal |
| Proposed placement | MPEG-TS media profile |
| Specification revision | 1 |

## Purpose

This test verifies that a relay delivers a published MPEG-2 transport stream
to a subscriber unaltered: every packet, in order, with nothing lost,
duplicated, reordered or corrupted. Control-plane cells can all pass while no
usable media crosses a pairing; this test observes the media itself, and needs
no decoder or player to do it.

## Protocol References

- [MoQT draft 22](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-22): publishing namespaces, subscriptions, objects and groups
- [ISO/IEC 13818-1](https://www.iso.org/standard/87619.html): transport stream packets, continuity counters, PSI and `random_access_indicator`
- [MSF MPEG-TS packaging](https://datatracker.ietf.org/doc/draft-gregoire-moq-msfts/): one packaging the publisher may use

## Roles And Preconditions

The test client operates one publisher session and one subscriber session
through the relay under test, using the shared [fixture and
packaging](./mpeg-ts.md). The published namespace is
`("moq-test", "ts-carriage-integrity", "<run-id>")`, with `<run-id>` as in the
data-plane [test identity](../data-plane/README.md#test-identity). Track names
are the packaging's.

## Procedure

1. Complete publisher SETUP, send PUBLISH_NAMESPACE for the namespace and wait
   for REQUEST_OK.
2. Complete subscriber SETUP and subscribe to the packaging's TS track (after
   its catalog, if the packaging has one). Wait until the subscription is
   established.
3. Publish the whole fixture once, paced to its own PCR as a live source
   arrives, then end the track as the packaging does.
4. Reassemble the subscriber's objects as the packaging defines, and run
   `check-ts.py --fixture fixture.ts --received received.ts`.

## Success Criteria

The test passes when every `check-ts.py` check passes: the stream is whole
188-byte packets with no transport errors; every PID's continuity counter
advances by one; PAT and PMT are unchanged; and the non-null packets are the
fixture's, byte for byte, from its first random access point or earlier to its
end. The subscriber's group and object counts equal the publisher's.

Permitted variation: dropped null packets; packets before the fixture's first
random access point; object sizes and group boundaries within the
[packaging rules](./mpeg-ts.md#packaging); and timing within the deadlines.

## Failure And Timeout Behavior

A request error, session failure, or object delivery that has not completed
10 seconds after the publisher ends the track fails the test. The fixture
plays for 20 seconds, so the test takes about 30.

## Diagnostics

The TAP YAML should carry `ts_packaging`, the publisher's and subscriber's
group and object counts, received bytes, and the checker's diagnostics
(`suffix_start_packet`, or `aligned_at_packet` and `first_mismatch_packet` when
the bytes differ, and TSDuck's first continuity report).

## Revision History

- Revision 1: Initial proposal.

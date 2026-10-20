# MPEG-TS Late Subscriber

| Attribute | Value |
|-----------|-------|
| Identifier | `ts-late-subscriber` |
| Status | Proposal |
| Proposed placement | MPEG-TS media profile |
| Specification revision | 1 |

## Purpose

This test verifies that a subscriber joining a live transport stream partway
through receives a stream it can decode from the join: a byte-exact tail of
what was published, whose first video frame is a random access point, with
continuity clean from there. It is the join a viewer or a downstream
distribution hop makes, and the one a relay serves from its cache.

## Protocol References

- [MoQT draft 22](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-22): subscriptions, groups as join points, and the Location Filter
- [ISO/IEC 13818-1](https://www.iso.org/standard/87619.html): continuity counters, PSI and `random_access_indicator`

## Roles And Preconditions

As [`ts-carriage-integrity`](./ts-carriage-integrity.md), with the namespace
`("moq-test", "ts-late-subscriber", "<run-id>")`.

## Procedure

1. Complete publisher SETUP, send PUBLISH_NAMESPACE and wait for REQUEST_OK.
2. Start publishing the fixture once, paced to its own PCR.
3. 8.5 seconds after publishing starts, halfway through a group, complete
   subscriber SETUP and subscribe to the packaging's TS track, with whatever
   join the client normally uses for live media.
4. Let the publisher end the track at the end of the fixture.
5. Reassemble the subscriber's objects as the packaging defines, and run
   `check-ts.py --fixture fixture.ts --received received.ts --suffix`.

## Success Criteria

The test passes when every `check-ts.py` check passes: whole packets, no
transport errors, clean continuity, PAT and PMT unchanged, the non-null
packets a contiguous tail of the fixture's running to its end, and the first
video frame that starts in the stream a random access point.

Permitted variation: whether the stream starts at the group in progress at the
join (for example, a draft-22 Next Object subscription with a fill of the
current group) or at the next one; continuation packets of a frame that began
before the join; dropped null packets; and timing within the deadlines.

## Failure And Timeout Behavior

A request error, session failure, or object delivery that has not completed
10 seconds after the publisher ends the track fails the test. A stream that
starts mid-group, skips a group, or repeats one fails the byte or random
access check.

## Diagnostics

The TAP YAML should carry `ts_packaging`, the join offset, the first Group ID
received, received bytes, and the checker's diagnostics
(`suffix_start_packet`, or `aligned_at_packet` and `first_mismatch_packet`).

## Revision History

- Revision 1: Initial proposal.

# CMSF Live Join

| Attribute | Value |
|-----------|-------|
| Identifier | `cmsf-live-join` |
| Status | Proposal |
| Proposed placement | Media profile, CMSF |
| Specification revision | 1 |

## Purpose

This test verifies that a subscriber joining a live CMSF broadcast through a
relay receives the catalog and then media that is intact, in order, still
advancing, and decodable. It is the ordinary viewer join, and the baseline
the other CMSF scenarios vary.

## Protocol References

- [MoQT draft 18](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-18)
  and later: publishing namespaces, subscriptions, Namespace Prefix Matching,
  subgroup streams
- [MSF](https://datatracker.ietf.org/doc/draft-ietf-moq-msf/) and
  [CMSF](https://datatracker.ietf.org/doc/draft-ietf-moq-cmsf/): the catalog
  and the CMAF packaging, as fixed in the [format notes](./cmsf.md)

## Roles And Preconditions

The test client operates one `publisher` session and one `subscriber`
session through the relay under test, using the shared [fixture, packaging and
oracle](./cmsf.md). The published namespace is
`("moq-test", "cmsf-live-join", "<run-id>")`, with `<run-id>` as in the
data-plane [test identity](../data-plane/README.md#test-identity). Track
Names are `catalog`, `video` and `audio`.

## Procedure

1. Complete publisher SETUP, send PUBLISH_NAMESPACE for the namespace and
   wait for REQUEST_OK.
2. Publish `catalog` (Group 0, Object 0). Begin publishing `video` and
   `audio` at time T0, each object paced to its decode time as the
   [packaging rule](./cmsf.md#packaging) defines; the fixture ends at
   T0 + 10 s.
3. At T0 + 1.5 s, complete subscriber SETUP and subscribe to `catalog`.
   Receive its object, then subscribe to `video` and `audio`, the tracks the
   catalog names.
4. Record every object received on the media tracks, with its arrival time,
   until both tracks have delivered their last group (Group 9) completely, or
   until the deadline.
5. Verify as in the [oracle](./cmsf.md#oracle).

## Success Criteria

The test passes when:

- `catalog`: the catalog object arrives within 5 s of the subscribe and
  equals the expected catalog;
- `byte-identical`: every received media object matches the manifest;
- `ordering`: objects and groups are in order with no gap or duplicate
  between the first and last received group on each track;
- both tracks deliver Group 9 completely;
- media is still arriving at least 3 s after the first media object arrived
  (the subscriber is following a live edge, not draining a cache);
- `decode`: the reassembled complete groups of each track decode with the
  expected frame counts.

Permitted variation: the first received group (the one in progress at the
join, or the next); whether the head of the group in progress is delivered
or the first received group starts part-way; scheduling and arrival order
across the two tracks; and timing within the deadlines.

## Failure And Timeout Behavior

A request error, a session failure, a catalog that does not arrive within 5 s
of its subscribe, or media delivery that has not completed by T0 + 20 s
(fixture end plus 10 s) fails the test. A subscriber that receives nothing
after the catalog, receives objects whose payloads differ, or sees a Group ID
skipped or repeated fails on the corresponding check. The test takes about
15 s.

## Diagnostics

The TAP YAML should carry `media_format`, `join_offset_ms`, the shared
counts, `first_group` and `last_group`, the per-track `tracks` mapping from
the [format notes](./cmsf.md#diagnostics), `publisher` and `subscriber`
session metadata, and `first_mismatch` when a check fails.

## Revision History

- Revision 1: Initial proposal.

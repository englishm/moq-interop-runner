# CMSF Late Join After An Idle Catalog

| Attribute | Value |
|-----------|-------|
| Identifier | `cmsf-late-join-idle-catalog` |
| Status | Proposal |
| Proposed placement | Media profile, CMSF |
| Specification revision | 1 |

## Purpose

This test verifies that a subscriber who joins a CMSF broadcast after its
catalog has been idle for longer than the relay's cache window still receives
the catalog, and then the media that follows. An MSF catalog is published once
and changes rarely, so a relay that forgets a quiet track's latest group, and
does not fetch it again from the publisher, serves new viewers nothing while
existing viewers keep playing and every control-plane test stays green. The
procedure follows the reproduction in moq-dev/moq#5413: one catalog snapshot,
a reader that joins and leaves, a reader that stays, an idle period, then a
new reader.

## Protocol References

- [MoQT draft 18](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-18)
  and later: subscriptions, the largest object, subscription fills and
  joining FETCH as the means of obtaining the current group
- [MSF](https://datatracker.ietf.org/doc/draft-ietf-moq-msf/) draft 01,
  catalog snapshots: a new reader needs the latest Group of `catalog`

## Roles And Preconditions

The test client operates one `publisher` session and three subscriber
sessions, `subscriber_1`, `subscriber_2` and `subscriber_3`, through the
relay under test, using the shared [fixture, packaging and
oracle](./cmsf.md). The published namespace is
`("moq-test", "cmsf-late-join-idle-catalog", "<run-id>")`. Track Names are
`catalog`, `video` and `audio`.

The idle period is `MEDIA_IDLE_SECS`, default 70 s. It must exceed the time
the relay under test keeps a quiet track's latest group, or the test does not
exercise expiry. moq-relay's nominal cache window is 30 s, but its cache is
swept periodically and a quiet catalog group on moq-relay 0.17.3 was still
served after a 50 s idle and gone after 60 s; 70 s leaves margin for the
sweep phase. A relay whose window is longer passes without exercising it,
which the diagnostics make visible (`idle_ms`).

## Procedure

1. Complete publisher SETUP, send PUBLISH_NAMESPACE for the namespace and
   wait for REQUEST_OK.
2. Publish `catalog` (Group 0, Object 0) and Group 0 of `video` and `audio`,
   paced as in the [packaging rule](./cmsf.md#packaging). Then publish
   nothing.
3. Complete `subscriber_1` SETUP, subscribe to `catalog`, receive its object
   and compare it, then close the session.
4. Complete `subscriber_2` SETUP, subscribe to `catalog`, receive its object
   and compare it, and keep the session and the `catalog` subscription open
   for the rest of the test.
5. Wait `MEDIA_IDLE_SECS` with nothing published on any track.
6. Complete `subscriber_3` SETUP and subscribe to `catalog`. Its object must
   arrive within 5 s. Then subscribe to `video` and `audio`.
7. One second after `subscriber_3` subscribed to the media tracks, resume
   publishing: Groups 1 through 9 of `video` and `audio`, paced as before
   with Group 1 starting at the resume time.
8. Record every object `subscriber_3` receives until both tracks have
   delivered Group 9 completely, or until the deadline, then verify.
9. Close `subscriber_3`, then `subscriber_2`, then the publisher.

## Success Criteria

The test passes when:

- `catalog`: `subscriber_1`, `subscriber_2` and `subscriber_3` each receive
  the catalog within 5 s of subscribing, and it equals the expected catalog
  every time (it was published once and never changed);
- `byte-identical`: every media object `subscriber_3` receives matches the
  manifest;
- `ordering`: objects and groups are in order with no gap or duplicate
  between the first and last received group on each track;
- Groups 1 through 9 of both tracks arrive completely at `subscriber_3`;
- `decode`: the reassembled complete groups of each track decode with the
  expected frame counts.

Permitted variation: whether the relay serves `subscriber_3`'s catalog from
its cache or by a fresh upstream SUBSCRIBE (the publisher answers either);
whether `subscriber_3` also receives Group 0 of the media tracks (from the
relay's cache, or from the publisher's through a fill or joining FETCH);
scheduling across the two tracks; and timing within the deadlines.

## Failure And Timeout Behavior

A request error or session failure on any session fails the test. A catalog
that does not arrive within 5 s of a subscribe fails the `catalog` check; for
`subscriber_3` that is the property under test, and the message should say
whether the relay answered with REQUEST_ERROR or with nothing. Media delivery
not complete 10 s after the publisher's last object fails the test. The test
takes `MEDIA_IDLE_SECS` plus about 15 s, so about 85 s by default.

## Diagnostics

The TAP YAML should carry `media_format`, `idle_ms`, `catalog_ms` for each
subscriber session, the shared counts, `first_group` and `last_group`, the
per-track `tracks` mapping from the [format notes](./cmsf.md#diagnostics),
metadata for all four sessions, and `first_mismatch` when a check fails.

## Revision History

- Revision 1: Initial proposal.

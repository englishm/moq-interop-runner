# MPEG-TS Media Tests: Fixture And Oracle

This file defines the mechanics shared by tests that carry an MPEG-2 transport
stream (ISO/IEC 13818-1) through a relay and check what a subscriber
reassembles. The repository-wide [catalog and lifecycle](../README.md) apply.
The tests follow the data-plane [normal publication
flow](../data-plane/README.md#normal-publication-flow), [test
identity](../data-plane/README.md#test-identity) and [timeouts](../data-plane/README.md#timeouts-and-diagnostics)
unless a scenario overrides them.

The format is a property of the fixture and the oracle, not of the relay: a
relay forwards objects without reading them, so a relay cell reads relay ×
format. These tests aim at relays first. Publisher × subscriber cells across
implementations need a TS packaging both sides read, and today there are two
(the MSF `mpeg2ts` packaging of draft-gregoire-moq-msfts and
implementation-specific ones), so those cells are a later dimension.

## Proposed Scenarios

- [`ts-carriage-integrity`](./ts-carriage-integrity.md) verifies that a
  subscriber present from the start receives the published transport stream
  byte for byte.
- [`ts-late-subscriber`](./ts-late-subscriber.md) verifies that a subscriber
  joining mid-stream receives a byte-exact tail that a decoder can start on.

## Roles

The test client drives the publisher and the subscriber through the relay
under test, as `announce-subscribe` does. Both roles are the same
implementation, so they share a packaging (below).

## Fixture

The fixture is generated at image build time by
[`lib/media/mpeg-ts/make-fixture.sh`](../../../lib/media/mpeg-ts/make-fixture.sh),
so nothing large or rights-encumbered is committed. The publisher and the
checker read the same generated file. Its properties are set explicitly:

| Property | Value |
|----------|-------|
| Duration | 20 s |
| Video | H.264 Main, 640×360, 25 frame/s, 1.5 Mb/s, closed 1 s GOP, no B-frames, on PID 0x100 |
| Audio | AAC-LC, 48 kHz stereo, 128 kb/s, on PID 0x101 |
| Multiplex | one service (ID 1), PMT on PID 0x1000, constant 2 Mb/s padded with null packets, PCR every 20 ms, PAT and PMT every 100 ms |
| Random access points | every 1 s; the video packet that starts each keyframe sets `random_access_indicator` |

The generator applies the oracle to its own output and fails rather than emit
a fixture that would not pass.

## Packaging

The publisher maps the fixture to objects with a TS packaging the client names
in its TAP YAML as `ts_packaging`. Whatever the packaging, a scenario requires
that:

- each object payload, once any header the packaging defines is removed, is a
  run of whole 188-byte packets of the fixture, in fixture order;
- a group starts at a random access point, or at PSI immediately before it;
- the subscriber reassembles the stream by concatenating payloads in Group ID
  then Object ID order.

Null packets (PID 0x1FFF) are stuffing, and a packaging may drop them. A
packaging can only place packets in a group once one has started, so packets
before the fixture's first random access point may be missing. Both are
permitted variation, and the oracle allows for them.

## Oracle

[`lib/media/mpeg-ts/check-ts.py`](../../../lib/media/mpeg-ts/check-ts.py)
compares the reassembled stream with the fixture. It needs Python 3 and
TSDuck, and no decoder or player. It prints TAP version 14, one test point per
check:

| Check | Fails when |
|-------|-----------|
| `received-nonempty` | nothing was received |
| `packet-alignment` | the stream is not whole 188-byte packets each starting 0x47 |
| `transport-errors` | any packet sets `transport_error_indicator` |
| `continuity` | TSDuck's `continuity` plugin reports any PID's counter out of step |
| `psi-unchanged` | the distinct PAT and PMT sections differ from the fixture's |
| `byte-identical` | the non-null packets are not the fixture's from its first random access point or earlier (`ts-carriage-integrity`) |
| `byte-identical-suffix` | the non-null packets are not a contiguous tail of the fixture's (`ts-late-subscriber`) |
| `starts-at-random-access` | the first video frame that starts in the stream is not a random access point (`ts-late-subscriber`) |

Continuity counters make loss, duplication and reordering self-detecting per
PID without a reference, but they are blind to a corrupted payload byte; the
byte comparison catches that. The sensitivity tests in
[`lib/media/mpeg-ts/test/test-check-ts.sh`](../../../lib/media/mpeg-ts/test/test-check-ts.sh)
show each check catching the fault it targets and accepting the permitted
variations.

## Scope

These tests ask whether the subscriber got what the publisher sent. They do
not check TR 101 290, PCR jitter, constant-rate conformance or release timing:
those belong to the publisher's pacing and any downstream grooming, not to the
relay under test. Passing demonstrates only the scenario's behavior for the
observed client, relay, draft and transport.

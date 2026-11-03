# Media Test Conventions

This directory contains prose specifications for tests that carry a streaming
format through a relay and verify the media a subscriber reassembles. The
repository-wide [catalog and lifecycle](../README.md) applies to every test
here, and so do the data-plane [test identity](../data-plane/README.md#test-identity)
and [timeout](../data-plane/README.md#timeouts-and-diagnostics) conventions
unless a scenario overrides them.

Control-plane tests can all pass across a pairing through which no usable
media flows. Media tests observe the media itself, with an oracle that needs
no player: a fixture whose every object is known in advance, so the checker can
say exactly what arrived, in what order, and whether a decoder accepts it.

## Formats

The format is a property of the fixture and the checker, not of the relay. A
relay forwards objects without reading them, so a relay cell reads
relay × format, and each format defines its own fixture, packaging rule and
checks in a notes file beside this README:

- [CMSF](./cmsf.md): CMAF fragments described by an MSF catalog (the IETF
  media-over-QUIC streaming format).

Other formats add their own notes file in the same layout; MPEG-TS
(`mpeg-ts.md`, with `ts-carriage-integrity` and `ts-late-subscriber`) is
proposed separately. A scenario names the format it uses; its identifier
carries the format as a prefix (`cmsf-`, `ts-`) so a client can expose several
formats without ambiguity.

Formats differ in who sets the object boundaries. In CMSF the fixture does:
each CMAF fragment is one object, so the expected objects are known before
anything is published. In MPEG-TS the packaging does: the publisher decides
how many 188-byte packets make an object, so only the reassembled stream can
be compared with the fixture. The conventions below say which form applies
where that distinction matters.

## Proposed Scenarios

- [`cmsf-live-join`](./cmsf-live-join.md) verifies that a subscriber joining a
  live CMSF broadcast receives the catalog and then media that is intact, in
  order, still advancing, and decodable.
- [`cmsf-late-join-idle-catalog`](./cmsf-late-join-idle-catalog.md) verifies
  that a subscriber joining after the catalog has been idle longer than the
  relay's cache window still receives the catalog and the media that follows.

## Roles

A media scenario has three parts: a reference publisher, the relay under
test, and a checker subscriber. Today one test client drives the publisher and
the subscriber sessions through the relay, as `announce-subscribe` does, so
both roles are the same implementation and share the fixture and its manifest
from the same image. A scenario names its sessions `publisher` and
`subscriber`, or `subscriber_1`, `subscriber_2`, … when it has several, and
the client reports them under those keys in TAP YAML.

Publisher × checker pairing across implementations is a later dimension: it
needs the harness to run two client images against one relay and a way to
hand the checker the publisher's manifest. Nothing here prevents it; the
specifications only describe what each role does.

## Namespace

Each run publishes one broadcast whose Track Namespace is the data-plane
routing prefix `("moq-test", "<test-id>", "<run-id>")`, where `<test-id>` is
the scenario identifier and `<run-id>` follows [Test
Identity](../data-plane/README.md#test-identity). The publisher sends
PUBLISH_NAMESPACE for that prefix. Unlike data-plane scenarios, no MoQT Test
tuple follows it: the tracks of the format sit directly under the prefix. A
format whose fixture sets the objects also fixes the Track Names (for CMSF,
`catalog`, `video` and `audio`); a format whose packaging sets them (MPEG-TS)
leaves the Track Names to the packaging, and the client reports which
packaging it used (`ts_packaging`) so a reader of the result knows what the
names were. Either way the subscriber learns the names the same way a viewer
would: from the description track when the format has one, otherwise from the
packaging. The `moq-test` root lets deployments that limit anonymous
publication to test namespaces accept the run.

## Normal Flow

The flow is publisher first, as in the data-plane [normal publication
flow](../data-plane/README.md#normal-publication-flow):

1. The publisher and relay complete SETUP. The publisher sends
   PUBLISH_NAMESPACE for the routing prefix and receives REQUEST_OK.
2. The publisher publishes the format's description track (for CMSF, the
   catalog) and starts, or has already produced, media objects.
3. The subscriber and relay complete SETUP. The subscriber subscribes to the
   description track, parses it, then subscribes to the media tracks it
   names.
4. The subscriber records every object it receives (track, Group ID, Object
   ID, payload) until the scenario's end condition or deadline, then
   verifies.

The downstream SUBSCRIBE uses the data-plane [common subscription
stimulus](../data-plane/README.md#common-subscription-stimulus): no filter, so
the subscription starts at the live edge. A relay, or a draft-20 and later
subscription fill, may also deliver the head of the group in progress. Which
group and object a subscriber sees first is permitted variation; what follows
is not. A scenario may add a scripted timeline (a late join, an idle period)
around this flow.

## Fixtures

Fixtures are generated at image build time under `lib/media/<format>/`, so
nothing large or rights-encumbered is committed. Each format provides:

- `make-fixture.sh`, which produces the media (synthetic sources, fixed
  parameters, bit-exact where the toolchain allows);
- the oracle's reference: when the fixture sets the objects, a manifest
  builder derives the expected per-object data (hashes, sizes, media times)
  and the expected description track from the media; when the packaging sets
  them, the reference is the fixture stream itself and the format's notes say
  how the received stream is reassembled before comparison;
- a `test/` directory with a sensitivity test showing that the checks catch
  the faults they target and accept the permitted variations.

The publisher and the checker read the fixture and its reference from the same
image, because an encoder's output is reproducible within one build but not
necessarily across builds.

## Images

A media client is built under `builds/<impl>/` with the usual `config.json`,
`build.sh`, `Dockerfile.client` and `entrypoint-client.sh`, follows the [test
client interface](../../TEST-CLIENT-INTERFACE.md), lists the media identifiers
it supports through `--list`, and exits 127 for any other test. The runtime
image carries whatever the format's checks need (`ffprobe`, TSDuck), which
is why a media image is larger than a control-plane one.

Area-specific settings use the `MEDIA_` environment prefix. `MEDIA_FIXTURE_DIR`
points at the fixture and manifest inside the image, and `MEDIA_RUN_ID`
overrides the random run identifier for debugging. A scenario documents the
settings it adds.

## Oracle

Every media scenario asks whether the subscriber got what the publisher sent,
and whether a decoder would accept it. The checks have stable names so TAP
subtests and discussion can refer to them:

| Check | Passes when |
|-------|-------------|
| `catalog` | the received description track equals the expected one (for formats that have one) |
| `byte-identical` | the received bytes are the fixture's: when the fixture sets the objects, every received object payload matches the manifest's hash for its (track, group, object); when the packaging sets them, the stream reassembled from the received payloads in (group, object) order equals the fixture, or a contiguous tail of it from a random access point when the scenario permits a late join |
| `ordering` | groups are opened with increasing Group ID, within each group the objects are contiguous and in order, and the set between the first and last received group has no gap or duplicate; objects of adjacent groups may interleave in time |
| `decode` | the media reassembled from the received objects decodes with the frame counts the fixture predicts |

A format's notes say how each check is computed for that format, which form
of `byte-identical` applies, and which tool performs the decode. A format may
add checks of its own as further subtests (for MPEG-TS, the continuity and
PSI checks), named in its notes, and a scenario may add one for the property
it isolates (`live` in `cmsf-live-join`); the four above keep the same
meaning across formats so results can be read side by side.

## Diagnostics

A media client reports one TAP test point per scenario identifier, the unit
the harness counts. It should also report each check as a TAP subtest named
as above, so a failing run says which property failed. Beyond the [common
fields](../../TAP-YAML-METADATA.md#common-fields) and per-session
`moqt_version`, `transport` and `alpn`, the area shares these YAML names:

| Field | Meaning |
|-------|---------|
| `media_format` | the fixture's format; its value is the format's directory name under `lib/media/` (`cmsf`, `mpeg-ts`) |
| `groups_received` | groups received across the media tracks |
| `objects_received` | objects received across the media tracks |
| `bytes_received` | payload bytes received across the media tracks |
| `first_group` | the lowest Group ID received on a media track |
| `last_group` | the highest Group ID received on a media track |
| `join_offset_ms` | when the subscriber subscribed, relative to the start of publishing |
| `first_mismatch` | the first (track, group, object) whose payload or position differed, with what was expected and what arrived |
| `message` | a concise diagnostic, especially on failure |

A format adds its own fields under its own names (`ts_packaging`, or a
per-track `tracks` mapping) rather than redefining these.

## TAP Output

A media client follows the [test client
interface](../../TEST-CLIENT-INTERFACE.md): `--list` prints the scenario
identifiers it exposes, one per line; `TESTCASE` or `--test` selects one, and
an identifier it does not expose exits 127. The output is TAP version 14 with
one test point per scenario, the subtest block for the checks before it, and
the YAML block after it. The subtests are the area's four checks plus any
check the scenario adds under its own name (`live` in `cmsf-live-join`). A
passing `cmsf-live-join` against a draft-22 relay over raw QUIC looks like
this (the `tracks` mapping is abbreviated):

```tap
TAP version 14
# stitcher-moq-media-client v0.1.0 (moq-net 0.3.15 via moq-tokio 0.19.28)
# Relay: moqt://relay:4443
# Offered: moq-transport-22, moq-transport-21, moq-transport-20, moq-transport-19, moq-transport-18
# Fixture: cmsf 10000 ms, 1000 ms groups: audio 10 groups/47 objects/470 frames, video 10 groups/50 objects/300 frames
1..1
# Subtest: cmsf-live-join
    1..5
    ok 1 - catalog (received in 105 ms, equal to the expected catalog)
    ok 2 - byte-identical (87 objects match the manifest)
    ok 3 - ordering (18 groups in order, groups 9-9 complete on every track)
    ok 4 - decode (audio 420 frames, video 270 frames)
    ok 5 - live (media kept arriving for 7999 ms after the first object)
ok 1 - cmsf-live-join
  ---
  duration_ms: 10805
  implementation_version: "0.1.0"
  test_spec_revision: 1
  media_format: "cmsf"
  sessions:
    publisher:
      moqt_version: "moqt-22"
      transport: "quic"
      alpn: "moqt-22"
    subscriber:
      moqt_version: "moqt-22"
      transport: "quic"
      alpn: "moqt-22"
  run_id: "7dfdb7e04df778eb2c1130710d8b03cf"
  namespace: "moq-test/cmsf-live-join/7dfdb7e04df778eb2c1130710d8b03cf"
  join_offset_ms: 1687
  catalog_ms: 105
  groups_received: 18
  objects_received: 87
  bytes_received: 1894236
  first_group: 1
  last_group: 9
  tracks:
    audio:
      groups: 9
      objects: 42
      bytes: 149888
      first_group: 1
      first_object: 0
      last_group: 9
      complete_groups: 9
      decoded_frames: 420
      expected_frames: 420
    video:
      ...
  media_span_ms: 7999
  ...
```

A failing check is `not ok` in the subtest block with the reason in
parentheses, the parent test point is `not ok`, `message` repeats the first
failing check, and `first_mismatch` names the object when a payload or
position differed. The harness counts only the parent test point; the
subtests and YAML are for the reader.

## Timeouts

A media scenario runs for the length of its fixture plus whatever idle or
join delay it scripts, so each scenario states its own deadlines rather than
inheriting the data-plane 10-second delivery budget. A client that exposes
the two CMSF scenarios runs for about 100 seconds per relay endpoint, 70 of
them the idle period of `cmsf-late-join-idle-catalog`. The harness bounds each
client run with `TEST_TIMEOUT` (120 seconds by default) and runs every
scenario a client exposes in that one budget, so a media client is registered
as its own implementation entry rather than added to a control-plane client's
case list: the media run gets its own budget and its own column in the report.

The same rule applies across formats. The registry has no per-client timeout,
so a client whose scenarios together would not fit the budget registers one
implementation entry per format, each exposing that format's identifiers
(the entry name then carries the format, as in `<impl>-media-ts`); one entry
that exposes two formats is fine while their total stays well inside the
budget. If the harness later lets an entry declare its own timeout, entries
can be merged without changing any scenario.

## Relation To `publish-subscribe-media`

[`publish-subscribe-media`](../TEST-CASES.md#publish-subscribe-media) asks a
real player to decode two frames through the relay, a functional probe with a
different publisher and subscriber. The scenarios here are complementary: a
byte-exact, structural oracle that needs no player and can say which object
went missing. Neither replaces the other.

## Scope

Passing a media test demonstrates only the behavior in that scenario for the
observed client, relay, protocol draft, transport and format. It does not
check pacing, latency or any conformance property of the publisher, and it is
not a general MoQT or streaming-format conformance result.

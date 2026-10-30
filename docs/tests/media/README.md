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

Other formats add their own notes file in the same layout. A scenario names
the format it uses; its identifier carries the format as a prefix (`cmsf-`,
`ts-`) so a client can expose several formats without ambiguity.

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
tuple follows it: the tracks of the format sit directly under the prefix, with
the Track Names the format notes define (for CMSF, `catalog`, `video` and
`audio`). The `moq-test` root lets deployments that limit anonymous
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
- a manifest builder, which derives the expected per-object data (hashes,
  sizes, media times) and the expected description track from the media;
- a `test/` directory with a sensitivity test showing that the checks catch
  the faults they target and accept the permitted variations.

The publisher and the checker read the fixture and the manifest from the same
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
| `byte-identical` | every received object payload matches the manifest's hash for its (track, group, object) |
| `ordering` | groups are opened with increasing Group ID, within each group the objects are contiguous and in order, and the set between the first and last received group has no gap or duplicate; objects of adjacent groups may interleave in time |
| `decode` | the media reassembled from the received objects decodes with the frame counts the manifest predicts |

A format's notes say how each check is computed for that format and which
tool performs the decode. Byte identity is format-agnostic; the other three
are where a format's structure matters.

## Diagnostics

A media client reports one TAP test point per scenario identifier, the unit
the harness counts. It should also report each check as a TAP subtest named
as above, so a failing run says which property failed. Beyond the [common
fields](../../TAP-YAML-METADATA.md#common-fields) and per-session
`moqt_version`, `transport` and `alpn`, the area shares these YAML names:

| Field | Meaning |
|-------|---------|
| `media_format` | the format of the fixture, such as `cmsf` or `mpeg-ts` |
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

## Timeouts

A media scenario runs for the length of its fixture plus whatever idle or
join delay it scripts, so each scenario states its own deadlines rather than
inheriting the data-plane 10-second delivery budget. A client that exposes
the two CMSF scenarios runs for about 100 seconds per relay endpoint, 70 of
them the idle period of `cmsf-late-join-idle-catalog`. The harness bounds each
client run with `TEST_TIMEOUT` (120 seconds by default), so a media client is
registered as its own implementation entry rather than added to a
control-plane client's case list: the media run gets its own budget and its
own column in the report.

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

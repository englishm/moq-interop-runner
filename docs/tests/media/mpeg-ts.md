# MPEG-TS Media Tests: Fixture, Packaging And Oracle

This file defines the mechanics shared by tests that carry an MPEG-2
transport stream through a relay. The [media area conventions](./README.md)
apply (roles, namespace, flow, fixtures, diagnostics); this file fixes what is
specific to the format.

## Protocol References

- [ISO/IEC 13818-1](https://www.iso.org/standard/91403.html): transport
  stream packets, continuity counters, PSI and `random_access_indicator`
- [MSF MPEG-TS packaging](https://datatracker.ietf.org/doc/draft-gregoire-moq-msfts/):
  one packaging a client may use

## Fixture

[`lib/media/mpeg-ts/make-fixture.sh`](../../../lib/media/mpeg-ts/make-fixture.sh)
generates the fixture at image build time with ffmpeg; nothing binary is
committed. Every property a test relies on is set explicitly:

| Property | Value |
|----------|-------|
| Duration | 20 s |
| Video | `testsrc2`, 640×360, 25 frame/s, H.264 Main 4:2:0, 1.5 Mb/s, closed 1 s GOP, no B-frames, one encoder thread, on PID 0x100 |
| Audio | `sine` at 1 kHz, AAC-LC, 48 kHz stereo, 128 kb/s, on PID 0x101 |
| Multiplex | one service (ID 1), PMT on PID 0x1000, constant 2 Mb/s padded with null packets, PCR every 20 ms, PAT and PMT every 100 ms, bit-exact flags on |
| Random access points | every 1 s; the video packet that starts each keyframe sets `random_access_indicator` |

The encoder output is reproducible within one build, so the publisher and the
checker read `fixture.ts` from the same image. The generator runs the oracle
over its own output and fails rather than emit a fixture that would not pass.

## Packaging

MPEG-TS defines no MoQT mapping of its own. The publisher maps the fixture to
objects with a TS packaging, MSF `mpeg2ts` or an implementation's own, and
names it in its TAP YAML as `ts_packaging`. The packaging sets the Track
Names, the object boundaries and any description track. Whatever the
packaging, a scenario requires that:

- each object payload, once any header the packaging defines is removed, is a
  run of whole 188-byte packets of the fixture, in fixture order, from which
  null packets may have been removed;
- a group starts at a random access point, or at PSI immediately before it;
- Group IDs increase by one from each group to the next, and Object IDs start
  at 0 in each group and increase by one;
- the publisher sends the fixture once, paced to its PCR as a live source
  arrives, then ends the track as the packaging does.

Null packets (PID 0x1FFF) are stuffing, and a packaging may drop them. A
packaging can only place packets in a group once one has started, so packets
before the fixture's first random access point may be missing. Both are
permitted variation.

Both roles are one client today, so they share a packaging. Publisher ×
checker cells across implementations need a packaging both sides read, which
is why the client reports the one it used.

## Reassembly

The subscriber keeps two records of what it received on the TS track:

- `received.ts`: the object payloads, any packaging header removed,
  concatenated in (group, object) order;
- an object log: one line per object in arrival order, `<group> <object>
  <bytes>`, where `<bytes>` is what the object added to `received.ts`.

Where the packaging has a catalog track, it also keeps the catalog object as
received.

## Oracle

The checker applies the area's four [checks](./README.md#oracle), then five
of the format's own as further subtests, in this order:

| Check | Computation |
|-------|-------------|
| `catalog` | where the packaging has a catalog track, the catalog object received equals the one the publisher sent; otherwise not applicable, since MPEG-TS has no description track of its own, and reported as `ok # SKIP` so the shared names line up |
| `byte-identical` | the packaging-set form: `received.ts` is the fixture from some packet to its end with only null packets removed: its non-null packets are the fixture's, and each null packet it keeps is the fixture's at that place. Without a late join that packet is at or before the fixture's first random access point. With one it may fall part-way through a group (the end of the group in progress at the join, which a relay may deliver), and the stream must contain a random access point |
| `ordering` | over the object log: groups open with strictly increasing Group ID; each group's Object IDs arrive consecutive and in order, from 0 in every group but the first received; every Group ID between the first and last received appears; no object arrives twice; and the logged sizes add up to `received.ts`. Objects of adjacent groups may interleave in time; no others may |
| `decode` | from the first random access point in `received.ts` to its end, `ffprobe -count_frames` reports no error and the video and audio frame counts it reports for the fixture from the same packet. A leading partial group is skipped, as a decoder would skip it |
| `packet-alignment` | `received.ts` is whole 188-byte packets, each starting 0x47, and so is each object in the object log |
| `transport-errors` | no packet sets `transport_error_indicator` |
| `continuity` | TSDuck's `continuity` plugin reports no PID's counter out of step |
| `psi-unchanged` | the distinct PAT and PMT sections equal the fixture's |
| `group-starts` | over the object log: each group starts at a random access point, or at PSI immediately before one, as the [packaging](#packaging) requires; with a late join the first group received is exempt when it arrives part-way, from an Object ID above 0 |

Continuity counters make the loss, duplication or reordering of packets
self-detecting per PID with no reference, which is what makes TS a cheap
fixture. They are blind to a corrupted payload byte, which `byte-identical`
catches, and the bytes are blind to objects that arrive out of order, which
`ordering` catches.

[`lib/media/mpeg-ts/check-ts.py`](../../../lib/media/mpeg-ts/check-ts.py) is
the reference implementation of all nine checks, with Python 3, TSDuck and
ffprobe; `--late-join` selects the late-join form of `byte-identical`,
`ordering` and `group-starts` are skipped when no object log is given, and
`catalog` is skipped unless `--catalog-expected` and `--catalog-received` give
the catalog objects. The sensitivity test in
[`lib/media/mpeg-ts/test/test-check-ts.sh`](../../../lib/media/mpeg-ts/test/test-check-ts.sh)
packages the fixture the way a publisher would and shows each check catching
the fault it targets: packets dropped, duplicated or transposed; a flipped
payload byte; a changed or moved null packet; a truncated tail; a transport error; a changed PMT; a lost video
frame; a stream or an object not cut on packet boundaries; a skipped group; swapped
objects; a group opened early; an object received twice; a later group that
starts part-way; an object arriving once a group two later has opened; a group,
or a late join's first whole group, that starts between random access points;
and a catalog changed in transit. It also shows the checks accepting the permitted
variations: dropped null packets, a stream from the first random access point,
a late join at or part-way through a group, and adjacent groups interleaving.

## Diagnostics

Beside the area's shared fields, a TS client reports `ts_packaging` and
`track_end`. `groups_received`, `objects_received`, `bytes_received`,
`first_group` and `last_group` come from the object log, so `bytes_received`
counts what the objects added to `received.ts`. `check-ts.py` prints these,
with the format's own, as `# key: value` lines a client can lift into its
YAML block; `track_end` is the client's:

| Field | Meaning |
|-------|---------|
| `track_end` | how the TS track ended for the subscriber: `finished`, the error that ended it, or that it had not ended by the deadline; a diagnostic, not graded |
| `ts_packets_received`, `ts_null_packets_received` | packets in `received.ts`, and how many of them are null |
| `ts_tail_start_packet` | the fixture packet `received.ts` starts at, when it is a tail of the fixture |
| `ts_first_object` | the Object ID at which the first received group starts |
| `ts_decode_start_packet` | the packet of `received.ts` at which `decode` starts |
| `ts_decoded_frames`, `ts_expected_frames` | video and audio frames decoded from there, and the fixture's from the same packet |
| `ts_continuity_first` | TSDuck's first continuity report |
| `first_mismatch` | the first packet of `received.ts` that differs, its group and object when an object log is given, and the PID and continuity counter expected and found |

`media_format` is `mpeg-ts`.

## Scope

These tests ask whether the subscriber got the transport stream the publisher
sent and whether a decoder accepts it. They do not check TR 101 290, PCR
jitter, constant-rate conformance or release timing: those belong to the
publisher's pacing and any downstream grooming, not to the relay under test.

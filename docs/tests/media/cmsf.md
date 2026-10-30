# CMSF Media Tests: Fixture, Packaging And Oracle

This file defines the mechanics shared by tests that carry CMSF through a
relay: CMAF fragments on MoQT tracks, described by an MSF catalog. The [media
area conventions](./README.md) apply (roles, namespace, flow, fixtures,
diagnostics); this file fixes what is specific to the format.

## Protocol References

- [MSF](https://datatracker.ietf.org/doc/draft-ietf-moq-msf/) draft 01: the
  catalog track, its `catalog` Track Name, snapshots in Object 0 of a Group,
  `initDataList` and `initRef`
- [CMSF](https://datatracker.ietf.org/doc/draft-ietf-moq-cmsf/): the `cmaf`
  packaging, one CMAF track per MoQT track, fragments as objects
- [ISO/IEC 23000-19](https://www.iso.org/standard/85623.html) (CMAF) and
  [ISO/IEC 14496-12](https://www.iso.org/standard/83102.html) (ISOBMFF):
  `ftyp`, `moov`, `moof`, `mdat`, `tfdt`, `trun`

## Fixture

[`lib/media/cmsf/make-fixture.sh`](../../../lib/media/cmsf/make-fixture.sh)
generates the fixture at image build time with ffmpeg; nothing binary is
committed. Every property a test relies on is set explicitly:

| Property | Value |
|----------|-------|
| Duration | 10 s |
| Video | `testsrc2`, 640×360, 30 frame/s, H.264 Main 4:2:0, 1.5 Mb/s, closed 1 s GOP (`-g 30 -keyint_min 30 -sc_threshold 0 -bf 0`), one encoder thread |
| Audio | `sine` at 1 kHz, AAC-LC, 48 kHz stereo, 128 kb/s |
| Container | one CMAF track file per track (`video.mp4`, `audio.mp4`): `-movflags cmaf+frag_keyframe+empty_moov+default_base_moof -frag_duration 200000`, bit-exact flags on |
| Init segment | `ftyp` + `moov`, everything before the first `moof` |
| Fragment | one `moof` + `mdat` pair; 200 ms of video (6 frames), about 213 ms of audio (10 AAC frames) |

The encoder output is reproducible within one build, so the publisher and the
checker read `video.mp4`, `audio.mp4`, `manifest.json` and `catalog.json`
from the same image. The generator runs the manifest builder's own
verification over its output and fails rather than emit a fixture that would
not pass.

## Packaging

The publisher maps each CMAF track file to one MoQT track with the rule
moq-net's fmp4 import uses: a group is a segment and each fragment in it is
an object.

- Track Names are `catalog`, `video` and `audio`, directly under the run's
  routing prefix.
- `catalog` carries the MSF catalog as one Group (ID 0) with one Object
  (ID 0), the UTF-8 JSON of `catalog.json`. The init segments travel inside
  it (`initDataList`, base64) and are never sent as objects.
- A media track's Group ID is the whole second in which the fragment's
  decode time starts: `floor(tfdt / timescale)`. A video group therefore
  starts on a keyframe. The Object ID is the fragment's position within its
  group, starting at 0. All objects of a group travel on subgroup 0.
- Object payloads are whole fragments (`moof` + `mdat`), unmodified.
- The publisher sends objects in decode order, paced to their `tfdt`:
  object `(g, i)` with decode time `t` seconds goes out `t` seconds after
  publishing started (or after the resume point a scenario defines).

With the fixture above, `video` has groups 0–9 of 5 objects each and
`audio` has groups 0–9 of 4 or 5 objects (47 fragments), so the manifest, not
arithmetic, is the reference for the expected object set.

## Manifest

[`lib/media/cmsf/manifest.py`](../../../lib/media/cmsf/manifest.py)
`build` reads the two track files and writes `manifest.json` and
`catalog.json`. The manifest is the oracle's reference:

```json
{
  "format": "cmsf",
  "generator": {"ffmpeg": "<ffmpeg -version first line>"},
  "duration_ms": 10000,
  "group_ms": 1000,
  "tracks": {
    "video": {
      "file": "video.mp4",
      "sha256": "<sha256 of the whole file>",
      "codec": "avc1.4d401e",
      "timescale": 15360,
      "frames": 300,
      "init": {"offset": 0, "bytes": 756, "sha256": "..."},
      "groups": [
        {"group": 0, "objects": [
          {"object": 0, "offset": 756, "bytes": 30498, "tfdt": 0, "samples": 6, "sha256": "..."}
        ]}
      ]
    },
    "audio": {"...": "same shape"}
  }
}
```

Field by field:

| Field | Meaning |
|-------|---------|
| `tracks.<name>.file`, `sha256` | the track file and its hash, so a checker can confirm it holds the fixture the manifest describes |
| `codec` | the RFC 6381 codec string the catalog carries |
| `timescale` | the track's `mdhd` timescale; `tfdt` values are in these units |
| `frames` | samples in the whole track, the `decode` check's reference for a complete track |
| `init` | byte range and hash of the init segment |
| `groups[].group` | Group ID, as the packaging rule derives it |
| `objects[].object` | Object ID within the group |
| `objects[].offset`, `bytes` | the fragment's byte range in the track file |
| `objects[].tfdt` | the fragment's decode time (`tfdt`), which also sets its send time |
| `objects[].samples` | samples in the fragment (`trun` sample count), the `decode` check's reference |
| `objects[].sha256` | hash of the fragment bytes, the `byte-identical` check's reference |

`catalog.json` is the expected MSF catalog: `version` `"draft-01"`, two
tracks with `packaging` `"cmaf"`, `isLive`, `role`, `codec`, the video
dimensions and frame rate or the audio sample rate and channel configuration,
and an `initRef` into `initDataList`, whose entries carry each init segment
as inline base64. It holds no generation time or other volatile field, so the
published catalog equals it byte for byte, and comparison is on the parsed
JSON (key order does not matter).

## Oracle

The checker applies the area's four [checks](./README.md#oracle) as follows.

| Check | Computation |
|-------|-------------|
| `catalog` | the first object of the first group received on `catalog`, parsed as JSON, equals `catalog.json` parsed as JSON; the deadline is the scenario's |
| `byte-identical` | for every received object on `video` and `audio`, SHA-256 of the payload equals `objects[].sha256` for that (track, group, object); an object at a (group, object) the manifest does not list fails |
| `ordering` | per track: the relay opens groups with strictly increasing Group ID; Object IDs within each received group are consecutive from the first received one to the manifest's last; every Group ID between the first and last received is present exactly once. Objects of adjacent groups may interleave in time (independent streams; a fill of the current group's head may land after the next group starts) |
| `decode` | per track: the init segment followed by the payloads of every complete received group, in (group, object) order, is written to a file; `ffprobe -count_frames` on it reports no error and a frame count equal to the sum of `samples` over those fragments |

A complete group is one whose received objects run from Object 0 to the
manifest's last object. The first received group may start part-way (a join
at the live edge), and the `decode` check then begins at the next group, as a
player would. Each scenario says which groups must be complete.

[`manifest.py verify`](../../../lib/media/cmsf/manifest.py) is the reference
implementation of `byte-identical`, `ordering` and `decode` over a
reassembled track file, and the sensitivity test in
[`lib/media/cmsf/test/test-manifest.sh`](../../../lib/media/cmsf/test/test-manifest.sh)
shows each check catching the fault it targets (a flipped payload byte, a
dropped fragment, two swapped fragments, a truncated tail) and accepting a
tail that starts at a group boundary.

## Diagnostics

Beside the area's shared fields, a CMSF client reports a `tracks` mapping
with, per media track, `groups`, `objects`, `bytes`, `first_group`,
`first_object`, `last_group`, `complete_groups`, `decoded_frames` and
`expected_frames`, and `catalog_ms` (time from the catalog SUBSCRIBE to its
object). `media_format` is `cmsf`.

## Scope

These tests ask whether the subscriber got the CMSF the publisher sent and
whether a decoder accepts it. They do not check timing, segment duration
conformance, catalog semantics beyond equality, or player behavior.

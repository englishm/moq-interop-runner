#!/usr/bin/env python3
"""manifest.py - the manifest builder and reference oracle for the CMSF media tests.

docs/tests/media/cmsf.md defines the fixture, the packaging rule (a group is the whole
second a fragment's decode time starts in, an object is one moof+mdat fragment) and the
manifest schema this script writes and reads.

  manifest.py build --fixture-dir DIR [--duration-ms N] [--generator TEXT]
      Reads DIR/video.mp4 and DIR/audio.mp4, writes DIR/manifest.json (per-object SHA-256,
      byte ranges, decode times, sample counts) and DIR/catalog.json (the expected MSF
      draft-01 catalog, init segments inline as base64).

  manifest.py verify --manifest manifest.json --track NAME --file received.mp4 [--decode]
      Applies the byte-identical, ordering and (with --decode) decode checks to a track file
      reassembled from received objects: init segment, then fragments in (group, object)
      order. The first fragment may be any object (a join at the live edge); from there the
      sequence must run to the manifest's last object without a gap, duplicate or
      corrupted fragment. Decode covers the complete groups, as a player would.

  manifest.py verify-catalog --expected catalog.json --received FILE
      The catalog check: both parse as JSON and are equal (key order does not matter).

verify prints TAP version 14, one test point per check, then diagnostics as `# key: value`
comments. Exit 0 when every check passes, 1 when any fails, 2 on a usage or environment
error. Only the standard library is needed; --decode needs ffprobe on PATH.
"""

import argparse
import base64
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from typing import Dict, List, Optional, Tuple

FORMAT = "cmsf"
GROUP_MS = 1000
TRACKS = ("video", "audio")
# Boxes that open a fragment ahead of its moof.
FRAGMENT_PREFIX = {b"styp", b"sidx", b"prft", b"emsg"}
# Boxes a muxer may append after the last fragment; not part of any object.
TRAILER = {b"mfra", b"free", b"skip"}


# ----------------------------------------------------------------------------- ISOBMFF


def boxes(data: bytes, start: int = 0, end: Optional[int] = None) -> List[Tuple[bytes, int, int, int]]:
    """Top-level boxes in data[start:end] as (type, offset, size, header_size)."""
    end = len(data) if end is None else end
    out = []
    i = start
    while i + 8 <= end:
        size, kind = struct.unpack(">I4s", data[i:i + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[i + 8:i + 16])[0]
            header = 16
        elif size == 0:
            size = end - i
        if size < header or i + size > end:
            raise ValueError("malformed box %r at %d" % (kind, i))
        out.append((kind, i, size, header))
        i += size
    if i != end:
        raise ValueError("%d trailing bytes after the last box" % (end - i))
    return out


def find(data: bytes, start: int, end: int, path: List[bytes]) -> Optional[Tuple[int, int, int]]:
    """The first box at `path` under data[start:end], as (offset, size, header_size)."""
    cur = (start, end - start, 0)
    for kind in path:
        found = None
        for ck, co, cs, ch in boxes(data, cur[0] + cur[2], cur[0] + cur[1]):
            if ck == kind:
                found = (co, cs, ch)
                break
        if found is None:
            return None
        cur = found
    return cur


def split_track(data: bytes) -> Tuple[Tuple[int, int], List[Tuple[int, int]]]:
    """(init range, [fragment ranges]) of a CMAF track file.

    The init segment is everything before the first fragment. A fragment starts at the
    first box after the init or after the previous mdat, and ends with its mdat. A
    trailer (mfra) after the last mdat belongs to neither.
    """
    init_end = None
    fragments = []
    frag_start = None
    for kind, off, size, _ in boxes(data):
        if init_end is None:
            if kind == b"moof" or kind in FRAGMENT_PREFIX:
                init_end = off
            else:
                continue
        if frag_start is None:
            if kind in TRAILER:
                continue
            frag_start = off
        if kind == b"mdat":
            fragments.append((frag_start, off + size - frag_start))
            frag_start = None
    if init_end is None:
        raise ValueError("no fragment found")
    if frag_start is not None:
        raise ValueError("the last fragment has no mdat")
    return (0, init_end), fragments


def fragment_info(data: bytes, off: int, size: int) -> Tuple[int, int]:
    """(tfdt, sample count) of the fragment at data[off:off+size]."""
    moof = None
    for kind, o, s, h in boxes(data, off, off + size):
        if kind == b"moof":
            moof = (o, s, h)
            break
    if moof is None:
        raise ValueError("fragment without moof")
    traf = find(data, moof[0] + moof[2], moof[0] + moof[1], [b"traf"])
    if traf is None:
        raise ValueError("moof without traf")
    tfdt = None
    samples = 0
    for kind, o, s, h in boxes(data, traf[0] + traf[2], traf[0] + traf[1]):
        if kind == b"tfdt":
            version = data[o + h]
            if version == 1:
                tfdt = struct.unpack(">Q", data[o + h + 4:o + h + 12])[0]
            else:
                tfdt = struct.unpack(">I", data[o + h + 4:o + h + 8])[0]
        elif kind == b"trun":
            samples += struct.unpack(">I", data[o + h + 4:o + h + 8])[0]
    if tfdt is None:
        raise ValueError("traf without tfdt")
    return tfdt, samples


def track_properties(data: bytes, init_end: int) -> Dict[str, object]:
    """timescale, codec string and stream properties from the init segment."""
    moov = find(data, 0, init_end, [b"moov"])
    if moov is None:
        raise ValueError("init segment without moov")
    trak = find(data, moov[0] + moov[2], moov[0] + moov[1], [b"trak"])
    if trak is None:
        raise ValueError("moov without trak")
    mdhd = find(data, trak[0] + trak[2], trak[0] + trak[1], [b"mdia", b"mdhd"])
    if mdhd is None:
        raise ValueError("trak without mdhd")
    version = data[mdhd[0] + mdhd[2]]
    body = mdhd[0] + mdhd[2] + 4
    timescale = struct.unpack(">I", data[body + 16:body + 20])[0] if version == 1 \
        else struct.unpack(">I", data[body + 8:body + 12])[0]
    stsd = find(data, trak[0] + trak[2], trak[0] + trak[1], [b"mdia", b"minf", b"stbl", b"stsd"])
    if stsd is None:
        raise ValueError("trak without stsd")
    entries = boxes(data, stsd[0] + stsd[2] + 8, stsd[0] + stsd[1])
    if not entries:
        raise ValueError("stsd without a sample entry")
    kind, eo, es, eh = entries[0]
    props: Dict[str, object] = {"timescale": timescale}
    if kind == b"avc1":
        # VisualSampleEntry: 6 reserved + 2 data_reference_index, then 16 bytes of
        # pre-defined/reserved, then width and height.
        width, height = struct.unpack(">HH", data[eo + eh + 24:eo + eh + 28])
        avcc = find(data, eo + eh + 78, eo + es, [b"avcC"])
        if avcc is None:
            raise ValueError("avc1 without avcC")
        c = avcc[0] + avcc[2]
        profile, compat, level = data[c + 1], data[c + 2], data[c + 3]
        props.update(role="video", codec="avc1.%02x%02x%02x" % (profile, compat, level),
                     width=width, height=height)
    elif kind == b"mp4a":
        # AudioSampleEntry: 6 reserved + 2 data_reference_index, 8 reserved, channelcount,
        # samplesize, 4 pre-defined/reserved, samplerate as 16.16.
        channels = struct.unpack(">H", data[eo + eh + 16:eo + eh + 18])[0]
        samplerate = struct.unpack(">I", data[eo + eh + 24:eo + eh + 28])[0] >> 16
        esds = find(data, eo + eh + 28, eo + es, [b"esds"])
        if esds is None:
            raise ValueError("mp4a without esds")
        oti, aot = es_descriptor_types(data, esds[0] + esds[2] + 4, esds[0] + esds[1])
        props.update(role="audio", codec="mp4a.%02x.%d" % (oti, aot),
                     samplerate=samplerate, channel_config=str(channels))
    else:
        raise ValueError("unsupported sample entry %r" % kind)
    return props


def es_descriptor_types(data: bytes, start: int, end: int) -> Tuple[int, int]:
    """(objectTypeIndication, audioObjectType) from an ES_Descriptor."""
    def descriptor(pos: int) -> Tuple[int, int, int]:
        tag = data[pos]
        pos += 1
        length = 0
        for _ in range(4):
            b = data[pos]
            pos += 1
            length = (length << 7) | (b & 0x7F)
            if not b & 0x80:
                break
        return tag, pos, length

    tag, pos, _ = descriptor(start)
    if tag != 0x03:
        raise ValueError("esds without ES_Descriptor")
    flags = data[pos + 2]
    pos += 3
    if flags & 0x80:
        pos += 2
    if flags & 0x40:
        pos += 1 + data[pos]
    if flags & 0x20:
        pos += 2
    tag, pos, _ = descriptor(pos)
    if tag != 0x04:
        raise ValueError("ES_Descriptor without DecoderConfigDescriptor")
    oti = data[pos]
    pos += 13
    tag, pos, _ = descriptor(pos)
    if tag != 0x05:
        raise ValueError("DecoderConfigDescriptor without DecoderSpecificInfo")
    aot = data[pos] >> 3
    if aot == 31:
        aot = 32 + (((data[pos] & 0x07) << 3) | (data[pos + 1] >> 5))
    return oti, aot


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ----------------------------------------------------------------------------- build


def describe_track(path: str) -> Tuple[Dict[str, object], bytes, Dict[str, object]]:
    """(manifest entry, init bytes, stream properties) for one CMAF track file."""
    with open(path, "rb") as f:
        data = f.read()
    (init_off, init_len), fragments = split_track(data)
    props = track_properties(data, init_len)
    timescale = int(props["timescale"])
    groups: Dict[int, List[Dict[str, object]]] = {}
    frames = 0
    for off, size in fragments:
        tfdt, samples = fragment_info(data, off, size)
        group = tfdt * 1000 // timescale // GROUP_MS
        groups.setdefault(group, []).append({
            "object": len(groups.get(group, [])),
            "offset": off,
            "bytes": size,
            "tfdt": tfdt,
            "samples": samples,
            "sha256": sha256(data[off:off + size]),
        })
        frames += samples
    entry: Dict[str, object] = {
        "file": os.path.basename(path),
        "sha256": sha256(data),
        "codec": props["codec"],
        "timescale": timescale,
        "frames": frames,
        "init": {"offset": init_off, "bytes": init_len, "sha256": sha256(data[init_off:init_off + init_len])},
        "groups": [{"group": g, "objects": groups[g]} for g in sorted(groups)],
    }
    return entry, data[init_off:init_off + init_len], props


def build_catalog(props: Dict[str, Dict[str, object]], inits: Dict[str, bytes], fps: Optional[float]) -> Dict[str, object]:
    """The expected MSF draft-01 catalog: nothing volatile, init segments inline."""
    tracks = []
    for name in TRACKS:
        p = props[name]
        track: Dict[str, object] = {
            "name": name,
            "packaging": "cmaf",
            "isLive": True,
            "role": p["role"],
            "codec": p["codec"],
        }
        if p["role"] == "video":
            track["width"] = p["width"]
            track["height"] = p["height"]
            if fps is not None:
                track["framerate"] = fps
        else:
            track["samplerate"] = p["samplerate"]
            track["channelConfig"] = p["channel_config"]
        track["initRef"] = name
        tracks.append(track)
    return {
        "version": "draft-01",
        "tracks": tracks,
        "initDataList": [
            {"id": name, "type": "inline", "data": base64.b64encode(inits[name]).decode("ascii")}
            for name in TRACKS
        ],
    }


def cmd_build(args: argparse.Namespace) -> int:
    entries: Dict[str, object] = {}
    props: Dict[str, Dict[str, object]] = {}
    inits: Dict[str, bytes] = {}
    for name in TRACKS:
        entry, init, p = describe_track(os.path.join(args.fixture_dir, name + ".mp4"))
        entries[name] = entry
        props[name] = p
        inits[name] = init
    video = entries["video"]
    fps = None
    if args.duration_ms and int(video["frames"]) > 0:
        fps = int(video["frames"]) * 1000 / args.duration_ms
        fps = int(fps) if fps == int(fps) else round(fps, 3)
    manifest = {
        "format": FORMAT,
        "generator": {"ffmpeg": args.generator or "unknown"},
        "duration_ms": args.duration_ms,
        "group_ms": GROUP_MS,
        "tracks": entries,
    }
    with open(os.path.join(args.fixture_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(args.fixture_dir, "catalog.json"), "w") as f:
        json.dump(build_catalog(props, inits, fps), f, indent=1, sort_keys=True)
        f.write("\n")
    for name in TRACKS:
        e = entries[name]
        objects = sum(len(g["objects"]) for g in e["groups"])
        print("manifest: %s %s, timescale %d, %d groups, %d objects, %d frames" % (
            name, e["codec"], e["timescale"], len(e["groups"]), objects, e["frames"]))
    return 0


# ----------------------------------------------------------------------------- verify


def manifest_objects(track: Dict[str, object]) -> List[Dict[str, object]]:
    """The track's objects in (group, object) order, each with its group id added."""
    out = []
    for g in track["groups"]:
        for o in g["objects"]:
            d = dict(o)
            d["group"] = g["group"]
            out.append(d)
    return out


def tap(results: List[Tuple[str, bool, str]], diag: Dict[str, object]) -> int:
    print("TAP version 14")
    print("1..%d" % len(results))
    for n, (name, ok, detail) in enumerate(results, 1):
        print("%s %d - %s (%s)" % ("ok" if ok else "not ok", n, name, detail))
    for key, value in diag.items():
        print("# %s: %s" % (key, value))
    return 0 if all(ok for _, ok, _ in results) else 1


def ffprobe_frames(path: str, role: str) -> Tuple[Optional[int], str]:
    """(decoded frame count, stderr) from ffprobe, counting frames by decoding them."""
    stream = "v:0" if role == "video" else "a:0"
    run = subprocess.run(
        ["ffprobe", "-v", "error", "-count_frames", "-select_streams", stream,
         "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", path],
        capture_output=True, text=True, check=False)
    out = run.stdout.strip().strip(",")
    frames = int(out) if out.isdigit() else None
    return frames, run.stderr.strip()


def cmd_verify(args: argparse.Namespace) -> int:
    with open(args.manifest) as f:
        manifest = json.load(f)
    if args.track not in manifest["tracks"]:
        print("Bail out! track %r not in the manifest" % args.track)
        return 2
    track = manifest["tracks"][args.track]
    expected = manifest_objects(track)
    by_tfdt = {o["tfdt"]: i for i, o in enumerate(expected)}
    with open(args.file, "rb") as f:
        data = f.read()

    results: List[Tuple[str, bool, str]] = []
    diag: Dict[str, object] = {"track": args.track, "received_bytes": len(data)}

    try:
        (init_off, init_len), fragments = split_track(data)
    except ValueError as err:
        results.append(("byte-identical", False, "not a CMAF track file: %s" % err))
        results.append(("ordering", False, "not a CMAF track file"))
        if args.decode:
            results.append(("decode", False, "not a CMAF track file"))
        return tap(results, diag)

    init_ok = sha256(data[init_off:init_off + init_len]) == track["init"]["sha256"]
    diag["fragments"] = len(fragments)

    # Identify each received fragment by its decode time, then compare bytes.
    received: List[Optional[int]] = []  # index into `expected`, or None if unknown
    mismatch = None
    for pos, (off, size) in enumerate(fragments):
        try:
            tfdt, _ = fragment_info(data, off, size)
            idx = by_tfdt.get(tfdt)
        except ValueError:
            idx = None
        received.append(idx)
        if idx is None:
            if mismatch is None:
                mismatch = {"position": pos, "expected": None, "got": sha256(data[off:off + size])}
            continue
        got = sha256(data[off:off + size])
        if got != expected[idx]["sha256"] and mismatch is None:
            mismatch = {"position": pos, "group": expected[idx]["group"], "object": expected[idx]["object"],
                        "expected": expected[idx]["sha256"], "got": got}
    bytes_ok = init_ok and mismatch is None and bool(fragments)
    if not init_ok:
        detail = "init segment differs from the manifest"
    elif not fragments:
        detail = "no fragment received"
    elif mismatch is None:
        detail = "init segment and %d fragments match the manifest" % len(fragments)
    elif mismatch["expected"] is None:
        detail = "fragment %d matches no manifest object" % mismatch["position"]
    else:
        detail = "fragment %d (group %d, object %d) differs" % (
            mismatch["position"], mismatch["group"], mismatch["object"])
    results.append(("byte-identical", bytes_ok, detail))
    if mismatch is not None:
        diag["first_mismatch"] = json.dumps(mismatch)

    # Ordering: a contiguous run of manifest objects from the first received to the last.
    known = [i for i in received if i is not None]
    order_ok = False
    if known:
        first = known[0]
        run = list(range(first, first + len(received)))
        contiguous = received == run
        to_end = known[-1] == len(expected) - 1
        order_ok = contiguous and to_end
        diag["first_group"] = expected[first]["group"]
        diag["first_object"] = expected[first]["object"]
        diag["last_group"] = expected[known[-1]]["group"]
        if order_ok:
            detail = "%d fragments in order from group %d object %d to the end" % (
                len(received), expected[first]["group"], expected[first]["object"])
        elif not contiguous:
            bad = next(p for p, (r, e) in enumerate(zip(received, run)) if r != e)
            if received[bad] is None:
                detail = "fragment %d is unknown" % bad
            else:
                detail = "fragment %d is group %d object %d, expected group %d object %d" % (
                    bad, expected[received[bad]]["group"], expected[received[bad]]["object"],
                    expected[run[bad]]["group"] if run[bad] < len(expected) else -1,
                    expected[run[bad]]["object"] if run[bad] < len(expected) else -1)
        else:
            detail = "ends at group %d object %d, before the manifest's last object" % (
                expected[known[-1]]["group"], expected[known[-1]]["object"])
    else:
        detail = "no fragment matches the manifest"
    results.append(("ordering", order_ok, detail))

    if args.decode:
        if not shutil.which("ffprobe"):
            print("Bail out! ffprobe not found")
            return 2
        # Complete groups only: the first received group may start part-way.
        complete: List[int] = []
        if order_ok:
            first = known[0]
            start = first if expected[first]["object"] == 0 else next(
                (i for i in range(first, len(expected)) if expected[i]["object"] == 0), len(expected))
            complete = list(range(start, len(expected)))
        want = sum(expected[i]["samples"] for i in complete)
        if complete:
            with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as tmp:
                tmp.write(data[init_off:init_off + init_len])
                for i in complete:
                    pos = received.index(i)
                    off, size = fragments[pos]
                    tmp.write(data[off:off + size])
                tmp_path = tmp.name
            try:
                frames, errors = ffprobe_frames(tmp_path, track_role(track))
            finally:
                os.unlink(tmp_path)
        else:
            frames, errors = None, "no complete group"
        decode_ok = bool(complete) and not errors and frames == want
        diag["complete_groups"] = len({expected[i]["group"] for i in complete})
        diag["decoded_frames"] = frames if frames is not None else "none"
        diag["expected_frames"] = want
        if decode_ok:
            detail = "%d frames from %d complete groups" % (frames, diag["complete_groups"])
        elif errors:
            detail = "ffprobe: %s" % errors.splitlines()[0]
        else:
            detail = "%s frames decoded, %d expected" % (frames, want)
        results.append(("decode", decode_ok, detail))

    return tap(results, diag)


def track_role(track: Dict[str, object]) -> str:
    return "video" if str(track["codec"]).startswith(("avc1", "hvc1", "hev1", "av01", "vp09")) else "audio"


def cmd_verify_catalog(args: argparse.Namespace) -> int:
    with open(args.expected) as f:
        expected = json.load(f)
    try:
        with open(args.received, "rb") as f:
            received = json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError) as err:
        return tap([("catalog", False, "received catalog does not parse: %s" % err)], {})
    path = first_difference(expected, received)
    ok = path is None
    return tap([("catalog", ok, "equal to the expected catalog" if ok else "differs at %s" % path)],
               {"first_difference": path} if path else {})


def first_difference(a: object, b: object, path: str = "$") -> Optional[str]:
    """JSON path of the first difference between two parsed documents, or None."""
    if type(a) is not type(b):
        return path
    if isinstance(a, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                return "%s.%s" % (path, key)
            sub = first_difference(a[key], b[key], "%s.%s" % (path, key))
            if sub:
                return sub
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return "%s.length" % path
        for i, (x, y) in enumerate(zip(a, b)):
            sub = first_difference(x, y, "%s[%d]" % (path, i))
            if sub:
                return sub
        return None
    return None if a == b else path


# ----------------------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    build = sub.add_parser("build", help="write manifest.json and catalog.json for a fixture")
    build.add_argument("--fixture-dir", required=True)
    build.add_argument("--duration-ms", type=int, default=None)
    build.add_argument("--generator", default=None, help="the encoder's version string")
    build.set_defaults(func=cmd_build)

    verify = sub.add_parser("verify", help="check a reassembled track file against the manifest")
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--track", required=True, choices=TRACKS)
    verify.add_argument("--file", required=True)
    verify.add_argument("--decode", action="store_true", help="also run the ffprobe decode check")
    verify.set_defaults(func=cmd_verify)

    catalog = sub.add_parser("verify-catalog", help="check a received catalog against the expected one")
    catalog.add_argument("--expected", required=True)
    catalog.add_argument("--received", required=True)
    catalog.set_defaults(func=cmd_verify_catalog)

    args = parser.parse_args()
    try:
        return args.func(args)
    except (OSError, ValueError, KeyError) as err:
        print("Bail out! %s" % err)
        return 2


if __name__ == "__main__":
    sys.exit(main())

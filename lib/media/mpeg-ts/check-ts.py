#!/usr/bin/env python3
"""check-ts.py - the reference oracle for the MPEG-TS media tests (docs/tests/media/mpeg-ts.md).

Applies the media area's checks to the transport stream a subscriber reassembled, against the
fixture the publisher sent, using the received bytes, the fixture, TSDuck and ffprobe. No player
is involved.

  check-ts.py --fixture fixture.ts --received received.ts [--objects objects.txt] [--late-join]
              [--catalog-expected published.json --catalog-received received.json]

received.ts is the subscriber's object payloads, any packaging header removed, concatenated in
(group, object) order. objects.txt lists the received objects in arrival order, one per line as
`<group> <object> <bytes>`, where <bytes> is what the object added to received.ts; the ordering
check needs it and is skipped without it. Where the packaging has a catalog track, the catalog
object the publisher sent and the one received are given as files and must be equal; without
them the catalog check is skipped, since MPEG-TS has no description track of its own.

Without --late-join the received stream must be the whole fixture from its first random access
point or earlier (ts-carriage-integrity). With it, the stream may begin anywhere, including
part-way through a group, and must run without a break to the fixture's end
(ts-late-subscriber). Null packets (PID 0x1FFF) are stuffing that a packaging may drop, so both
sides are compared without them, and a null packet that is delivered must be one of the
fixture's. Decoding starts at the first random access point received.

Output is TAP version 14, one test point per check in the order the notes list them, then
diagnostics as `# key: value` comments that a test client can lift into its YAML block. Packet
numbers are indices into the received file or the fixture file. Exit 0 when every check passes
or is skipped, 1 when any fails, 2 on a usage or environment error.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

PACKET = 188
SYNC = 0x47
NULL_PID = 0x1FFF
PAT_PID = 0x0000
VIDEO_TYPES = {0x01, 0x02, 0x1B, 0x24}


def pid_of(pkt):
    return ((pkt[1] & 0x1F) << 8) | pkt[2]


def pusi(pkt):
    return bool(pkt[1] & 0x40)


def tei(pkt):
    return bool(pkt[1] & 0x80)


def cc_of(pkt):
    return pkt[3] & 0x0F


def random_access(pkt):
    """The adaptation field's random_access_indicator, which marks a random access point."""
    has_af = pkt[3] & 0x20
    return bool(has_af and pkt[4] > 0 and pkt[5] & 0x40)


def payload(pkt):
    """The packet's payload bytes, after any adaptation field."""
    control = (pkt[3] >> 4) & 0x3
    if not control & 0x1:
        return b""
    start = 4 + (1 + pkt[4] if control & 0x2 else 0)
    return pkt[start:] if start < PACKET else b""


def packets(data):
    return [data[i:i + PACKET] for i in range(0, len(data) - len(data) % PACKET, PACKET)]


def section(pkt):
    """The PSI section that starts in this packet, or None."""
    if not pusi(pkt):
        return None
    body = payload(pkt)
    if not body:
        return None
    start = 1 + body[0]
    if start + 3 > len(body):
        return None
    length = ((body[start + 1] & 0x0F) << 8) | body[start + 2]
    return body[start:start + 3 + length]


def pmt_pids(pkts):
    pids = set()
    for pkt in pkts:
        if pid_of(pkt) != PAT_PID:
            continue
        sec = section(pkt)
        if not sec or sec[0] != 0x00:
            continue
        for i in range(8, len(sec) - 4, 4):
            program = (sec[i] << 8) | sec[i + 1]
            if program != 0:
                pids.add(((sec[i + 2] & 0x1F) << 8) | sec[i + 3])
    return pids


def video_pids(pkts, pmts):
    """Elementary PIDs whose PMT stream_type is a video type the fixture uses."""
    pids = set()
    for pkt in pkts:
        if pid_of(pkt) not in pmts:
            continue
        sec = section(pkt)
        if not sec or sec[0] != 0x02:
            continue
        info = ((sec[10] & 0x0F) << 8) | sec[11]
        i = 12 + info
        while i + 5 <= len(sec) - 4:
            stream_type = sec[i]
            elementary = ((sec[i + 1] & 0x1F) << 8) | sec[i + 2]
            es_info = ((sec[i + 3] & 0x0F) << 8) | sec[i + 4]
            if stream_type in VIDEO_TYPES:
                pids.add(elementary)
            i += 5 + es_info
    return pids


def random_access_points(pkts, vpids):
    """Indices of the packets that start a video frame at a random access point."""
    return [i for i, p in enumerate(pkts) if pid_of(p) in vpids and pusi(p) and random_access(p)]


def psi_set(pkts, pids):
    """Distinct PAT and PMT sections, which a faithful carriage leaves unchanged."""
    return {bytes(sec) for pkt in pkts if pid_of(pkt) in pids for sec in [section(pkt)] if sec}


def align(fx, rx):
    """The fixture index the received packets most plausibly start at, or None.

    PSI packets repeat byte for byte once their continuity counter wraps, so a first packet that
    occurs more than once is placed where a tail of the received length would start, if it fits."""
    hits = [i for i, p in enumerate(fx) if p == rx[0]] if rx else []
    if len(hits) > 1 and len(fx) - len(rx) in hits:
        return len(fx) - len(rx)
    return hits[0] if hits else None


def describe(pkt):
    return f"PID 0x{pid_of(pkt):04X} CC {cc_of(pkt)}"


def read_objects(path):
    """The object log as [(group, object, bytes)] in arrival order."""
    objects = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            fields = line.split("#", 1)[0].split()
            if not fields:
                continue
            if len(fields) != 3 or not all(x.isdigit() for x in fields):
                raise ValueError(f"{path}:{n}: expected '<group> <object> <bytes>'")
            objects.append(tuple(int(x) for x in fields))
    return objects


def check_ordering(objects, total):
    """The area's ordering rule over objects in arrival order: groups open with increasing Group
    ID, each group's objects arrive contiguous and in order (only the first group received may
    start part-way), no group between the first and last is missing and none is repeated.
    Objects of adjacent groups may interleave in time; no others may."""
    if not objects:
        return False, "no object received"
    seen = set()
    opened = []
    due = {}
    for group, obj, _ in objects:
        if (group, obj) in seen:
            return False, f"group {group} object {obj} received twice"
        seen.add((group, obj))
        if group not in due:
            if opened and group < opened[-1]:
                return False, f"group {group} opened after group {opened[-1]}"
            if opened and obj != 0:
                return False, f"group {group} starts at object {obj}"
            opened.append(group)
        elif obj != due[group]:
            return False, f"group {group} object {obj} arrived where object {due[group]} was due"
        elif group < opened[-1] - 1:
            return False, f"group {group} object {obj} arrived after group {opened[-1]} opened"
        due[group] = obj + 1
    gap = next((a for a, b in zip(opened, opened[1:]) if b > a + 1), None)
    if gap is not None:
        return False, f"group {gap + 1} missing between groups {opened[0]} and {opened[-1]}"
    logged = sum(size for _, _, size in objects)
    if logged != total:
        return False, f"the object log accounts for {logged} bytes, the received stream holds {total}"
    return True, f"{len(objects)} objects in groups {opened[0]}-{opened[-1]}, in order"


def misplaced_null(rx_all, fx_all, start):
    """The first received packet that breaks "the fixture from packet `start`, with only null
    packets removed", or None. Called once the non-null packets are known to match, so it finds a
    null packet the fixture does not have at that place."""
    j = start
    for i, p in enumerate(rx_all):
        while j < len(fx_all) and fx_all[j] != p and pid_of(fx_all[j]) == NULL_PID:
            j += 1
        if j == len(fx_all) or fx_all[j] != p:
            return i
        j += 1
    return None


def check_group_starts(objects, rx_all, vpids, psi_pids, late_join):
    """The packaging rule over the object log: each group starts at a random access point, or at
    PSI immediately before one. A late join's first group is exempt when it arrives part-way."""
    starts, first_object, pos = {}, {}, 0
    for group, obj, size in sorted({(g, o): (g, o, n) for g, o, n in objects}.values()):
        if group not in starts:
            starts[group], first_object[group] = pos, obj
        pos += size
    groups = sorted(starts)
    if late_join and first_object[groups[0]] > 0:
        groups = groups[1:]
    for group in groups:
        if starts[group] % PACKET:
            return False, f"group {group} starts at byte {starts[group]}, not on a packet boundary"
        i = first = starts[group] // PACKET
        while i < len(rx_all) and pid_of(rx_all[i]) in psi_pids:
            i += 1
        if i == len(rx_all) or not (pid_of(rx_all[i]) in vpids and pusi(rx_all[i])
                                    and random_access(rx_all[i])):
            return False, (f"group {group} starts at received packet {first}, not at a random "
                           f"access point or PSI before one")
    return True, f"{len(groups)} groups, each at a random access point"


def locate(objects, offset):
    """The (group, object) holding byte `offset` of the stream reassembled in (group, object) order."""
    pos = 0
    for group, obj, size in sorted(objects):
        if offset < pos + size:
            return group, obj
        pos += size
    return None


def probe(pkts):
    """({codec_type: decoded frames}, ffprobe's error output) for a run of packets."""
    with tempfile.NamedTemporaryFile(suffix=".ts", delete=False) as tmp:
        tmp.write(b"".join(pkts))
        path = tmp.name
    try:
        run = subprocess.run(
            ["ffprobe", "-v", "error", "-count_frames", "-show_entries",
             "stream=codec_type,nb_read_frames", "-of", "csv=p=0", path],
            capture_output=True, text=True, check=False)
    finally:
        os.unlink(path)
    frames = {}
    for line in run.stdout.splitlines():
        kind, _, count = line.strip().strip(",").partition(",")
        if count.isdigit():
            frames.setdefault(kind, int(count))
    return frames, run.stderr.strip()


def frame_list(frames):
    return ", ".join(f"{kind} {frames[kind]}" for kind in sorted(frames, reverse=True)) or "none"


def tsduck_continuity(path):
    """Lines TSDuck's continuity plugin reports; empty means every PID advanced by one."""
    run = subprocess.run(["tsp", "-I", "file", path, "-P", "continuity", "-O", "drop"],
                         capture_output=True, text=True, check=False)
    lines = [l for l in (run.stdout + run.stderr).splitlines() if l.strip()]
    return run.returncode, lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--received", required=True)
    parser.add_argument("--objects", help="the received objects in arrival order")
    parser.add_argument("--late-join", action="store_true",
                        help="accept a stream that begins part-way (ts-late-subscriber)")
    parser.add_argument("--catalog-expected",
                        help="the catalog object the publisher sent, where its packaging has one")
    parser.add_argument("--catalog-received", help="the catalog object as received")
    args = parser.parse_args()
    if (args.catalog_expected is None) != (args.catalog_received is None):
        print("Bail out! --catalog-expected and --catalog-received go together")
        return 2

    for tool in ("tsp", "ffprobe"):
        if not shutil.which(tool):
            print(f"Bail out! {tool} not found")
            return 2
    try:
        with open(args.fixture, "rb") as f:
            fixture_bytes = f.read()
        with open(args.received, "rb") as f:
            received_bytes = f.read()
        objects = read_objects(args.objects) if args.objects else None
        catalogs = None
        if args.catalog_expected is not None:
            with open(args.catalog_expected, "rb") as f:
                expected_catalog = f.read()
            with open(args.catalog_received, "rb") as f:
                catalogs = (expected_catalog, f.read())
    except (OSError, ValueError) as err:
        print(f"Bail out! {err}")
        return 2

    results = []
    diag = {"media_format": "mpeg-ts"}

    def check(name, ok, detail):
        results.append((name, ok, detail))

    rx_all = packets(received_bytes)
    fx_all = packets(fixture_bytes)
    rx_pos = [i for i, p in enumerate(rx_all) if p[0] == SYNC and pid_of(p) != NULL_PID]
    fx_pos = [i for i, p in enumerate(fx_all) if pid_of(p) != NULL_PID]
    rx = [rx_all[i] for i in rx_pos]
    fx = [fx_all[i] for i in fx_pos]
    pmts = pmt_pids(fx)
    vpids = video_pids(fx, pmts)
    fx_raps = random_access_points(fx, vpids)
    rx_raps = random_access_points(rx, vpids)
    diag["ts_packets_received"] = len(rx_all)
    diag["ts_null_packets_received"] = sum(1 for p in rx_all if p[0] == SYNC and pid_of(p) == NULL_PID)

    if catalogs is None:
        check("catalog", None, "MPEG-TS has no description track of its own")
    elif catalogs[0] == catalogs[1]:
        check("catalog", True, f"equal to the published catalog, {len(catalogs[0])} bytes")
    else:
        check("catalog", False, f"the received catalog ({len(catalogs[1])} bytes) differs from "
              f"the published one ({len(catalogs[0])} bytes)")

    # byte-identical: the received non-null packets are a tail of the fixture's, running to its end,
    # and any null packet delivered is one of the fixture's (dropping them is allowed, altering not).
    k = len(fx) - len(rx)
    tail = bool(rx) and k >= 0 and fx[k:] == rx
    if tail:
        diag["ts_tail_start_packet"] = fx_pos[k] if k < len(fx_pos) else len(fx_all)
    bad_null = misplaced_null(rx_all, fx_all, fx_pos[k - 1] + 1 if k > 0 else 0) if tail else None
    if args.late_join:
        placed = tail and any(r >= k for r in fx_raps)
    else:
        placed = tail and bool(fx_raps) and k <= fx_raps[0]
    whole = placed and bad_null is None
    if whole:
        detail = f"the fixture's last {len(rx)} non-null packets, from packet {fx_pos[k]}"
    elif not rx:
        detail = "nothing received"
    elif placed:
        detail = f"received packet {bad_null} is not where the fixture has it (only null packets may be removed)"
        diag["first_mismatch"] = json.dumps({"packet": bad_null, "got": describe(rx_all[bad_null])})
    elif tail and args.late_join:
        detail = "no random access point received"
    elif tail:
        detail = f"starts at fixture packet {fx_pos[k]}, after its first random access point ({fx_pos[fx_raps[0]]})"
    else:
        start = align(fx, rx)
        if start is None:
            detail = "the first packet received is not in the fixture"
            bad = 0
        else:
            overlap = min(len(rx), len(fx) - start)
            bad = next((i for i in range(overlap) if rx[i] != fx[start + i]), None)
            if bad is None and len(rx) < len(fx) - start:
                detail = f"ends at fixture packet {fx_pos[start + len(rx) - 1]}, before the fixture's end"
                bad = len(rx)
            elif bad is None:
                detail = f"{len(rx) - overlap} packets received beyond the fixture's end"
                bad = overlap
            else:
                detail = f"received packet {rx_pos[bad]} differs from fixture packet {fx_pos[start + bad]}"
        mismatch = {"packet": rx_pos[bad] if bad < len(rx_pos) else len(rx_all)}
        if objects and bad < len(rx_pos):
            where = locate(objects, rx_pos[bad] * PACKET)
            if where:
                mismatch["group"], mismatch["object"] = where
        if start is not None and start + bad < len(fx):
            mismatch["expected"] = describe(fx[start + bad])
        if bad < len(rx):
            mismatch["got"] = describe(rx[bad])
        diag["first_mismatch"] = json.dumps(mismatch)
    check("byte-identical", whole, detail)

    if objects is None:
        check("ordering", None, "no object log given")
    else:
        ok, detail = check_ordering(objects, len(received_bytes))
        check("ordering", ok, detail)
        if objects:
            groups = sorted({group for group, _, _ in objects})
            diag["groups_received"] = len(groups)
            diag["objects_received"] = len(objects)
            diag["bytes_received"] = sum(size for _, _, size in objects)
            diag["first_group"] = groups[0]
            diag["last_group"] = groups[-1]
            diag["ts_first_object"] = min(obj for group, obj, _ in objects if group == groups[0])

    # decode: from the first random access point received, as a decoder would start.
    if not rx_raps:
        check("decode", False, "no random access point received")
    else:
        r = rx_raps[0]
        f = k + r if tail else (fx.index(rx[r]) if rx[r] in fx else None)
        if f is None:
            check("decode", False, "the first random access point received is not the fixture's")
        else:
            got, errors = probe(rx[r:])
            want, fixture_errors = probe(fx[f:])
            diag["ts_decode_start_packet"] = rx_pos[r]
            diag["ts_decoded_frames"] = frame_list(got)
            diag["ts_expected_frames"] = frame_list(want)
            if fixture_errors:
                check("decode", False, f"the fixture does not decode from packet {fx_pos[f]}: "
                      f"{fixture_errors.splitlines()[0]}")
            elif errors:
                check("decode", False, f"ffprobe: {errors.splitlines()[0]}")
            else:
                check("decode", bool(got) and got == want,
                      f"{frame_list(got)} frames from packet {rx_pos[r]}, "
                      f"{'as' if got == want else 'not as'} the fixture predicts")

    aligned = bool(received_bytes) and len(received_bytes) % PACKET == 0 and all(p[0] == SYNC for p in rx_all)
    split = next(((g, o) for g, o, size in objects or [] if size % PACKET), None)
    check("packet-alignment", aligned and split is None,
          "nothing received" if not received_bytes else
          "not whole 188-byte packets with sync bytes" if not aligned else
          f"group {split[0]} object {split[1]} is not whole 188-byte packets" if split else
          f"{len(rx_all)} packets")

    errors = sum(1 for p in rx_all if p[0] == SYNC and tei(p))
    check("transport-errors", bool(rx_all) and errors == 0,
          f"{errors} packets with transport_error_indicator set" if rx_all else "nothing received")

    rc, cc = tsduck_continuity(args.received)
    check("continuity", bool(rx_all) and rc == 0 and not cc,
          f"{len(cc)} TSDuck continuity reports" if rx_all else "nothing received")
    if cc:
        diag["ts_continuity_first"] = cc[0]

    psi_pids = pmts | {PAT_PID}
    psi_ok = bool(pmts) and psi_set(rx, psi_pids) == psi_set(fx, psi_pids)
    check("psi-unchanged", psi_ok,
          f"PAT and {len(pmts)} PMT(s) as in the fixture" if psi_ok else
          "the PAT and PMT sections received differ from the fixture's")

    if objects is None:
        check("group-starts", None, "no object log given")
    elif not objects:
        check("group-starts", False, "no object received")
    else:
        check("group-starts", *check_group_starts(objects, rx_all, vpids, psi_pids, args.late_join))

    failed = [(name, detail) for name, ok, detail in results if ok is False]
    if failed:
        diag["message"] = f"{failed[0][0]}: {failed[0][1]}"

    print("TAP version 14")
    print(f"1..{len(results)}")
    for n, (name, ok, detail) in enumerate(results, 1):
        if ok is None:
            print(f"ok {n} - {name} # SKIP {detail}")
        else:
            print(f"{'ok' if ok else 'not ok'} {n} - {name} ({detail})")
    for key, value in diag.items():
        print(f"# {key}: {value}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

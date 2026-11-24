#!/usr/bin/env python3
"""check-ts.py - the reference oracle for the MPEG-TS media tests (docs/tests/media/mpeg-ts.md).

Applies the media area's checks to the transport stream a subscriber reassembled, against the
fixture the publisher sent, using the received bytes, the fixture, TSDuck and ffprobe. No player
is involved.

  check-ts.py --fixture fixture.ts --received received.ts [--objects objects.txt] [--late-join]
              [--expect-step | --programs N | --restart-at SECONDS]
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
(ts-late-subscriber). With --expect-step the fixture's clock steps at the packet its manifest
(the fixture's name with .json for .ts) records: continuity expects the fixture's own breaks
there, and decode reads each side of the step alone (ts-clock-step). With --programs N the PAT
must list N programmes, and decode reads each programme alone (ts-multi-program). With
--restart-at the stream may have one gap, after a part that ends by that many seconds into the
fixture and before a part that starts at a random access point and runs to the end; ordering
holds within each part, and continuity and decode are not judged (ts-publisher-restart).
Null packets (PID 0x1FFF) are stuffing that a packaging may drop, so both
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


def programs(pkts):
    """{program_number: PMT PID} from the first PAT section."""
    for pkt in pkts:
        if pid_of(pkt) != PAT_PID:
            continue
        sec = section(pkt)
        if not sec or sec[0] != 0x00:
            continue
        found = {}
        for i in range(8, len(sec) - 4, 4):
            program = (sec[i] << 8) | sec[i + 1]
            if program != 0:
                found[program] = ((sec[i + 2] & 0x1F) << 8) | sec[i + 3]
        return found
    return {}


def program_pids(pkts, pmt):
    """The PIDs a decoder reads for one programme: the PAT, its PMT, its PCR and its streams."""
    for pkt in pkts:
        if pid_of(pkt) != pmt:
            continue
        sec = section(pkt)
        if not sec or sec[0] != 0x02:
            continue
        pids = {PAT_PID, pmt, ((sec[8] & 0x1F) << 8) | sec[9]}
        i = 12 + (((sec[10] & 0x0F) << 8) | sec[11])
        while i + 5 <= len(sec) - 4:
            pids.add(((sec[i + 1] & 0x1F) << 8) | sec[i + 2])
            i += 5 + (((sec[i + 3] & 0x0F) << 8) | sec[i + 4])
        return pids
    return {PAT_PID, pmt}


def pcr_of(pkt):
    """The packet's PCR in 27 MHz ticks, or None."""
    if not (pkt[3] & 0x20 and pkt[4] >= 7 and pkt[5] & 0x10):
        return None
    base = (pkt[6] << 25) | (pkt[7] << 17) | (pkt[8] << 9) | (pkt[9] << 1) | (pkt[10] >> 7)
    return base * 300 + (((pkt[10] & 1) << 8) | pkt[11])


def packet_seconds(pkts):
    """Seconds per packet at the stream's mux rate, from its first PCR PID's clock up to any
    step."""
    pcrs = [(i, v) for i, p in enumerate(pkts) for v in [pcr_of(p)] if v is not None]
    if not pcrs:
        return None
    clock = pid_of(pkts[pcrs[0][0]])
    pcrs = [(i, v) for i, v in pcrs if pid_of(pkts[i]) == clock]
    run = [pcrs[0]]
    for i, v in pcrs[1:]:
        if not 0 < v - run[-1][1] < 27_000_000:
            break
        run.append((i, v))
    if len(run) < 2:
        return None
    return (run[-1][1] - run[0][1]) / 27_000_000 / (run[-1][0] - run[0][0])


def cc_breaks(pkts):
    """{PID: continuity breaks}, a repeated packet allowed once, PIDs without payload ignored."""
    last, breaks = {}, {}
    for pkt in pkts:
        q = pid_of(pkt)
        if q == NULL_PID or not (pkt[3] >> 4) & 0x1:
            continue
        if q in last:
            prev, prev_pkt = last[q]
            if cc_of(pkt) == prev and pkt == prev_pkt:
                continue
            if cc_of(pkt) != (prev + 1) & 0x0F:
                breaks[q] = breaks.get(q, 0) + 1
        last[q] = (cc_of(pkt), pkt)
    return breaks


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


def pid_list(counts):
    return ", ".join(f"0x{q:04X}" for q in sorted(counts))


def restart_parts(fx, rx, fx_pos, rx_all, fx_all, rx_pos, fx_raps, vpids, psi_pids, restart_at):
    """byte-identical across a restart: (ok, detail, (a, end1, c)), where the received non-null
    packets are the fixture's [a, end1) then [c, end). The first part starts at or before the
    fixture's first random access point and ends by `restart_at` seconds into the fixture; the
    second starts at a random access point, or PSI before one, and runs to the end."""
    if not rx:
        return False, "nothing received", None
    if not fx_raps:
        return False, "the fixture has no random access point", None
    a = align(fx, rx)
    if a is None:
        return False, "the first packet received is not in the fixture", None
    if a > fx_raps[0]:
        return False, (f"starts at fixture packet {fx_pos[a]}, after its first random access "
                       f"point ({fx_pos[fx_raps[0]]})"), None
    run = 0
    while run < len(rx) and a + run < len(fx) and rx[run] == fx[a + run]:
        run += 1
    end1 = a + run
    if run == len(rx):
        if end1 == len(fx):
            return True, f"the fixture's last {len(rx)} non-null packets, with no gap", (a, end1, end1)
        return False, (f"ends at fixture packet {fx_pos[end1 - 1]}, with no second part to the "
                       f"fixture's end"), None
    per = packet_seconds(fx_all)
    if per and fx_pos[end1 - 1] * per > restart_at:
        return False, (f"the first part runs to fixture packet {fx_pos[end1 - 1]}, past "
                       f"{restart_at:g} s, before received packet {rx_pos[run]} breaks it"), None
    rest = rx[run:]
    c = len(fx) - len(rest)
    if c < end1 or fx[c:] != rest:
        bad = 0 if c < end1 else next(i for i in range(len(rest)) if rest[i] != fx[c + i])
        return False, (f"received packet {rx_pos[run + bad]} is in neither the first part nor an "
                       f"unbroken run to the fixture's end"), None
    i = c
    while i < len(fx) and pid_of(fx[i]) in psi_pids:
        i += 1
    if i == len(fx) or not (pid_of(fx[i]) in vpids and pusi(fx[i]) and random_access(fx[i])):
        return False, (f"the second part starts at fixture packet {fx_pos[c]}, not at a random "
                       f"access point or PSI before one"), None
    split = rx_pos[run]
    bad_null = misplaced_null(rx_all[:split], fx_all, fx_pos[a - 1] + 1 if a > 0 else 0)
    if bad_null is None:
        later = misplaced_null(rx_all[split:], fx_all, fx_pos[c - 1] + 1)
        bad_null = None if later is None else split + later
    if bad_null is not None:
        return False, (f"received packet {bad_null} is not where the fixture has it (only null "
                       f"packets may be removed)"), None
    return True, (f"fixture packets {fx_pos[a]}-{fx_pos[end1 - 1]}, then from {fx_pos[c]} to the "
                  f"end"), (a, end1, c)


def check_ordering_parts(objects, total, second):
    """The ordering rule within each part of a restarted stream: the objects that arrived before
    the first of the second part's first group, `second` = (group, object), and those from it."""
    if second is None:
        return check_ordering(objects, total)
    logged = sum(size for _, _, size in objects)
    if logged != total:
        return False, f"the object log accounts for {logged} bytes, the received stream holds {total}"
    cut = next((i for i, (g, _, _) in enumerate(objects) if g >= second[0]), len(objects))
    details = []
    for name, part in (("first", objects[:cut]), ("second", objects[cut:])):
        ok, detail = check_ordering(part, sum(size for _, _, size in part))
        if not ok:
            return False, f"{name} part: {detail}"
        details.append(detail)
    return True, f"{details[0]}; then {details[1]}"


def without_final_pes(pkts, psi_pids):
    """The packets less each elementary stream's last PES, which a cut may have left short."""
    last = {}
    for i, p in enumerate(pkts):
        if pusi(p) and pid_of(p) not in psi_pids:
            last[pid_of(p)] = i
    return [p for i, p in enumerate(pkts) if i < last.get(pid_of(p), len(pkts))]


def compare_decode(got_pkts, want_pkts, what):
    """(ok, detail, frames) for one decoded span against the fixture's same span."""
    got, errors = probe(got_pkts)
    want, fixture_errors = probe(want_pkts)
    if fixture_errors:
        return False, f"the fixture does not decode {what}: {fixture_errors.splitlines()[0]}", got
    if errors:
        return False, f"ffprobe {what}: {errors.splitlines()[0]}", got
    if not got or got != want:
        return False, f"{frame_list(got)} frames {what}, the fixture predicts {frame_list(want)}", got
    return True, f"{frame_list(got)} {what}", got


def decode_whole(fx, rx, fx_pos, rx_pos, r, f, diag):
    got, errors = probe(rx[r:])
    want, fixture_errors = probe(fx[f:])
    diag["ts_decoded_frames"] = frame_list(got)
    diag["ts_expected_frames"] = frame_list(want)
    if fixture_errors:
        return False, f"the fixture does not decode from packet {fx_pos[f]}: {fixture_errors.splitlines()[0]}"
    if errors:
        return False, f"ffprobe: {errors.splitlines()[0]}"
    return (bool(got) and got == want,
            f"{frame_list(got)} frames from packet {rx_pos[r]}, "
            f"{'as' if got == want else 'not as'} the fixture predicts")


def decode_step(fx, rx, fx_pos, rx_pos, vpids, r, f, manifest, diag):
    """Decode each side of the clock step alone: from the first random access point received to
    the step, and from the second encode's first random access point to the end."""
    is_rap = lambda p: pid_of(p) in vpids and pusi(p) and random_access(p)
    fx_step = next((i for i, p in enumerate(fx_pos) if p >= manifest["step_packet"]), len(fx))
    diag["ts_step_packet"] = manifest["step_packet"]
    if f >= fx_step:
        return False, "no random access point received before the step"
    rx_step = r + (fx_step - f)
    if not (rx_step < len(rx) and rx[rx_step] == fx[fx_step] and rx[rx_step - 1] == fx[fx_step - 1]):
        rx_step = next((i for i in range(r, len(rx)) if rx[i] == fx[fx_step]), None)
        if rx_step is None:
            return False, "the step's first packet was not received"
    diag["ts_step_received"] = rx_pos[rx_step]
    fx_key = next((i for i in range(fx_step, len(fx)) if is_rap(fx[i])), None)
    rx_key = next((i for i in range(rx_step, len(rx)) if is_rap(rx[i])), None)
    if fx_key is None or rx_key is None:
        return False, "no random access point after the step"
    # The splice cuts the first encode's last PES of each stream short; both sides stop before.
    psi_pids = pmt_pids(fx) | {PAT_PID}
    spans = []
    for name, got_pkts, want_pkts in (("before", without_final_pes(rx[r:rx_step], psi_pids),
                                       without_final_pes(fx[f:fx_step], psi_pids)),
                                      ("after", rx[rx_key:], fx[fx_key:])):
        ok, detail, got = compare_decode(got_pkts, want_pkts, f"{name} the step")
        diag[f"ts_decoded_frames_{name}_step"] = frame_list(got)
        if not ok:
            return False, detail
        spans.append(detail)
    return True, f"{'; '.join(spans)}, as the fixture predicts"


def decode_programs(fx, rx, rx_pos, r, f, diag):
    """Decode each programme alone, from its first random access point received, to the end
    less each stream's last PES, which the fixture's cut may have left short."""
    found = programs(fx)
    if not found:
        return False, "the fixture's PAT lists no programme"
    psi_pids = set(found.values()) | {PAT_PID}
    frames, spans, failed = {}, [], None
    for number, pmt in sorted(found.items()):
        pids = program_pids(fx, pmt)
        own = video_pids(fx, {pmt})
        start = next((i for i in range(r, len(rx)) if pid_of(rx[i]) in own and pusi(rx[i])
                      and random_access(rx[i])), None)
        if start is None:
            frames[str(number)] = "none"
            failed = failed or f"no random access point received in programme {number}"
            continue
        got_pkts = [p for p in rx[start:] if pid_of(p) in pids]
        want_pkts = [p for p in fx[f + start - r:] if pid_of(p) in pids]
        ok, detail, got = compare_decode(without_final_pes(got_pkts, psi_pids),
                                         without_final_pes(want_pkts, psi_pids),
                                         f"in programme {number}")
        frames[str(number)] = frame_list(got)
        spans.append(detail)
        if not ok and failed is None:
            failed = detail
    diag["ts_decoded_frames"] = json.dumps(frames)
    if failed:
        return False, failed
    return True, f"{'; '.join(spans)}, from packet {rx_pos[r]}, as the fixture predicts"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--received", required=True)
    parser.add_argument("--objects", help="the received objects in arrival order")
    parser.add_argument("--late-join", action="store_true",
                        help="accept a stream that begins part-way (ts-late-subscriber)")
    parser.add_argument("--expect-step", action="store_true",
                        help="the fixture's clock steps where its manifest says (ts-clock-step)")
    parser.add_argument("--programs", type=int,
                        help="the number of programmes the PAT lists (ts-multi-program)")
    parser.add_argument("--restart-at", type=float, metavar="SECONDS",
                        help="allow one gap after this point in the fixture (ts-publisher-restart)")
    parser.add_argument("--catalog-expected",
                        help="the catalog object the publisher sent, where its packaging has one")
    parser.add_argument("--catalog-received", help="the catalog object as received")
    args = parser.parse_args()
    if (args.catalog_expected is None) != (args.catalog_received is None):
        print("Bail out! --catalog-expected and --catalog-received go together")
        return 2
    modes = [args.late_join, args.expect_step, args.programs is not None, args.restart_at is not None]
    if sum(modes) > 1:
        print("Bail out! --late-join, --expect-step, --programs and --restart-at are exclusive")
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
        manifest = None
        if args.expect_step:
            with open(os.path.splitext(args.fixture)[0] + ".json") as f:
                manifest = json.load(f)
            manifest["step_packet"] = int(manifest["step_packet"])
        catalogs = None
        if args.catalog_expected is not None:
            with open(args.catalog_expected, "rb") as f:
                expected_catalog = f.read()
            with open(args.catalog_received, "rb") as f:
                catalogs = (expected_catalog, f.read())
    except (OSError, ValueError, KeyError) as err:
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

    psi_pids = pmts | {PAT_PID}
    parts = None
    if args.restart_at is not None:
        ok, detail, parts = restart_parts(fx, rx, fx_pos, rx_all, fx_all, rx_pos, fx_raps, vpids,
                                          psi_pids, args.restart_at)
        if parts and parts[2] > parts[1]:
            per = packet_seconds(fx_all) or 0
            last, resumed = fx_pos[parts[1] - 1], fx_pos[parts[2]]
            diag["ts_restart_gap"] = json.dumps({"from": last, "to": resumed,
                                                 "seconds": round((resumed - last) * per, 3)})
        check("byte-identical", ok, detail)

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
    if args.restart_at is not None:
        pass
    elif whole:
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
    if args.restart_at is None:
        check("byte-identical", whole, detail)

    if objects is None:
        check("ordering", None, "no object log given")
    else:
        if parts and parts[1] < len(rx):
            ok, detail = check_ordering_parts(objects, len(received_bytes),
                                              locate(objects, rx_pos[parts[1] - parts[0]] * PACKET))
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
    if args.restart_at is not None:
        check("decode", None, "not judged across a restart; byte-identical compares each part")
    elif not rx_raps:
        check("decode", False, "no random access point received")
    else:
        r = rx_raps[0]
        f = k + r if tail else (fx.index(rx[r]) if rx[r] in fx else None)
        if f is None:
            check("decode", False, "the first random access point received is not the fixture's")
        else:
            diag["ts_decode_start_packet"] = rx_pos[r]
            if manifest is not None:
                check("decode", *decode_step(fx, rx, fx_pos, rx_pos, vpids, r, f, manifest, diag))
            elif args.programs is not None:
                check("decode", *decode_programs(fx, rx, rx_pos, r, f, diag))
            else:
                check("decode", *decode_whole(fx, rx, fx_pos, rx_pos, r, f, diag))

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

    if args.restart_at is not None:
        check("continuity", None, "the restart's gap breaks it; byte-identical compares each part")
    elif manifest is not None:
        got = cc_breaks(rx_all)
        want = cc_breaks(fx_all[fx_pos[k]:] if tail and k < len(fx_pos) else fx_all)
        extra = {q: n for q, n in got.items() if n > want.get(q, 0)}
        missing = {q: n for q, n in want.items() if got.get(q, 0) < n}
        check("continuity", bool(rx_all) and not extra and not missing,
              "nothing received" if not rx_all else
              f"breaks the fixture does not have on PID(s) {pid_list(extra)}" if extra else
              f"the step's breaks missing on PID(s) {pid_list(missing)}" if missing else
              f"breaks only where the fixture does, on {len(want)} PIDs at the step")
    else:
        rc, cc = tsduck_continuity(args.received)
        check("continuity", bool(rx_all) and rc == 0 and not cc,
              f"{len(cc)} TSDuck continuity reports" if rx_all else "nothing received")
        if cc:
            diag["ts_continuity_first"] = cc[0]

    psi_ok = bool(pmts) and psi_set(rx, psi_pids) == psi_set(fx, psi_pids)
    psi_detail = (f"PAT and {len(pmts)} PMT(s) as in the fixture" if psi_ok else
                  "the PAT and PMT sections received differ from the fixture's")
    if args.programs is not None:
        found = sorted(programs(rx))
        diag["ts_programs"] = ",".join(str(n) for n in found)
        if psi_ok and len(found) != args.programs:
            psi_ok, psi_detail = False, f"the PAT lists {len(found)} programmes, not {args.programs}"
    check("psi-unchanged", psi_ok, psi_detail)

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

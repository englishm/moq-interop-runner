#!/usr/bin/env python3
"""splice-step.py - splice two encodes of the area's fixture into the ts-clock-step fixture.

  splice-step.py <first.ts> <second.ts> <out.ts> <manifest.json> --cut SECONDS --key SECONDS

The two inputs are the same programme muxed alike on clocks thousands of seconds apart, the
second's GOPs out of phase with the first's. The output is the first up to the packet whose PCR
is SECONDS into its encode, then the second from a packet just before the video frame that comes
--key seconds before one of its random access points, so the second encode joins mid-GOP. Every
PID breaks its continuity counter once at the splice, the PAT, PMT and SDT are byte-identical on
both sides, and no packet sets discontinuity_indicator: the switch a contribution makes between
two encoders whose clocks are not locked. The manifest records where the splice is.
"""

import argparse
import json
import sys

PACKET = 188
WRAP = 1 << 33
PSI = (0x0000, 0x0011)


def pid(p):
    return (p[1] & 0x1F) << 8 | p[2]


def pusi(p):
    return bool(p[1] & 0x40)


def payload_at(p):
    control = (p[3] >> 4) & 3
    if not control & 1:
        return None
    off = 5 + p[4] if control & 2 else 4
    return off if off < PACKET else None


def af_flags(p):
    return p[5] if (p[3] & 0x20) and p[4] else 0


def pcr(p):
    if not af_flags(p) & 0x10 or p[4] < 7:
        return None
    return p[6] << 25 | p[7] << 17 | p[8] << 9 | p[9] << 1 | p[10] >> 7


def stamp(p):
    """The decode time of the PES that starts in this packet (its DTS, else its PTS)."""
    off = payload_at(p)
    if off is None or not pusi(p) or p[off:off + 3] != b"\0\0\1" or not p[off + 7] & 0x80:
        return None
    b = p[off + 14:off + 19] if p[off + 7] & 0x40 else p[off + 9:off + 14]
    return ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1


def read(path):
    data = open(path, "rb").read()
    return [bytearray(data[i:i + PACKET]) for i in range(0, len(data) - PACKET + 1, PACKET)]


def program(pkts):
    """The PMT PID, the PCR PID and the video PID of the PAT's only programme."""
    for p in pkts:
        if pid(p) == 0 and pusi(p):
            s = p[payload_at(p) + 1 + p[payload_at(p)]:]
            pmt = (s[10] & 0x1F) << 8 | s[11]
            break
    for p in pkts:
        if pid(p) == pmt and pusi(p):
            s = p[payload_at(p) + 1 + p[payload_at(p)]:]
            clock = (s[8] & 0x1F) << 8 | s[9]
            i = 12 + ((s[10] & 0x0F) << 8 | s[11])
            end = 3 + ((s[1] & 0x0F) << 8 | s[2]) - 4
            while i < end:
                if s[i] in (0x01, 0x02, 0x1B, 0x24):
                    return pmt, clock, (s[i + 1] & 0x1F) << 8 | s[i + 2]
                i += 5 + ((s[i + 3] & 0x0F) << 8 | s[i + 4])
    sys.exit("splice-step: no video stream in the PMT")


def seconds(pkts, clock):
    """Each PCR packet's index and its time in seconds from the encode's first PCR."""
    times = [(k, pcr(p)) for k, p in enumerate(pkts) if pid(p) == clock and pcr(p) is not None]
    first = times[0][1]
    return [(k, ((v - first) % WRAP) / 90000) for k, v in times]


def step(a, b):
    """b - a in seconds, the shorter way round the 33-bit clock."""
    return ((b - a + WRAP // 2) % WRAP - WRAP // 2) / 90000


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("first")
    parser.add_argument("second")
    parser.add_argument("out")
    parser.add_argument("manifest")
    parser.add_argument("--cut", type=float, required=True)
    parser.add_argument("--key", type=float, required=True)
    args = parser.parse_args()

    a, b = read(args.first), read(args.second)
    pmt, clock, video = program(a)
    if program(b) != (pmt, clock, video):
        sys.exit("splice-step: the two encodes' programmes differ")

    i = next((k for k, t in seconds(a, clock) if t >= args.cut), None)
    if i is None:
        sys.exit("splice-step: the first encode is shorter than the cut")

    # The second encode joins on a frame --key before one of its random access points, at a
    # packet inside the frame before that, so its first frames are the tail of a GOP.
    starts = [k for k, p in enumerate(b) if pid(p) == video and pusi(p) and stamp(p) is not None]
    at = dict(seconds(b, clock))
    clock_at = 0.0
    j = None
    for n in range(2, len(starts)):
        k = starts[n]
        clock_at = next((at[x] for x in range(k, -1, -1) if x in at), clock_at)
        if clock_at < args.cut or not af_flags(b[k]) & 0x40:
            continue
        lead = next((m for m in range(n - 1, 0, -1)
                     if abs((stamp(b[k]) - stamp(b[starts[m]])) / 90000 - args.key) < 0.005), None)
        if lead is None or af_flags(b[starts[lead]]) & 0x40:
            continue
        j = (starts[lead - 1] + starts[lead]) // 2
        break
    if j is None:
        sys.exit("splice-step: no random access point in the second encode fits the splice")

    # Every PID breaks its continuity counter once, as at a real switch.
    last = {}
    for p in a[:i]:
        if payload_at(p) is not None:
            last[pid(p)] = p[3] & 0x0F
    for q in sorted(last):
        if q == 0x1FFF:
            continue
        first = next((p for p in b[j:] if pid(p) == q and payload_at(p) is not None), None)
        if first is None:
            continue
        cc = first[3] & 0x0F
        if cc in (last[q], (last[q] + 1) & 0x0F):
            bump = (last[q] + 9 - cc) & 0x0F
            for p in b[j:]:
                if pid(p) == q:
                    p[3] = (p[3] & 0xF0) | ((p[3] + bump) & 0x0F)

    spliced = a[:i] + b[j:]
    if any(af_flags(p) & 0x80 for p in spliced):
        sys.exit("splice-step: a packet sets discontinuity_indicator")
    for q in PSI + (pmt,):
        before = next(p for p in reversed(a[:i]) if pid(p) == q and pusi(p))
        after = next(p for p in b[j:] if pid(p) == q and pusi(p))
        if before[4:] != after[4:]:
            sys.exit(f"splice-step: PID 0x{q:04X}'s table differs either side of the splice")

    key = next(k for k in range(i, len(spliced))
               if pid(spliced[k]) == video and pusi(spliced[k]) and af_flags(spliced[k]) & 0x40)
    last_pcr = next(pcr(p) for p in reversed(a[:i]) if pid(p) == clock and pcr(p) is not None)
    next_pcr = next(pcr(p) for p in b[j:] if pid(p) == clock and pcr(p) is not None)
    manifest = {
        "fixture": args.out.rsplit("/", 1)[-1],
        "step_packet": i,
        "step_seconds": round(step(last_pcr, next_pcr), 3),
        "random_access_packet": key,
        "random_access_after_seconds": args.key,
    }
    with open(args.out, "wb") as f:
        f.write(b"".join(spliced))
    with open(args.manifest, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"splice-step: {len(spliced)} packets, the clock steps {manifest['step_seconds']:+.3f} s "
          f"at packet {i}, a random access point at packet {key}")


if __name__ == "__main__":
    main()

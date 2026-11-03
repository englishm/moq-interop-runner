#!/usr/bin/env python3
"""check-ts.py - the oracle for the MPEG-TS media tests (docs/tests/media/mpeg-ts.md).

Compares the transport stream a subscriber reassembled against the fixture the publisher sent,
using the received bytes, the fixture and TSDuck. No decoder or player is involved.

  check-ts.py --fixture fixture.ts --received received.ts [--suffix]

Without --suffix the received stream must be the whole fixture (ts-carriage-integrity). With
--suffix it must be a tail of the fixture that a decoder can start on (ts-late-subscriber).
Null packets (PID 0x1FFF) are stuffing that a packaging may drop, so both sides are compared
without them.

Output is TAP version 14, one test point per check, then diagnostics as `# key: value` comments
that a test client can lift into its YAML block. Exit 0 when every check passes, 1 when any
fails, 2 on a usage or environment error.
"""

import argparse
import shutil
import subprocess
import sys

PACKET = 188
SYNC = 0x47
NULL_PID = 0x1FFF
PAT_PID = 0x0000


def pid_of(pkt):
    return ((pkt[1] & 0x1F) << 8) | pkt[2]


def pusi(pkt):
    return bool(pkt[1] & 0x40)


def tei(pkt):
    return bool(pkt[1] & 0x80)


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
    video_types = {0x01, 0x02, 0x1B, 0x24}
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
            if stream_type in video_types:
                pids.add(elementary)
            i += 5 + es_info
    return pids


def psi_set(pkts, pids):
    """Distinct PAT and PMT sections, which a faithful carriage leaves unchanged."""
    return {bytes(sec) for pkt in pkts if pid_of(pkt) in pids for sec in [section(pkt)] if sec}


def find_suffix(fixture, received):
    """Index k such that fixture[k:] == received, or None."""
    if not received:
        return None
    first = received[0]
    for k, pkt in enumerate(fixture):
        if pkt == first and len(fixture) - k == len(received) and fixture[k:] == received:
            return k
    return None


def first_mismatch(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return None if len(a) == len(b) else min(len(a), len(b))


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
    parser.add_argument("--suffix", action="store_true",
                        help="accept a decodable tail of the fixture (late subscriber)")
    args = parser.parse_args()

    if not shutil.which("tsp"):
        print("Bail out! tsp (TSDuck) not found")
        return 2
    try:
        with open(args.fixture, "rb") as f:
            fixture_bytes = f.read()
        with open(args.received, "rb") as f:
            received_bytes = f.read()
    except OSError as err:
        print(f"Bail out! {err}")
        return 2

    results = []
    diag = {"received_bytes": len(received_bytes), "fixture_bytes": len(fixture_bytes),
            "mode": "suffix" if args.suffix else "whole"}

    def check(name, ok, detail):
        results.append((name, ok, detail))

    rx_all = packets(received_bytes)
    fx_all = packets(fixture_bytes)
    check("received-nonempty", len(received_bytes) > 0, f"{len(received_bytes)} bytes")

    aligned = len(received_bytes) % PACKET == 0 and all(p[0] == SYNC for p in rx_all)
    check("packet-alignment", aligned and bool(rx_all),
          f"{len(rx_all)} packets" if aligned else "not whole 188-byte packets with sync bytes")

    errors = sum(1 for p in rx_all if p[0] == SYNC and tei(p))
    check("transport-errors", errors == 0, f"{errors} packets with transport_error_indicator set")

    rc, cc = tsduck_continuity(args.received)
    check("continuity", rc == 0 and not cc, f"{len(cc)} TSDuck continuity reports")
    if cc:
        diag["continuity_first"] = cc[0]

    rx = [p for p in rx_all if p[0] == SYNC and pid_of(p) != NULL_PID]
    fx = [p for p in fx_all if pid_of(p) != NULL_PID]
    diag["received_null_packets"] = len(rx_all) - len(rx)
    diag["fixture_null_packets"] = len(fx_all) - len(fx)

    pmts = pmt_pids(fx)
    psi_pids = pmts | {PAT_PID}
    check("psi-unchanged", bool(pmts) and psi_set(rx, psi_pids) == psi_set(fx, psi_pids),
          f"PAT and {len(pmts)} PMT(s) as in the fixture")

    vpids = video_pids(fx, pmts)
    first_rap = next((i for i, p in enumerate(fx)
                      if pid_of(p) in vpids and pusi(p) and random_access(p)), None)
    k = find_suffix(fx, rx)
    if k is not None:
        diag["suffix_start_packet"] = k
    elif rx and rx[0] in fx:
        start = fx.index(rx[0])
        diag["aligned_at_packet"] = start
        diag["first_mismatch_packet"] = first_mismatch(rx, fx[start:])

    if not args.suffix:
        # A packaging can only place bytes in a group once one starts, so packets before the
        # fixture's first random access point may be missing.
        whole = k is not None and first_rap is not None and k <= first_rap
        check("byte-identical", whole,
              f"the fixture's non-null packets from packet {k}, at or before its first random "
              f"access point ({first_rap})" if whole else
              f"not the fixture from its first random access point ({len(rx)} vs {len(fx)} "
              "non-null packets)")
    else:
        check("byte-identical-suffix", k is not None,
              f"the fixture's last {len(rx)} non-null packets, from packet {k}" if k is not None
              else "not a contiguous tail of the fixture")
        # Continuation packets of a frame begun before the join are discarded by any decoder, so
        # only the first frame that starts in the stream must be a random access point.
        first_frame = next((p for p in rx if pid_of(p) in vpids and pusi(p)), None)
        starts_ok = first_frame is not None and random_access(first_frame)
        check("starts-at-random-access", starts_ok,
              "the first video frame received is a random access point" if starts_ok else
              "the first video frame received is not a random access point")

    print("TAP version 14")
    print(f"1..{len(results)}")
    for n, (name, ok, detail) in enumerate(results, 1):
        print(f"{'ok' if ok else 'not ok'} {n} - {name} ({detail})")
    for key, value in diag.items():
        print(f"# {key}: {value}")
    return 0 if all(ok for _, ok, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main())

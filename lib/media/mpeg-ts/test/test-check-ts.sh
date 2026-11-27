#!/bin/bash
# lib/media/mpeg-ts/test/test-check-ts.sh - sensitivity tests for the MPEG-TS oracle
#
# Run with: bash lib/media/mpeg-ts/test/test-check-ts.sh
# Outputs TAP. Needs ffmpeg, ffprobe, TSDuck (tsp) and python3; skips when any is missing.
#
# An oracle that never fails is worthless, so each mutation below is one the checker must catch,
# and each permitted variation is one it must accept.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../check-ts.py"

for tool in ffmpeg ffprobe tsp python3; do
    if ! command -v "$tool" >/dev/null; then
        echo "1..0 # SKIP $tool not found"
        exit 0
    fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

DURATION=6 bash "$SCRIPT_DIR/../make-fixture.sh" "$WORK/fixture.ts" >/dev/null
DURATION=8 STEP_AT=4 bash "$SCRIPT_DIR/../make-fixture.sh" --step "$WORK/fixture-step.ts" >/dev/null
DURATION=6 bash "$SCRIPT_DIR/../make-fixture.sh" --mpts "$WORK/fixture-mpts.ts" >/dev/null
FX="$WORK/fixture.ts"

# mutate <name> <python expression over pk, the packets of the fixture $FX; raps, the indices of
# its video random access points; step, the step fixture's splice; and pid(p), flip(p, at) and
# frame(i), the packets of the video frame that starts at index i>
mutate() {
    python3 - "$FX" "$WORK/$1.ts" "$2" <<'EOF'
import json, sys
src, dst, expr = sys.argv[1:]
step = json.load(open(src[:-3] + ".json"))["step_packet"] if src.endswith("-step.ts") else None
data = open(src, "rb").read()
pk = [data[i:i + 188] for i in range(0, len(data), 188)]
pid = lambda p: ((p[1] & 0x1F) << 8) | p[2]
starts = [i for i, p in enumerate(pk) if pid(p) == 0x100 and p[1] & 0x40]
raps = [i for i in starts if pk[i][3] & 0x20 and pk[i][4] > 0 and pk[i][5] & 0x40]
def flip(p, at):
    return p[:at] + bytes([p[at] ^ 0xFF]) + p[at + 1:]
def frame(i):
    end = next(j for j in starts if j > i)
    return {j for j in range(i, end) if pid(pk[j]) == 0x100}
out = eval(expr)
open(dst, "wb").write(b"".join(out))
EOF
}

# package <name> <python expression over objs, the fixture packaged into [(group, object,
# packets)] in arrival order, and late, the objects from halfway through group 2> writes
# <name>.ts (payloads in (group, object) order) and <name>.objects (the arrival log). The
# simulated packaging drops null packets, opens a group at each video random access point and
# cuts objects of up to 64 packets; packets before the first random access point are not placed.
package() {
    python3 - "$FX" "$WORK/$1" "$2" <<'EOF'
import sys
src, dst, expr = sys.argv[1:]
data = open(src, "rb").read()
pk = [data[i:i + 188] for i in range(0, len(data), 188)]
pid = lambda p: ((p[1] & 0x1F) << 8) | p[2]
nn = [p for p in pk if pid(p) != 0x1FFF]
groups = []
for p in nn:
    if pid(p) == 0x100 and p[1] & 0x40 and p[3] & 0x20 and p[4] > 0 and p[5] & 0x40:
        groups.append([])
    if groups:
        groups[-1].append(p)
objs = [(g, o, grp[i:i + 64]) for g, grp in enumerate(groups) for o, i in enumerate(range(0, len(grp), 64))]
mid = len(groups[2]) // 2 // 64
late = [x for x in objs if (x[0], x[1]) >= (2, mid)]
def swap(lst, a, b):
    lst = list(lst)
    lst[a], lst[b] = lst[b], lst[a]
    return lst
def at(g, o):
    return next(i for i, x in enumerate(objs) if x[:2] == (g, o))
def move(lst, a, b):
    lst = list(lst)
    lst.insert(b, lst.pop(a))
    return lst
def restarted(before, after, skip=0):
    """Groups below `before`, then from group `after` on, less the first `skip` objects of it."""
    return [x for x in objs if x[0] < before] + [x for x in objs if x[0] >= after][skip:]
def regroup(g):
    """Move the last object of group g - 1 to the head of group g, renumbering group g."""
    prev = [x for x in objs if x[0] == g - 1]
    head = [(g, o, p) for o, (_, _, p) in enumerate(prev[-1:] + [x for x in objs if x[0] == g])]
    return [x for x in objs if x[0] < g - 1] + prev[:-1] + head + [x for x in objs if x[0] > g]
out = eval(expr)
with open(dst + ".ts", "wb") as f:
    for g, o, packets in sorted({(g, o): (g, o, p) for g, o, p in out}.values(), key=lambda x: x[:2]):
        f.write(b"".join(packets))
with open(dst + ".objects", "w") as f:
    for g, o, packets in out:
        f.write(f"{g} {o} {188 * len(packets)}\n")
EOF
}

TESTS=0
FAILURES=0

# expect <description> <pass|fail> <check that must decide it, or -> <checker arguments...>
expect() {
    local desc="$1" want="$2" decider="$3"
    shift 3
    local out rc=0
    out=$(python3 "$CHECK" --fixture "$FX" "$@") || rc=$?
    TESTS=$((TESTS + 1))
    local got=pass
    [ "$rc" -eq 0 ] || got=fail
    [ "$rc" -le 1 ] || got=error
    local decided=1
    if [ "$decider" != - ] && ! echo "$out" | grep -q "^not ok [0-9]* - $decider "; then
        decided=0
    fi
    if [ "$got" = "$want" ] && [ "$decided" = 1 ]; then
        echo "ok $TESTS - $desc"
    else
        echo "not ok $TESTS - $desc"
        echo "# ${out//$'\n'/$'\n'# }"
        FAILURES=$((FAILURES + 1))
    fi
}

# expect_ok <description> <check that must pass> <checker arguments...>
expect_ok() {
    local desc="$1" check="$2"
    shift 2
    local out
    out=$(python3 "$CHECK" --fixture "$FX" "$@") || true
    TESTS=$((TESTS + 1))
    if echo "$out" | grep -q "^ok [0-9]* - $check "; then
        echo "ok $TESTS - $desc"
    else
        echo "not ok $TESTS - $desc"
        echo "# ${out//$'\n'/$'\n'# }"
        FAILURES=$((FAILURES + 1))
    fi
}

mutate identity 'pk'
mutate dropped '[p for i, p in enumerate(pk) if not 3000 <= i < 3500]'
mutate duplicated 'pk[:3000] + pk[3000:3020] + pk[3000:]'
mutate transposed 'pk[:3000] + pk[3010:3020] + pk[3000:3010] + pk[3020:]'
mutate flipped '[flip(p, 100) if i == next(j for j in range(3000, len(pk)) if pid(pk[j]) == 0x100) else p for i, p in enumerate(pk)]'
mutate null-changed '[flip(p, 100) if i == next(j for j in range(3000, len(pk)) if pid(pk[j]) == 0x1FFF) else p for i, p in enumerate(pk)]'
mutate truncated 'pk[:-200]'
mutate tei '[bytes([p[0], p[1] | 0x80]) + p[2:] if i == 3000 else p for i, p in enumerate(pk)]'
mutate pmt-changed '[flip(p, 10) if pid(p) == 0x1000 and p[1] & 0x40 else p for p in pk]'
mutate frame-lost '[p for i, p in enumerate(pk) if i not in frame(next(j for j in range(raps[2] + 1, len(pk)) if pid(pk[j]) == 0x100 and pk[j][1] & 0x40))]'
mutate unaligned '[b"".join(pk)[10:]]'
mutate null-moved '(lambda j: pk[:j] + [pk[j + 1], pk[j]] + pk[j + 2:])(next(j for j in range(3000, len(pk) - 1) if pid(pk[j]) == 0x1FFF and pid(pk[j + 1]) != 0x1FFF))'

package whole 'objs'
package late 'late'
package late-at-group 'late[late.index(next(x for x in late if x[:2] == (3, 0))):]'
package skipped-group '[x for x in late if x[0] != 3]'
package swapped-objects 'swap(objs, at(1, 1), at(1, 2))'
package group-opened-early 'swap(objs, at(2, 0), at(3, 0))'
package interleaved 'swap(objs, at(2, len([x for x in objs if x[0] == 2]) - 1), at(3, 0))'
package repeated 'objs + [objs[at(1, 1)]]'
package group-part-way '[x for x in objs if x[:2] != (3, 0)]'
package far-group 'objs[:-1] + [(2 ** 40, 0, objs[-1][2])]'
package nonadjacent 'move(objs, at(1, len([x for x in objs if x[0] == 1]) - 1), at(3, 0))'
package off-rap 'regroup(3)'
package late-off-rap '[x for x in regroup(3) if x[0] >= 3]'
# One packet cut across two objects of a group: the stream and the logged total are unchanged.
cp "$WORK/whole.ts" "$WORK/split.ts"
awk '$1 == 1 && $2 == 0 { $3 -= 1 } $1 == 1 && $2 == 1 { $3 += 1 } 1' \
    "$WORK/whole.objects" >"$WORK/split.objects"

printf '{"m2ts":{"track":"0.m2ts","randomAccess":true}}' >"$WORK/catalog.json"
printf '{"m2ts":{"track":"0.m2ts","randomAccess":false}}' >"$WORK/catalog-changed.json"

expect "the fixture itself passes" pass - --received "$WORK/identity.ts"
expect "the fixture packaged from its first random access point passes, nulls dropped" pass - \
    --received "$WORK/whole.ts" --objects "$WORK/whole.objects"
expect "500 dropped packets fail continuity" fail continuity --received "$WORK/dropped.ts"
expect "a duplicated 20-packet run fails continuity" fail continuity --received "$WORK/duplicated.ts"
expect "two transposed blocks fail continuity" fail continuity --received "$WORK/transposed.ts"
expect_ok "continuity alone misses one corrupted payload byte" continuity --received "$WORK/flipped.ts"
expect "one corrupted payload byte fails byte identity" fail byte-identical --received "$WORK/flipped.ts"
expect "a changed null packet fails byte identity" fail byte-identical --received "$WORK/null-changed.ts"
expect "a null packet moved past its neighbour fails byte identity" fail byte-identical --received "$WORK/null-moved.ts"
expect "a truncated stream fails byte identity" fail byte-identical --received "$WORK/truncated.ts"
expect "a transport error indicator fails transport-errors" fail transport-errors --received "$WORK/tei.ts"
expect "a changed PMT fails psi-unchanged" fail psi-unchanged --received "$WORK/pmt-changed.ts"
expect "a lost video frame fails decode" fail decode --received "$WORK/frame-lost.ts"
expect "a stream not cut on packet boundaries fails packet-alignment" fail packet-alignment \
    --received "$WORK/unaligned.ts"
expect "an object that is not whole packets fails packet-alignment" fail packet-alignment \
    --received "$WORK/split.ts" --objects "$WORK/split.objects"
expect "a late join is not the whole stream" fail byte-identical \
    --received "$WORK/late.ts" --objects "$WORK/late.objects"
expect "a late join part-way through a group passes, decoding from the next group" pass - \
    --received "$WORK/late.ts" --objects "$WORK/late.objects" --late-join
expect "a late join at a group boundary passes" pass - \
    --received "$WORK/late-at-group.ts" --objects "$WORK/late-at-group.objects" --late-join
expect "a late join that skips a group fails ordering" fail ordering \
    --received "$WORK/skipped-group.ts" --objects "$WORK/skipped-group.objects" --late-join
expect_ok "byte identity alone misses objects that arrive out of order" byte-identical \
    --received "$WORK/swapped-objects.ts" --objects "$WORK/swapped-objects.objects"
expect "objects out of order within a group fail ordering" fail ordering \
    --received "$WORK/swapped-objects.ts" --objects "$WORK/swapped-objects.objects"
expect "a group opened before the one ahead of it fails ordering" fail ordering \
    --received "$WORK/group-opened-early.ts" --objects "$WORK/group-opened-early.objects"
expect "adjacent groups interleaving in time is a permitted variation" pass - \
    --received "$WORK/interleaved.ts" --objects "$WORK/interleaved.objects"
expect "an object received twice fails ordering" fail ordering \
    --received "$WORK/repeated.ts" --objects "$WORK/repeated.objects"
expect "a group after the first that starts part-way fails ordering" fail ordering \
    --received "$WORK/group-part-way.ts" --objects "$WORK/group-part-way.objects"
expect "a Group ID far past the last fails ordering without enumerating the gap" fail ordering \
    --received "$WORK/far-group.ts" --objects "$WORK/far-group.objects"
expect "an object arriving once a group two later has opened fails ordering" fail ordering \
    --received "$WORK/nonadjacent.ts" --objects "$WORK/nonadjacent.objects"
expect "a group that starts between random access points fails group-starts" fail group-starts \
    --received "$WORK/off-rap.ts" --objects "$WORK/off-rap.objects"
expect_ok "a group that starts between random access points still passes ordering" ordering \
    --received "$WORK/off-rap.ts" --objects "$WORK/off-rap.objects"
expect "a late join's first group, whole but between random access points, fails group-starts" \
    fail group-starts --late-join \
    --received "$WORK/late-off-rap.ts" --objects "$WORK/late-off-rap.objects"
expect_ok "a catalog received as published passes the catalog check" catalog \
    --received "$WORK/identity.ts" \
    --catalog-expected "$WORK/catalog.json" --catalog-received "$WORK/catalog.json"
expect "a catalog changed in transit fails the catalog check" fail catalog \
    --received "$WORK/identity.ts" \
    --catalog-expected "$WORK/catalog.json" --catalog-received "$WORK/catalog-changed.json"

# ts-publisher-restart: one gap, after a part that ends by --restart-at and before a part that
# starts at a random access point. Groups open at each 1 s random access point, so groups 0-1
# end by 2.5 s.
package restart 'restarted(2, 3)'
package restart-late 'restarted(4, 5)'
package restart-off-rap 'restarted(2, 3, skip=1)'
package restart-twice '[x for x in restarted(2, 3) if x[0] != 4]'
package restart-no-second '[x for x in objs if x[0] < 2]'
package restart-swapped '(lambda r: swap(r, r.index(next(x for x in r if x[:2] == (3, 1))), r.index(next(x for x in r if x[:2] == (3, 2)))))(restarted(2, 3))'
expect "a restart with one gap at a random access point passes" pass - \
    --received "$WORK/restart.ts" --objects "$WORK/restart.objects" --restart-at 2.5
expect "a restart is not the whole stream without --restart-at" fail byte-identical \
    --received "$WORK/restart.ts" --objects "$WORK/restart.objects"
expect "a first part that runs past the restart point fails byte identity" fail byte-identical \
    --received "$WORK/restart-late.ts" --objects "$WORK/restart-late.objects" --restart-at 2.5
expect "a second part that starts between random access points fails byte identity" fail byte-identical \
    --received "$WORK/restart-off-rap.ts" --objects "$WORK/restart-off-rap.objects" --restart-at 2.5
expect "a second gap fails byte identity" fail byte-identical \
    --received "$WORK/restart-twice.ts" --objects "$WORK/restart-twice.objects" --restart-at 2.5
expect "no second part fails byte identity" fail byte-identical \
    --received "$WORK/restart-no-second.ts" --objects "$WORK/restart-no-second.objects" --restart-at 2.5
expect "objects out of order within the second part fail ordering" fail ordering \
    --received "$WORK/restart-swapped.ts" --objects "$WORK/restart-swapped.objects" --restart-at 2.5

# ts-clock-step: the fixture breaks every continuity counter once at the splice, and decodes
# on each side of it.
FX="$WORK/fixture-step.ts"
mutate step-identity 'pk'
mutate step-ends 'pk[:step]'
mutate step-dropped '[p for i, p in enumerate(pk) if not step + 3000 <= i < step + 3500]'
mutate step-repaired '(lambda last: pk[:step] + [bytes([p[0], p[1], p[2], (p[3] & 0xF0) | (last.__setitem__(pid(p), (last[pid(p)] + 1) & 15) or last[pid(p)])]) + p[4:] if pid(p) in last and p[3] & 0x10 else p for p in pk[step:]])({pid(p): p[3] & 15 for p in pk[:step] if pid(p) != 0x1FFF and p[3] & 0x10})'
mutate step-frame-lost '[p for i, p in enumerate(pk) if i not in frame(next(j for j in range(raps[-2] + 1, len(pk)) if pid(pk[j]) == 0x100 and pk[j][1] & 0x40))]'
expect "the step fixture itself passes with --expect-step" pass - --received "$WORK/step-identity.ts" --expect-step
expect "the step fixture's own breaks fail continuity without --expect-step" fail continuity \
    --received "$WORK/step-identity.ts"
expect "a stream that ends at the splice fails byte identity" fail byte-identical \
    --received "$WORK/step-ends.ts" --expect-step
expect "500 packets dropped after the splice fail continuity" fail continuity \
    --received "$WORK/step-dropped.ts" --expect-step
expect "continuity counters renumbered across the splice fail continuity" fail continuity \
    --received "$WORK/step-repaired.ts" --expect-step
expect "a lost video frame after the splice fails decode" fail decode \
    --received "$WORK/step-frame-lost.ts" --expect-step

# ts-multi-program: the PAT lists three programmes, each decodes alone.
FX="$WORK/fixture-mpts.ts"
mutate mpts-identity 'pk'
mutate mpts-first-only '[p for p in pk if not 0x200 <= pid(p) < 0x400]'
mutate mpts-pmt3-changed '[flip(p, 10) if pid(p) == 0x300 and p[1] & 0x40 else p for p in pk]'
mutate mpts-p3-frame-lost '(lambda s: [p for i, p in enumerate(pk) if not (pid(p) == 0x311 and s[2] <= i < s[3])])([i for i, p in enumerate(pk) if pid(p) == 0x311 and p[1] & 0x40][len(pk) // 4000:])'
expect "the three-programme fixture itself passes with --programs 3" pass - \
    --received "$WORK/mpts-identity.ts" --programs 3
expect "a stream carrying only the first programme fails psi-unchanged" fail psi-unchanged \
    --received "$WORK/mpts-first-only.ts" --programs 3
expect "a stream carrying only the first programme fails byte identity" fail byte-identical \
    --received "$WORK/mpts-first-only.ts" --programs 3
expect "a changed PMT of the third programme fails psi-unchanged" fail psi-unchanged \
    --received "$WORK/mpts-pmt3-changed.ts" --programs 3
expect "a lost frame in the third programme fails decode" fail decode \
    --received "$WORK/mpts-p3-frame-lost.ts" --programs 3
expect "a PAT listing three programmes fails --programs 2" fail psi-unchanged \
    --received "$WORK/mpts-identity.ts" --programs 2

echo "1..$TESTS"
if [ "$FAILURES" -gt 0 ]; then
    echo "# $FAILURES of $TESTS tests failed"
    exit 1
fi

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

# mutate <name> <python expression over pk, the fixture's packets; raps, the indices of its
# video random access points; and pid(p), flip(p, at) and frame(i), the packets of the video
# frame that starts at index i>
mutate() {
    python3 - "$WORK/fixture.ts" "$WORK/$1.ts" "$2" <<'EOF'
import sys
src, dst, expr = sys.argv[1:]
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
    python3 - "$WORK/fixture.ts" "$WORK/$1" "$2" <<'EOF'
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
    out=$(python3 "$CHECK" --fixture "$WORK/fixture.ts" "$@") || rc=$?
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
    out=$(python3 "$CHECK" --fixture "$WORK/fixture.ts" "$@") || true
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

echo "1..$TESTS"
if [ "$FAILURES" -gt 0 ]; then
    echo "# $FAILURES of $TESTS tests failed"
    exit 1
fi

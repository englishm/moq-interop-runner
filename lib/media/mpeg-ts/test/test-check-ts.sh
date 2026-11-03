#!/bin/bash
# lib/media/mpeg-ts/test/test-check-ts.sh - sensitivity tests for the MPEG-TS oracle
#
# Run with: bash lib/media/mpeg-ts/test/test-check-ts.sh
# Outputs TAP. Needs ffmpeg, TSDuck (tsp) and python3; skips when any is missing.
#
# An oracle that never fails is worthless, so each mutation below is one the checker must catch,
# and each permitted variation is one it must accept.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../check-ts.py"

for tool in ffmpeg tsp python3; do
    if ! command -v "$tool" >/dev/null; then
        echo "1..0 # SKIP $tool not found"
        exit 0
    fi
done

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

DURATION=6 bash "$SCRIPT_DIR/../make-fixture.sh" "$TMPDIR/fixture.ts" >/dev/null

# mutate <name> <python expression over pk, the fixture's packets, and raps, the indices of its
# video random access points (each preceded by the muxer's PAT and PMT)>
mutate() {
    python3 - "$TMPDIR/fixture.ts" "$TMPDIR/$1.ts" "$2" <<'EOF'
import sys
src, dst, expr = sys.argv[1:]
data = open(src, "rb").read()
pk = [data[i:i + 188] for i in range(0, len(data), 188)]
pid = lambda p: ((p[1] & 0x1F) << 8) | p[2]
raps = [i for i, p in enumerate(pk)
        if pid(p) == 0x100 and p[1] & 0x40 and p[3] & 0x20 and p[4] > 0 and p[5] & 0x40]
def flip(p, at):
    return p[:at] + bytes([p[at] ^ 0xFF]) + p[at + 1:]
out = eval(expr)
open(dst, "wb").write(b"".join(out))
EOF
}

TESTS=0
FAILURES=0

# expect <description> <pass|fail> <check that must decide it, or -> <checker arguments...>
expect() {
    local desc="$1" want="$2" decider="$3"
    shift 3
    local out rc=0
    out=$(python3 "$CHECK" --fixture "$TMPDIR/fixture.ts" "$@") || rc=$?
    TESTS=$((TESTS + 1))
    local got=pass
    [ "$rc" -eq 0 ] || got=fail
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
    out=$(python3 "$CHECK" --fixture "$TMPDIR/fixture.ts" "$@") || true
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
mutate no-nulls '[p for p in pk if pid(p) != 0x1FFF]'
mutate from-first-rap 'pk[raps[0]:]'
mutate dropped '[p for i, p in enumerate(pk) if not 3000 <= i < 3500]'
mutate duplicated 'pk[:3000] + pk[3000:3020] + pk[3000:]'
mutate transposed 'pk[:3000] + pk[3010:3020] + pk[3000:3010] + pk[3020:]'
mutate flipped '[flip(p, 100) if i == next(j for j in range(3000, len(pk)) if pid(pk[j]) == 0x100) else p for i, p in enumerate(pk)]'
mutate truncated 'pk[:-200]'
mutate late-at-rap 'pk[raps[2]:]'
mutate late-at-psi 'pk[raps[2] - 12:]'
mutate late-mid-group 'pk[raps[2] + 300:]'

expect "the fixture itself passes" pass - --received "$TMPDIR/identity.ts"
expect "dropped null packets are a permitted variation" pass - --received "$TMPDIR/no-nulls.ts"
expect "a stream from the first random access point passes" pass - --received "$TMPDIR/from-first-rap.ts"
expect "500 dropped packets fail continuity" fail continuity --received "$TMPDIR/dropped.ts"
expect "a duplicated 20-packet run fails continuity" fail continuity --received "$TMPDIR/duplicated.ts"
expect "two transposed blocks fail continuity" fail continuity --received "$TMPDIR/transposed.ts"
expect_ok "continuity alone misses one corrupted payload byte" continuity --received "$TMPDIR/flipped.ts"
expect "one corrupted payload byte fails byte identity" fail byte-identical --received "$TMPDIR/flipped.ts"
expect "a truncated stream fails byte identity" fail byte-identical --received "$TMPDIR/truncated.ts"
expect "a late join at a random access point passes" pass - --received "$TMPDIR/late-at-rap.ts" --suffix
expect "a late join at the PSI before it passes" pass - --received "$TMPDIR/late-at-psi.ts" --suffix
expect "a late join mid-group fails" fail starts-at-random-access --received "$TMPDIR/late-mid-group.ts" --suffix
expect "a late join is not the whole stream" fail byte-identical --received "$TMPDIR/late-at-rap.ts"

echo "1..$TESTS"
if [ "$FAILURES" -gt 0 ]; then
    echo "# $FAILURES of $TESTS tests failed"
    exit 1
fi

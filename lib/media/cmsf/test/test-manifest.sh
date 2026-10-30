#!/bin/bash
# lib/media/cmsf/test/test-manifest.sh - sensitivity tests for the CMSF oracle
#
# Run with: bash lib/media/cmsf/test/test-manifest.sh
# Outputs TAP. Needs ffmpeg, ffprobe and python3; skips when any is missing.
#
# An oracle that never fails is worthless, so each mutation below is one the checker must
# catch, and each permitted variation is one it must accept.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_PY="$SCRIPT_DIR/../manifest.py"

for tool in ffmpeg ffprobe python3; do
    if ! command -v "$tool" >/dev/null; then
        echo "1..0 # SKIP $tool not found"
        exit 0
    fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

DURATION=4 bash "$SCRIPT_DIR/../make-fixture.sh" "$WORK/fixture" >/dev/null

# mutate <track> <name> <python expression over init (bytes), frags (list of fragment bytes)
# and objs (the manifest's objects in order, each with group/object/offset/bytes)>
mutate() {
    python3 - "$WORK/fixture" "$1" "$WORK/$2.mp4" "$3" <<'PY'
import json, sys
fixture, track, dst, expr = sys.argv[1:]
manifest = json.load(open(fixture + "/manifest.json"))["tracks"][track]
data = open(fixture + "/" + track + ".mp4", "rb").read()
init = data[:manifest["init"]["bytes"]]
objs = [dict(o, group=g["group"]) for g in manifest["groups"] for o in g["objects"]]
frags = [data[o["offset"]:o["offset"] + o["bytes"]] for o in objs]
def flip(frag, at):
    return frag[:at] + bytes([frag[at] ^ 0xFF]) + frag[at + 1:]
def first_object(group):
    return next(i for i, o in enumerate(objs) if o["group"] == group and o["object"] == 0)
out = eval(expr)
open(dst, "wb").write(out if isinstance(out, bytes) else b"".join(out))
PY
}

TESTS=0
FAILURES=0

# expect <description> <pass|fail> <check that must decide it, or -> <verify arguments...>
expect() {
    local desc="$1" want="$2" decider="$3"
    shift 3
    local out rc=0
    out=$(python3 "$MANIFEST_PY" verify --manifest "$WORK/fixture/manifest.json" "$@") || rc=$?
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

# expect_diag <description> <key: value that must appear> <verify arguments...>
expect_diag() {
    local desc="$1" want="$2"
    shift 2
    local out
    out=$(python3 "$MANIFEST_PY" verify --manifest "$WORK/fixture/manifest.json" "$@") || true
    TESTS=$((TESTS + 1))
    if echo "$out" | grep -qF "# $want"; then
        echo "ok $TESTS - $desc"
    else
        echo "not ok $TESTS - $desc"
        echo "# ${out//$'\n'/$'\n'# }"
        FAILURES=$((FAILURES + 1))
    fi
}

mutate video identity '[init] + frags'
mutate video flipped '[init] + [flip(f, len(f) - 10) if i == 7 else f for i, f in enumerate(frags)]'
mutate video dropped '[init] + [f for i, f in enumerate(frags) if i != 7]'
mutate video swapped '[init] + frags[:7] + [frags[8], frags[7]] + frags[9:]'
mutate video duplicated '[init] + frags[:8] + [frags[7]] + frags[8:]'
mutate video truncated '[init] + frags[:-3]'
mutate video tail-at-group '[init] + frags[first_object(2):]'
mutate video tail-mid-group '[init] + frags[first_object(1) + 2:]'
mutate video wrong-init '[flip(init, len(init) - 1)] + frags'
mutate video no-fragments 'init'
mutate audio audio-identity '[init] + frags'
mutate audio audio-tail '[init] + frags[first_object(2):]'

expect "the fixture itself passes every check" pass - --track video --file "$WORK/identity.mp4" --decode
expect "the audio fixture passes every check" pass - --track audio --file "$WORK/audio-identity.mp4" --decode
expect "one corrupted payload byte fails byte identity" fail byte-identical --track video --file "$WORK/flipped.mp4"
expect "a dropped fragment fails ordering" fail ordering --track video --file "$WORK/dropped.mp4"
expect "two swapped fragments fail ordering" fail ordering --track video --file "$WORK/swapped.mp4"
expect "a duplicated fragment fails ordering" fail ordering --track video --file "$WORK/duplicated.mp4"
expect "a truncated track fails ordering" fail ordering --track video --file "$WORK/truncated.mp4"
expect "a corrupted init segment fails byte identity" fail byte-identical --track video --file "$WORK/wrong-init.mp4"
expect "an init segment alone fails" fail byte-identical --track video --file "$WORK/no-fragments.mp4"
expect "a tail from a group boundary passes" pass - --track video --file "$WORK/tail-at-group.mp4" --decode
expect_diag "a tail from a group boundary decodes only its groups" "expected_frames: 60" --track video --file "$WORK/tail-at-group.mp4" --decode
expect "a tail from mid-group passes, decoding from the next group" pass - --track video --file "$WORK/tail-mid-group.mp4" --decode
expect_diag "a mid-group tail reports its first object" "first_object: 2" --track video --file "$WORK/tail-mid-group.mp4"
expect_diag "a mid-group tail decodes the complete groups only" "complete_groups: 2" --track video --file "$WORK/tail-mid-group.mp4" --decode
expect "an audio tail from a group boundary passes" pass - --track audio --file "$WORK/audio-tail.mp4" --decode

# The catalog check.
TESTS=$((TESTS + 1))
if python3 "$MANIFEST_PY" verify-catalog --expected "$WORK/fixture/catalog.json" --received "$WORK/fixture/catalog.json" >/dev/null; then
    echo "ok $TESTS - the expected catalog equals itself"
else
    echo "not ok $TESTS - the expected catalog equals itself"
    FAILURES=$((FAILURES + 1))
fi
python3 - "$WORK/fixture/catalog.json" "$WORK/catalog-changed.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["tracks"][0]["codec"] = "avc1.640028"
json.dump(c, open(sys.argv[2], "w"))
PY
TESTS=$((TESTS + 1))
if out=$(python3 "$MANIFEST_PY" verify-catalog --expected "$WORK/fixture/catalog.json" --received "$WORK/catalog-changed.json"); then
    echo "not ok $TESTS - a changed codec string fails the catalog check"
    FAILURES=$((FAILURES + 1))
elif echo "$out" | grep -q 'tracks\[0\].codec'; then
    echo "ok $TESTS - a changed codec string fails the catalog check"
else
    echo "not ok $TESTS - a changed codec string fails the catalog check"
    echo "# ${out//$'\n'/$'\n'# }"
    FAILURES=$((FAILURES + 1))
fi

echo "1..$TESTS"
if [ "$FAILURES" -gt 0 ]; then
    echo "# $FAILURES of $TESTS tests failed"
    exit 1
fi

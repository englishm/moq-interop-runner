#!/bin/bash
# lib/media/mpeg-ts/make-fixture.sh - generate the MPEG-TS fixtures for the media tests
#
# Usage: bash lib/media/mpeg-ts/make-fixture.sh [--step | --mpts] [out.ts]
#
#   (no option)  fixture.ts, the area's fixture (docs/tests/media/mpeg-ts.md)
#   --step       fixture-step.ts and its manifest fixture-step.json: two encodes of the area's
#                fixture on clocks 16,844.5 s apart, spliced at one packet 10 s into 20 s
#                (docs/tests/media/ts-clock-step.md)
#   --mpts       fixture-mpts.ts: three programmes under one PAT, programme 1 the area's fixture
#                and programme 3 on an unrelated clock (docs/tests/media/ts-multi-program.md)
#
# Synthetic and generated rather than committed, so nothing large or rights-encumbered enters
# the repository; intended to run at image build time. Every property a test relies on is set
# explicitly here. Overriding a variable produces a different fixture, which is useful for
# development but not for a test run.
#
# The same ffmpeg build reproduces the same bytes; different builds may not, which is why the
# publisher and checker read the fixture from the same image rather than regenerating it.
# --mpts also needs TSDuck, and its merge timing varies between builds, so its bytes do too.

set -euo pipefail

MODE=area
case "${1:-}" in
    --step) MODE=step; shift ;;
    --mpts) MODE=mpts; shift ;;
    -*) echo "make-fixture: unknown option $1" >&2; exit 2 ;;
esac
case "$MODE" in
    area) OUT=${1:-fixture.ts} ;;
    *) OUT=${1:-fixture-$MODE.ts} ;;
esac

DURATION=${DURATION:-20}
WIDTH=${WIDTH:-640}
HEIGHT=${HEIGHT:-360}
FPS=${FPS:-25}
GOP=${GOP:-$FPS}                # closed 1 s GOP: a random access point every second
VBPS=${VBPS:-1500k}
ABPS=${ABPS:-128k}
MUXRATE=${MUXRATE:-2000000}     # constant mux rate, padded with null packets
SERVICE_ID=${SERVICE_ID:-1}
PMT_PID=${PMT_PID:-0x1000}
START_PID=${START_PID:-0x0100}
STEP=${STEP:-16844.5}           # --step: the second encode's clock, this far behind the first's
STEP_BASE=${STEP_BASE:-33155.5} # --step: the lower clock, so the step back stays above zero
STEP_AT=${STEP_AT:-10}          # --step: the splice, seconds into the first encode
STEP_KEY=${STEP_KEY:-0.08}      # --step: the second encode's first random access point after it
STEP_SKEW=${STEP_SKEW:-0.28}    # --step: the second encode starts this far into the programme
MPTS_CLOCK=${MPTS_CLOCK:-25630} # --mpts: programmes 1 and 2's clock; programme 3 keeps ffmpeg's
MPTS_LEAD=${MPTS_LEAD:-1}       # --mpts: seconds cut while the merge starts inserting

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v ffmpeg >/dev/null || { echo "make-fixture: ffmpeg not found" >&2; exit 1; }
for tool in tsp ffprobe python3; do
    command -v "$tool" >/dev/null || { echo "make-fixture: $tool not found; the fixture cannot be checked" >&2; exit 1; }
done

# encode <out> [ffmpeg input and output options]: the area's fixture. bitexact keeps encoder
# version strings and other build-dependent metadata out of the output; one encoder thread keeps
# x264's output independent of the build host's core count.
encode() {
    local out=$1 skew=${SKEW:-} offset=${OFFSET:-}
    ffmpeg -nostdin -hide_banner -loglevel error -y \
        ${skew:+-ss "$skew"} -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}" \
        ${skew:+-ss "$skew"} -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=${DURATION}" \
        -flags +bitexact -fflags +bitexact \
        -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p \
        -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -bf 0 \
        -x264-params "open-gop=0:threads=1:sliced-threads=0" \
        -b:v "$VBPS" -minrate "$VBPS" -maxrate "$VBPS" -bufsize "$VBPS" \
        -c:a aac -b:a "$ABPS" -ar 48000 -ac 2 \
        -muxrate "$MUXRATE" -pcr_period 20 \
        -mpegts_service_id "$SERVICE_ID" \
        -mpegts_pmt_start_pid "$PMT_PID" \
        -mpegts_start_pid "$START_PID" \
        ${offset:+-output_ts_offset "$offset"} \
        -f mpegts "$out"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CHECK_ARGS=()

case "$MODE" in
area)
    encode "$OUT"
    ;;
step)
    MANIFEST="${OUT%.ts}.json"
    OFFSET=$(python3 -c "print($STEP_BASE + $STEP)") encode "$WORK/first.ts"
    OFFSET=$STEP_BASE SKEW=$STEP_SKEW encode "$WORK/second.ts"
    python3 "$SCRIPT_DIR/splice-step.py" "$WORK/first.ts" "$WORK/second.ts" "$OUT" "$MANIFEST" \
        --cut "$STEP_AT" --key "$STEP_KEY" >/dev/null
    CHECK_ARGS=(--expect-step)
    ;;
mpts)
    LONG=$((DURATION + MPTS_LEAD + 2))
    # Programme 1: the area's fixture, padded with one null packet per packet so its PCRs stay
    # exact at twice the rate and the padding makes room for the other two.
    DURATION=$LONG OFFSET=$MPTS_CLOCK encode "$WORK/p1.ts"
    tsp --add-input-stuffing 1/1 -I file "$WORK/p1.ts" -O file "$WORK/base.ts"
    # Programme 2: video only, on programme 1's clock. Programme 3: video and audio, VBR, on its own.
    ffmpeg -nostdin -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=480x270:rate=${FPS}:duration=${LONG}" \
        -flags +bitexact -fflags +bitexact \
        -c:v libx264 -preset veryfast -pix_fmt yuv420p -x264-params threads=1 \
        -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -bf 0 -b:v 500k -maxrate 500k -bufsize 500k \
        -muxrate 700000 -pcr_period 20 -output_ts_offset "$MPTS_CLOCK" -f mpegts "$WORK/p2.ts"
    ffmpeg -nostdin -hide_banner -loglevel error -y \
        -f lavfi -i "smptebars=size=480x270:rate=${FPS}:duration=${LONG}" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=${LONG}" \
        -flags +bitexact -fflags +bitexact \
        -c:v libx264 -preset veryfast -pix_fmt yuv420p -x264-params threads=1 \
        -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -bf 0 -b:v 300k -maxrate 400k -bufsize 800k \
        -c:a aac -b:a 64k -muxrate 600000 -pcr_period 20 -f mpegts "$WORK/p3.ts"
    rate=$(tsp -I file "$WORK/base.ts" -P analyze --normalized -O drop 2>/dev/null |
        sed -n 's/^ts:.*:pcrbitrate=\([0-9]*\):.*/\1/p' | head -1)
    # The main input waits for the merged ones to start, which a file read would outrun.
    # --acceleration-threshold 0 inserts each merged programme by its own PCR rather than as soon
    # as nulls are free; --no-psi-merge keeps programme 1's tables, which -P pat and -P sdt extend.
    tsp -I fork "sleep 2; cat $WORK/base.ts" \
        -P merge --no-psi-merge --acceleration-threshold 0 \
        "tsp -I file $WORK/p2.ts -P svrename 1 --id 2 -P remap 0x1000=0x0200 0x0100=0x0211" \
        -P merge --no-psi-merge --acceleration-threshold 0 \
        "tsp -I file $WORK/p3.ts -P svrename 1 --id 3 -P remap 0x1000=0x0300 0x0100=0x0311 0x0101=0x0312" \
        -P pat --add-service 2/0x0200 --add-service 3/0x0300 \
        -P sdt --service-id 2 --name 'Video only' --provider 'moq-interop-runner' --type 1 \
        -P sdt --service-id 3 --name 'Own clock' --provider 'moq-interop-runner' --type 1 \
        -P skip $((rate * MPTS_LEAD / 8 / 188)) \
        -P until --packets $((rate * (DURATION + 1) / 8 / 188)) \
        -O file "$WORK/merged.ts"
    # Start at the PAT before a random access point of programme 1 with no other programme's
    # random access point between them, so the fixture's first random access point is
    # programme 1's, then cut to DURATION.
    python3 - "$WORK/merged.ts" "$OUT" "$((rate * DURATION / 8 / 188))" <<'EOF'
import sys
src, dst, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(src, "rb").read()
pk = [data[i:i + 188] for i in range(0, len(data), 188)]
pid = lambda p: ((p[1] & 0x1F) << 8) | p[2]
rap = lambda p: p[1] & 0x40 and p[3] & 0x20 and p[4] > 0 and p[5] & 0x40
videos = {0x0100, 0x0211, 0x0311}
pat = None
for i, p in enumerate(pk):
    if pid(p) == 0 and p[1] & 0x40:
        pat = i
    elif pat is not None and pid(p) in videos and rap(p):
        if pid(p) == 0x0100:
            break
        pat = None
else:
    sys.exit("make-fixture: no PAT before one of programme 1's random access points")
if len(pk) - pat < count:
    sys.exit("make-fixture: the merged stream is shorter than the fixture")
open(dst, "wb").write(b"".join(pk[pat:pat + count]))
EOF
    CHECK_ARGS=(--programs 3)
    ;;
esac

bytes=$(wc -c <"$OUT" | tr -d ' ')

# A fixture that fails the oracle it will be judged by is not a fixture.
if ! report=$(python3 "$SCRIPT_DIR/check-ts.py" --fixture "$OUT" --received "$OUT" ${CHECK_ARGS[@]+"${CHECK_ARGS[@]}"}); then
    echo "make-fixture: $OUT fails its own oracle:" >&2
    echo "$report" >&2
    exit 1
fi

echo "make-fixture: $OUT ${bytes} bytes, $((bytes / 188)) packets, ${DURATION}s"

#!/bin/bash
# lib/media/mpeg-ts/make-fixture.sh - generate the MPEG-TS fixture for the media tests
#
# Usage: bash lib/media/mpeg-ts/make-fixture.sh [fixture.ts]
#
# Synthetic and generated rather than committed, so nothing large or rights-encumbered enters
# the repository; intended to run at image build time. docs/tests/media/mpeg-ts.md defines the
# fixture, and every property a test relies on is set explicitly here. Overriding a variable
# produces a different fixture, which is useful for development but not for a test run.
#
# The same ffmpeg build reproduces the same bytes; different builds may not, which is why the
# publisher and checker read the fixture from the same image rather than regenerating it.

set -euo pipefail

OUT=${1:-fixture.ts}
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v ffmpeg >/dev/null || { echo "make-fixture: ffmpeg not found" >&2; exit 1; }

# bitexact keeps encoder version strings and other build-dependent metadata out of the output.
ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=${DURATION}" \
    -flags +bitexact -fflags +bitexact \
    -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -bf 0 -x264-params open-gop=0 \
    -b:v "$VBPS" -minrate "$VBPS" -maxrate "$VBPS" -bufsize "$VBPS" \
    -c:a aac -b:a "$ABPS" -ar 48000 -ac 2 \
    -muxrate "$MUXRATE" -pcr_period 20 \
    -mpegts_service_id "$SERVICE_ID" \
    -mpegts_pmt_start_pid "$PMT_PID" \
    -mpegts_start_pid "$START_PID" \
    -f mpegts "$OUT"

bytes=$(wc -c <"$OUT" | tr -d ' ')

# A fixture that fails the oracle it will be judged by is not a fixture.
if command -v tsp >/dev/null; then
    if ! report=$(python3 "$SCRIPT_DIR/check-ts.py" --fixture "$OUT" --received "$OUT"); then
        echo "make-fixture: $OUT fails its own oracle:" >&2
        echo "$report" >&2
        exit 1
    fi
fi

echo "make-fixture: $OUT ${bytes} bytes, $((bytes / 188)) packets, ${DURATION}s at ${MUXRATE} b/s"

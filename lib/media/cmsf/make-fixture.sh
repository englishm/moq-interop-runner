#!/bin/bash
# lib/media/cmsf/make-fixture.sh - generate the CMSF fixture for the media tests
#
# Usage: bash lib/media/cmsf/make-fixture.sh [output-dir]
#
# Writes video.mp4 and audio.mp4 (one CMAF track file each), then manifest.json and
# catalog.json from manifest.py, into output-dir (default: the current directory).
#
# Synthetic and generated rather than committed, so nothing large or rights-encumbered enters
# the repository; intended to run at image build time. docs/tests/media/cmsf.md defines the
# fixture, and every property a test relies on is set explicitly here. Overriding a variable
# produces a different fixture, which is useful for development but not for a test run.
#
# The same ffmpeg build reproduces the same bytes; different builds may not, which is why the
# publisher and checker read the fixture and manifest from the same image rather than
# regenerating them.

set -euo pipefail

OUT_DIR=${1:-.}
DURATION=${DURATION:-10}
WIDTH=${WIDTH:-640}
HEIGHT=${HEIGHT:-360}
FPS=${FPS:-30}
GOP=${GOP:-$FPS}                    # closed 1 s GOP: every group starts on a keyframe
VBPS=${VBPS:-1500k}
ABPS=${ABPS:-128k}
FRAG_US=${FRAG_US:-200000}          # 200 ms fragments: 5 video objects per 1 s group

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v ffmpeg >/dev/null || { echo "make-fixture: ffmpeg not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "make-fixture: python3 not found" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# CMAF: fragmented, empty moov, default-base-is-moof, negative CTS offsets; skip_trailer
# leaves out the mfra index some ffmpeg builds append after the last fragment.
# frag_keyframe starts a fragment on every keyframe and frag_duration cuts the rest.
# bitexact keeps encoder version strings, creation times and other build-dependent
# metadata out of the output.
MOVFLAGS="cmaf+frag_keyframe+empty_moov+default_base_moof+skip_trailer"

ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}" \
    -flags +bitexact -fflags +bitexact \
    -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -bf 0 \
    -x264-params "open-gop=0:threads=1:sliced-threads=0" \
    -b:v "$VBPS" -minrate "$VBPS" -maxrate "$VBPS" -bufsize "$VBPS" \
    -an \
    -f mp4 -movflags "$MOVFLAGS" -frag_duration "$FRAG_US" \
    "$OUT_DIR/video.mp4"

ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=${DURATION}" \
    -flags +bitexact -fflags +bitexact \
    -c:a aac -b:a "$ABPS" -ar 48000 -ac 2 \
    -vn \
    -f mp4 -movflags "$MOVFLAGS" -frag_duration "$FRAG_US" \
    "$OUT_DIR/audio.mp4"

FFMPEG_VERSION=$(ffmpeg -version | head -n1)

python3 "$SCRIPT_DIR/manifest.py" build \
    --fixture-dir "$OUT_DIR" \
    --duration-ms "$((DURATION * 1000))" \
    --generator "$FFMPEG_VERSION"

# A fixture that fails the oracle it will be judged by is not a fixture.
for track in video audio; do
    if ! report=$(python3 "$SCRIPT_DIR/manifest.py" verify \
            --manifest "$OUT_DIR/manifest.json" --track "$track" \
            --file "$OUT_DIR/$track.mp4" --decode); then
        echo "make-fixture: $track.mp4 fails its own oracle:" >&2
        echo "$report" >&2
        exit 1
    fi
done

vbytes=$(wc -c <"$OUT_DIR/video.mp4" | tr -d ' ')
abytes=$(wc -c <"$OUT_DIR/audio.mp4" | tr -d ' ')
echo "make-fixture: ${DURATION}s CMSF fixture in $OUT_DIR: video.mp4 ${vbytes} bytes, audio.mp4 ${abytes} bytes, manifest.json, catalog.json"

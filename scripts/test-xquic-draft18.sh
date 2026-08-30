#!/bin/bash
# Run the xquic draft-18 client against registered remote raw-QUIC relays and
# render the runner's result as HTML.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_IMAGE="xquic-moq-client-draft-18:latest"
REGISTERED_IMAGE="ghcr.io/englishm/moq-interop-runner-xquic-moq-client-draft-18:latest"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Docker is required and its daemon must be running." >&2
    exit 1
fi

if [ -n "${XQUIC_SOURCE:-}" ]; then
    if [ ! -d "$XQUIC_SOURCE" ]; then
        echo "XQUIC_SOURCE does not exist: $XQUIC_SOURCE" >&2
        exit 1
    fi
    "$RUNNER_ROOT/builds/xquic/build.sh" \
        --local "$XQUIC_SOURCE" \
        --target client-draft-18
fi

# The runner reads the publishable image name from implementations.json.
# Re-tag a local development build without changing the shared registry.
if docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
    docker tag "$LOCAL_IMAGE" "$REGISTERED_IMAGE"
elif ! docker image inspect "$REGISTERED_IMAGE" >/dev/null 2>&1; then
    echo "The xquic draft-18 client image is not available." >&2
    echo "Build it with XQUIC_SOURCE=/absolute/path/to/xquic or pull:" >&2
    echo "  docker pull $REGISTERED_IMAGE" >&2
    exit 1
fi

RUNNER_LOG=$(mktemp "${TMPDIR:-/tmp}/xquic-draft18-run.XXXXXX")
cleanup() {
    rm -f "$RUNNER_LOG"
}
trap cleanup EXIT

set +e
"$RUNNER_ROOT/run-interop-tests.sh" \
    --client xquic-draft-18 \
    --target-version draft-18 \
    --only-at-target \
    --remote-only \
    --quic-only \
    "$@" 2>&1 | tee "$RUNNER_LOG"
run_status=${PIPESTATUS[0]}
set -e

RESULT_DIR=$(sed -n 's/^Results saved to: //p' "$RUNNER_LOG" | tail -n 1)
if [ -n "$RESULT_DIR" ] && [ -f "$RESULT_DIR/summary.json" ]; then
    "$RUNNER_ROOT/generate-report.sh" "$RESULT_DIR"
    echo "HTML report: $RESULT_DIR/report.html"
fi

exit "$run_status"

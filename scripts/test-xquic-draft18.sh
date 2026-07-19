#!/bin/bash
# Build the local xquic client (optional), run all supported tests, and render
# the result as HTML. The default matrix uses remote draft-18 raw-QUIC relays;
# --local-relay selects the registered local moq-rs draft-18 relay image.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_ENV="$SCRIPT_DIR/local-container-env.sh"
CLIENT_IMPL="xquic-draft-18"
CLIENT_IMAGE="xquic-moq-client-draft-18:latest"
LOCAL_RELAY_IMPL="moq-rs-draft-18"
LOCAL_RELAY_IMAGE="ghcr.io/englishm/moq-interop-runner-moq-relay-ietf-draft-18:latest"
RUN_MODE="remote"

if [ "${1:-}" = "--local-relay" ]; then
    RUN_MODE="local"
    shift
fi

if ! "$LOCAL_ENV" docker info >/dev/null 2>&1; then
    echo "Docker is not available. Start the local runtime first:" >&2
    echo "  make local-runtime-start" >&2
    exit 1
fi

if [ -n "${XQUIC_SOURCE:-}" ]; then
    if [ ! -d "$XQUIC_SOURCE" ]; then
        echo "XQUIC_SOURCE does not exist: $XQUIC_SOURCE" >&2
        exit 1
    fi
    "$LOCAL_ENV" "$RUNNER_ROOT/builds/xquic/build.sh" \
        --local "$XQUIC_SOURCE" --target client
elif ! "$LOCAL_ENV" docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1; then
    echo "No local $CLIENT_IMAGE image was found." >&2
    echo "Build it by setting the draft-18 checkout:" >&2
    echo "  make xquic-client-build XQUIC_SOURCE=/absolute/path/to/xquic" >&2
    exit 1
fi

DEV_CONFIG=$(mktemp "${TMPDIR:-/tmp}/moq-xquic-draft18.XXXXXX.json")
cleanup() {
    rm -f "$DEV_CONFIG"
}
trap cleanup EXIT

# The checked-in registry uses the publishable GHCR image name. Override only
# the client image for a local-source development run.
jq '
    .implementations["xquic-draft-18"].roles.client.docker.image = "xquic-moq-client-draft-18:latest"
' "$RUNNER_ROOT/implementations.json" > "$DEV_CONFIG"

RUN_ID="$(date +%Y-%m-%d_%H%M%S)-xquic-draft18-${RUN_MODE}"
PIPELINE_RESULTS_DIR="$RUNNER_ROOT/results/$RUN_ID"

runner_args=(
    --config "$DEV_CONFIG"
    --client "$CLIENT_IMPL"
    --target-version draft-18
    --only-at-target
)

if [ "$RUN_MODE" = "local" ]; then
    # macOS protects Documents from the Colima virtiofs process even though
    # the Docker CLI can read the checkout. Stage only bind-mounted runtime
    # files under Colima's short home, which is visible inside the VM.
    if [ "$(uname -s)" = "Darwin" ]; then
        MOQT_HOST_IO_ROOT="${MOQT_HOST_IO_ROOT:-/Users/$(id -un)/.moq-interop-colima/io}"
        export MOQT_HOST_IO_ROOT
        "$RUNNER_ROOT/generate-certs.sh" "$RUNNER_ROOT/certs"
        mkdir -p \
            "$MOQT_HOST_IO_ROOT/certs" \
            "$MOQT_HOST_IO_ROOT/mlog/relay" \
            "$MOQT_HOST_IO_ROOT/mlog/client"
        cp "$RUNNER_ROOT/certs/cert.pem" "$MOQT_HOST_IO_ROOT/certs/cert.pem"
        cp "$RUNNER_ROOT/certs/priv.key" "$MOQT_HOST_IO_ROOT/certs/priv.key"
    fi

    if ! "$LOCAL_ENV" docker image inspect "$LOCAL_RELAY_IMAGE" >/dev/null 2>&1; then
        echo "Pulling registered local draft-18 relay image..." >&2
        "$LOCAL_ENV" docker pull "$LOCAL_RELAY_IMAGE"
    fi
    runner_args+=(--docker-only --relay "$LOCAL_RELAY_IMPL")
else
    runner_args+=(--remote-only --quic-only)
fi

set +e
RESULTS_DIR="$PIPELINE_RESULTS_DIR" \
    "$LOCAL_ENV" "$RUNNER_ROOT/run-interop-tests.sh" "${runner_args[@]}" "$@"
run_status=$?
set -e

if [ -f "$PIPELINE_RESULTS_DIR/summary.json" ]; then
    NO_OPEN=1 "$RUNNER_ROOT/generate-report.sh" "$PIPELINE_RESULTS_DIR"
    echo "HTML report: $PIPELINE_RESULTS_DIR/report.html"
    echo "HTML index:  $RUNNER_ROOT/results/index.html"
fi

exit "$run_status"

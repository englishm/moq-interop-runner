#!/bin/bash
# build.sh - Build moq-dev-js test client Docker image
#
# Usage:
#   ./build.sh
#
# Source code is embedded in this repository (builds/moq-dev-js/),
# so no external clone is needed. Provenance uses the runner repo commit.

set -euo pipefail

IMPL_NAME="moq-dev-js"
BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "${BUILD_DIR}/../.." && pwd)"

log() {
    echo "[build] $*" >&2
}

get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

get_git_commit() {
    local dir="$1"
    git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown"
}

is_git_dirty() {
    local dir="$1"
    if git -C "$dir" diff --quiet HEAD 2>/dev/null && \
       git -C "$dir" diff --cached --quiet HEAD 2>/dev/null; then
        echo "false"
    else
        echo "true"
    fi
}

#############################################################################
# Docker Build
#############################################################################

IMAGE_NAME="moq-dev-js-client"

log "Building ${IMAGE_NAME}:latest"
docker build -t "${IMAGE_NAME}:latest" -f "${BUILD_DIR}/Dockerfile.client" "${BUILD_DIR}"

#############################################################################
# Provenance Output
#############################################################################

TIMESTAMP=$(get_timestamp)
RUNNER_COMMIT=$(get_git_commit "$RUNNER_ROOT")
RUNNER_DIRTY=$(is_git_dirty "$RUNNER_ROOT")

PROVENANCE=$(jq -n \
    --arg impl "$IMPL_NAME" \
    --arg ts "$TIMESTAMP" \
    --arg runner_commit "$RUNNER_COMMIT" \
    --arg commit "$RUNNER_COMMIT" \
    --argjson dirty "$RUNNER_DIRTY" \
    '{
        implementation: $impl,
        timestamp: $ts,
        runner_commit: $runner_commit,
        source: {
            type: "embedded",
            repository: "https://github.com/englishm/moq-interop-runner",
            ref: "main",
            local_path: null,
            commit: $commit,
            dirty: $dirty
        },
        images: [
            { target: "client", image: ($impl + "-client:latest") }
        ]
    }'
)

echo "$PROVENANCE" > "${BUILD_DIR}/.last-build.json"
log "Provenance saved to ${BUILD_DIR}/.last-build.json"

echo ""
echo "=== Build Provenance ==="
echo "$PROVENANCE"

log "Done"

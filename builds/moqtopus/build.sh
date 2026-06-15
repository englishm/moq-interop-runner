#!/bin/bash

set -euo pipefail

IMPL_NAME="moqtopus"
REPO_URL="https://github.com/kota-yata/Moqtopus.git"
DEFAULT_REF="main"

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="${BUILD_DIR}/.sources"
RUNNER_ROOT="$(cd "${BUILD_DIR}/../.." && pwd)"

log() {
    echo "[build] $*" >&2
}

error() {
    echo "[build] ERROR: $*" >&2
    exit 1
}

get_git_commit() {
    git -C "$1" rev-parse HEAD 2>/dev/null || echo "unknown"
}

is_git_dirty() {
    if git -C "$1" diff --quiet HEAD 2>/dev/null && \
       git -C "$1" diff --cached --quiet HEAD 2>/dev/null; then
        echo "false"
    else
        echo "true"
    fi
}

REF=""
LOCAL_PATH=""
TARGET=""
CUSTOM_REPO=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --ref)
            [[ -n "${2:-}" ]] || error "--ref requires a value"
            REF="$2"
            shift 2
            ;;
        --repo)
            [[ -n "${2:-}" ]] || error "--repo requires a value"
            CUSTOM_REPO="$2"
            shift 2
            ;;
        --local)
            [[ -n "${2:-}" ]] || error "--local requires a value"
            LOCAL_PATH="$2"
            shift 2
            ;;
        --target)
            [[ -n "${2:-}" ]] || error "--target requires a value"
            TARGET="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--ref REF | --local PATH] [--repo URL] [--target client]"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

[[ -z "$CUSTOM_REPO" ]] || REPO_URL="$CUSTOM_REPO"
[[ -z "$REF" || -z "$LOCAL_PATH" ]] || error "Cannot specify both --ref and --local"
[[ -z "$CUSTOM_REPO" || -z "$LOCAL_PATH" ]] || error "Cannot specify both --repo and --local"
[[ -z "$TARGET" || "$TARGET" = "client" ]] || error "Only the client target is supported"

if [[ -n "$LOCAL_PATH" ]]; then
    [[ -d "$LOCAL_PATH" ]] || error "Local path does not exist: $LOCAL_PATH"
    SOURCE_DIR="$(cd "$LOCAL_PATH" && pwd)"
    SOURCE_TYPE="local"
    log "Using local checkout: $SOURCE_DIR"
else
    REF="${REF:-$DEFAULT_REF}"
    SOURCE_DIR="${SOURCES_DIR}/${IMPL_NAME}"
    SOURCE_TYPE="git"
    mkdir -p "$SOURCES_DIR"

    if [[ -d "$SOURCE_DIR/.git" ]]; then
        EXISTING_URL=$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || echo "")
        if [[ "$EXISTING_URL" != "$REPO_URL" ]]; then
            rm -rf "$SOURCE_DIR"
            git clone "$REPO_URL" "$SOURCE_DIR"
        else
            git -C "$SOURCE_DIR" fetch origin
        fi
    else
        rm -rf "$SOURCE_DIR"
        git clone "$REPO_URL" "$SOURCE_DIR"
    fi

    git -C "$SOURCE_DIR" checkout "$REF"
    git -C "$SOURCE_DIR" pull origin "$REF" 2>/dev/null || true
fi

SOURCE_COMMIT=$(get_git_commit "$SOURCE_DIR")
SOURCE_DIRTY=$(is_git_dirty "$SOURCE_DIR")
ENTRYPOINT_DEST="${SOURCE_DIR}/moqtopus-interop-entrypoint.sh"

cleanup() {
    rm -f "$ENTRYPOINT_DEST"
}
trap cleanup EXIT

cp "${BUILD_DIR}/entrypoint-client.sh" "$ENTRYPOINT_DEST"

log "Building client -> moqtopus-interop-client:latest"
docker build \
    -f "${BUILD_DIR}/Dockerfile.client" \
    -t moqtopus-interop-client:latest \
    "$SOURCE_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RUNNER_COMMIT=$(git -C "$RUNNER_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")

jq -n \
    --arg impl "$IMPL_NAME" \
    --arg ts "$TIMESTAMP" \
    --arg runner_commit "$RUNNER_COMMIT" \
    --arg source_type "$SOURCE_TYPE" \
    --arg repo "$REPO_URL" \
    --arg ref "${REF:-local}" \
    --arg local_path "${LOCAL_PATH:-}" \
    --arg commit "$SOURCE_COMMIT" \
    --argjson dirty "$SOURCE_DIRTY" \
    '{
        implementation: $impl,
        timestamp: $ts,
        runner_commit: $runner_commit,
        source: {
            type: $source_type,
            repository: $repo,
            ref: $ref,
            local_path: (if $local_path == "" then null else $local_path end),
            commit: $commit,
            dirty: $dirty
        },
        images: [
            {target: "client", image: "moqtopus-interop-client:latest"}
        ]
    }' | tee "${BUILD_DIR}/.last-build.json"

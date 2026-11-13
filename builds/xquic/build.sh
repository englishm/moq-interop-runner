#!/bin/bash
# build.sh - Build draft-22 xquic client/server endpoint images
#
# Usage:
#   ./build.sh                              # Clone dev/moqt-interop
#   ./build.sh --ref dev/moqt-interop        # Select branch/tag/commit
#   ./build.sh --local ~/github_xquic/xquic # Use local checkout
#   ./build.sh --target client               # Build xquic-client only
#   ./build.sh --target relay                # Build xquic-relay only

set -euo pipefail

#############################################################################
# Configuration
#############################################################################

IMPL_NAME="xquic"
REPO_URL="https://github.com/alibaba/xquic.git"

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="${BUILD_DIR}/.sources"
RUNNER_ROOT="$(cd "${BUILD_DIR}/../.." && pwd)"
CONFIG="${BUILD_DIR}/config.json"

#############################################################################
# Utility Functions
#############################################################################

log() {
    echo "[build] $*" >&2
}

error() {
    echo "[build] ERROR: $*" >&2
    exit 1
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

get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

get_runner_commit() {
    git -C "$RUNNER_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown"
}

#############################################################################
# Argument Parsing
#############################################################################

REF=""
LOCAL_PATH=""
TARGET=""
CUSTOM_REPO=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --ref)
            [[ -n "${2:-}" ]] || error "--ref requires a value"
            REF="$2"; shift 2 ;;
        --repo)
            [[ -n "${2:-}" ]] || error "--repo requires a value"
            CUSTOM_REPO="$2"; shift 2 ;;
        --local)
            [[ -n "${2:-}" ]] || error "--local requires a value"
            LOCAL_PATH="$2"; shift 2 ;;
        --target)
            [[ -n "${2:-}" ]] || error "--target requires a value"
            TARGET="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --ref REF       Git ref to checkout (branch/tag/commit)"
            echo "  --repo URL      Clone from a different repository (fork)"
            echo "  --local PATH    Use local xquic checkout instead of cloning"
            echo "  --target NAME   Build client or relay (default: both)"
            echo "  --help          Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                                           # Clone dev/moqt-interop"
            echo "  $0 --local ~/github_xquic/xquic             # Use local checkout"
            echo "  $0 --local ~/github_xquic/xquic --target client"
            echo "  $0 --local ~/github_xquic/xquic --target relay"
            exit 0
            ;;
        *) error "Unknown option: $1" ;;
    esac
done

case "$TARGET" in
    ""|client|relay) ;;
    *) error "Unknown target: $TARGET (supported: client, relay)" ;;
esac
command -v jq >/dev/null 2>&1 || error "jq is required"
DEFAULT_REF=$(jq -er '.default_ref' "$CONFIG")

if [[ -n "$CUSTOM_REPO" ]]; then
    REPO_URL="$CUSTOM_REPO"
fi

if [[ -n "$REF" && -n "$LOCAL_PATH" ]]; then
    error "Cannot specify both --ref and --local"
fi

if [[ -n "$CUSTOM_REPO" && -n "$LOCAL_PATH" ]]; then
    error "Cannot specify both --repo and --local"
fi

if [[ -z "$REF" && -z "$LOCAL_PATH" ]]; then
    REF="$DEFAULT_REF"
fi

#############################################################################
# Source Preparation
#############################################################################

if [[ -n "$LOCAL_PATH" ]]; then
    if [[ ! -d "$LOCAL_PATH" ]]; then
        error "Local path does not exist: $LOCAL_PATH"
    fi
    SOURCE_DIR="$(cd "$LOCAL_PATH" && pwd)"
    SOURCE_TYPE="local"
    log "Using local checkout: $SOURCE_DIR"
else
    SOURCE_DIR="${SOURCES_DIR}/${IMPL_NAME}"
    SOURCE_TYPE="git"

    mkdir -p "$SOURCES_DIR"

    if [[ -d "$SOURCE_DIR/.git" ]]; then
        EXISTING_URL=$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || echo "")
        if [[ "$EXISTING_URL" != "$REPO_URL" ]]; then
            log "Repo URL changed ($EXISTING_URL -> $REPO_URL), re-cloning..."
            rm -rf "$SOURCE_DIR"
            git clone "$REPO_URL" "$SOURCE_DIR"
        else
            log "Updating existing clone..."
            git -C "$SOURCE_DIR" fetch origin
        fi
    else
        log "Cloning $REPO_URL..."
        rm -rf "$SOURCE_DIR"
        git clone "$REPO_URL" "$SOURCE_DIR"
    fi

    log "Checking out ref: $REF"
    git -C "$SOURCE_DIR" checkout "$REF"
    git -C "$SOURCE_DIR" pull origin "$REF" 2>/dev/null || true
fi

SOURCE_COMMIT=$(get_git_commit "$SOURCE_DIR")
SOURCE_DIRTY=$(is_git_dirty "$SOURCE_DIR")

#############################################################################
# Docker Builds
#############################################################################

BUILT_IMAGES=()

build_target() {
    local target="$1"
    local dockerfile image_name registry_image
    dockerfile="${BUILD_DIR}/$(jq -er --arg target "$target" \
        '.targets[$target].dockerfile' "$CONFIG")"
    image_name=$(jq -er --arg target "$target" \
        '.targets[$target].image_name' "$CONFIG")
    registry_image=$(jq -r --arg target "$target" \
        '.targets[$target].registry_image // empty' "$CONFIG")

    log "Building ${target} -> ${image_name}:latest"
    local args=(build --target "$target" -f "$dockerfile"
        -t "${image_name}:latest")
    # The registered client also gets its registry tag for local runner use.
    if [[ -n "$registry_image" ]]; then
        args+=(-t "${registry_image}:latest")
    fi
    docker "${args[@]}" "$SOURCE_DIR" || error "Docker build failed for ${target}"
    BUILT_IMAGES+=("{\"target\": \"${target}\", \"image\": \"${image_name}:latest\"}")
}

if [[ -n "$TARGET" ]]; then
    build_target "$TARGET"
else
    build_target client
    build_target relay
fi

#############################################################################
# Provenance Output
#############################################################################

TIMESTAMP=$(get_timestamp)
RUNNER_COMMIT=$(get_runner_commit)
IMAGES_JSON=$(IFS=,; echo "${BUILT_IMAGES[*]}")

if command -v jq &>/dev/null; then
    # shellcheck disable=SC2016
    PROVENANCE=$(jq -n \
        --arg impl "$IMPL_NAME" \
        --arg ts "$TIMESTAMP" \
        --arg runner_commit "$RUNNER_COMMIT" \
        --arg source_type "$SOURCE_TYPE" \
        --arg repo "$REPO_URL" \
        --arg ref "${REF:-}" \
        --arg local_path "${LOCAL_PATH:-}" \
        --arg commit "$SOURCE_COMMIT" \
        --argjson dirty "$SOURCE_DIRTY" \
        --argjson images "[$IMAGES_JSON]" \
        '{
            implementation: $impl,
            timestamp: $ts,
            runner_commit: $runner_commit,
            source: {
                type: $source_type,
                repository: $repo,
                ref: (if $ref == "" then "local" else $ref end),
                local_path: (if $local_path == "" then null else $local_path end),
                commit: $commit,
                dirty: $dirty
            },
            images: $images
        }'
    )
    echo "$PROVENANCE" > "${BUILD_DIR}/.last-build.json"
    log "Provenance saved to ${BUILD_DIR}/.last-build.json"
    echo ""
    echo "=== Build Provenance ==="
    echo "$PROVENANCE"
else
    log "jq not found, skipping provenance output"
fi

log "Build complete!"

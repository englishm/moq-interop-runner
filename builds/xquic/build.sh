#!/bin/bash
# build.sh - Build xquic MoQ Docker images from source
#
# Usage:
#   ./build.sh                              # Clone from GitHub (main branch)
#   ./build.sh --ref moq-interop            # Clone specific branch/tag/commit
#   ./build.sh --local ~/github_xquic/xquic # Use local checkout
#   ./build.sh --target relay               # Build only relay image
#
# This builds xquic with MoQ support (-DXQC_ENABLE_MOQ=1) and produces
# a Docker image containing moq_demo_server as the relay endpoint.

set -euo pipefail

#############################################################################
# Configuration
#############################################################################

IMPL_NAME="xquic"
REPO_URL="https://github.com/alibaba/xquic.git"
DEFAULT_REF="main"

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="${BUILD_DIR}/.sources"
RUNNER_ROOT="$(cd "${BUILD_DIR}/../.." && pwd)"

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
            echo "  --target NAME   Build only specific target (relay)"
            echo "  --help          Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                                           # Clone main branch"
            echo "  $0 --local ~/github_xquic/xquic             # Use local checkout"
            echo "  $0 --local ~/github_xquic/xquic --target relay"
            exit 0
            ;;
        *) error "Unknown option: $1" ;;
    esac
done

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
    local dockerfile=""
    local image_name=""
    local entrypoint_script=""

    case "$target" in
        relay)
            dockerfile="${BUILD_DIR}/Dockerfile.relay"
            image_name="xquic-moq-relay"
            entrypoint_script="${BUILD_DIR}/entrypoint-relay.sh"
            ;;
        client)
            dockerfile="${BUILD_DIR}/Dockerfile.client"
            image_name="xquic-moq-client"
            entrypoint_script="${BUILD_DIR}/entrypoint-client.sh"
            ;;
        *)
            error "Unknown target: $target (supported: relay, client)"
            ;;
    esac

    log "Building ${target} -> ${image_name}:latest"
    log "  Dockerfile: ${dockerfile}"
    log "  Context: ${SOURCE_DIR}"

    local entrypoint_dest="${SOURCE_DIR}/$(basename "$entrypoint_script")"
    cp "$entrypoint_script" "$entrypoint_dest"

    if docker build \
        -f "${dockerfile}" \
        -t "${image_name}:latest" \
        "$SOURCE_DIR"; then
        rm -f "$entrypoint_dest"
    else
        rm -f "$entrypoint_dest"
        error "Docker build failed for ${target}"
    fi

    BUILT_IMAGES+=("{\"target\": \"${target}\", \"image\": \"${image_name}:latest\"}")
}

if [[ -n "$TARGET" ]]; then
    build_target "$TARGET"
else
    build_target "relay"
    build_target "client"
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

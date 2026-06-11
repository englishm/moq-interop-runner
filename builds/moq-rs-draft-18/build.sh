#!/bin/bash
# build.sh - Build moq-rs draft-18 Docker images from source
#
# Usage:
#   ./build.sh                      # Clone from default ref (draft-18-dev)
#   ./build.sh --ref feature-branch # Clone specific branch/tag/commit
#   ./build.sh --repo URL           # Clone from a different repository (fork)
#   ./build.sh --local ~/git/moq-rs # Use local checkout
#   ./build.sh --target relay       # Build only relay image
#   ./build.sh --target client      # Build only client image
#
# This script is designed to be easy to copy/paste for other implementations.
# Utility functions at the top can be extracted to a shared library.

set -euo pipefail

#############################################################################
# Configuration (implementation-specific)
#############################################################################

IMPL_NAME="moq-rs-draft-18"
REPO_URL="https://github.com/cloudflare/moq-rs"
DEFAULT_REF="draft-18-dev"

# Build directory (where this script lives)
BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="${BUILD_DIR}/.sources"
RUNNER_ROOT="$(cd "${BUILD_DIR}/../.." && pwd)"

#############################################################################
# Utility Functions (candidates for shared library)
#############################################################################

log() {
    echo "[build] $*" >&2
}

error() {
    echo "[build] ERROR: $*" >&2
    exit 1
}

# Get git commit hash from a directory
get_git_commit() {
    local dir="$1"
    git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown"
}

# Check if git working directory is dirty
is_git_dirty() {
    local dir="$1"
    if git -C "$dir" diff --quiet HEAD 2>/dev/null && \
       git -C "$dir" diff --cached --quiet HEAD 2>/dev/null; then
        echo "false"
    else
        echo "true"
    fi
}

# Get current timestamp in ISO 8601 format
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

#############################################################################
# Argument Parsing
#############################################################################

REPO="$REPO_URL"
REF="$DEFAULT_REF"
LOCAL_PATH=""
TARGET="all"  # all | relay | client

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --ref)
            REF="$2"
            shift 2
            ;;
        --local)
            LOCAL_PATH="$2"
            shift 2
            ;;
        --target)
            TARGET="$2"
            shift 2
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
done

#############################################################################
# Source Preparation
#############################################################################

SOURCE_DIR="${SOURCES_DIR}/${IMPL_NAME}"
SOURCE_INFO=""

if [[ -n "$LOCAL_PATH" ]]; then
    log "Using local checkout: $LOCAL_PATH"
    SOURCE_DIR="$LOCAL_PATH"
    COMMIT=$(get_git_commit "$SOURCE_DIR")
    DIRTY=$(is_git_dirty "$SOURCE_DIR")
    SOURCE_INFO="local:$LOCAL_PATH commit:${COMMIT:0:7} dirty:$DIRTY"
else
    log "Cloning $REPO at ref $REF..."
    mkdir -p "$SOURCES_DIR"
    rm -rf "$SOURCE_DIR"
    git clone --depth=1 --branch "$REF" "$REPO" "$SOURCE_DIR"
    COMMIT=$(get_git_commit "$SOURCE_DIR")
    SOURCE_INFO="repo:$REPO ref:$REF commit:${COMMIT:0:7}"
    log "Cloned at commit $COMMIT"
fi

#############################################################################
# Build
#############################################################################

# We use docker build -f <dockerfile> <context> to keep Dockerfiles in the
# interop-runner repo while using the source repo as the build context.
# This avoids polluting local checkouts with extra files.
#
# If your network uses TLS inspection, place your CA certificate at
# builds/moq-rs-draft-18/extra-ca.pem and it will be trusted during the build.

build_target() {
    local target="$1"
    local image_name=""
    local entrypoint_script=""

    case "$target" in
        relay)
            dockerfile="${BUILD_DIR}/Dockerfile.relay"
            image_name="moq-relay-ietf"
            entrypoint_script="${BUILD_DIR}/entrypoint-relay.sh"
            ;;
        client)
            dockerfile="${BUILD_DIR}/Dockerfile.client"
            image_name="moq-test-client"
            entrypoint_script="${BUILD_DIR}/entrypoint-client.sh"
            ;;
        *)
            error "Unknown target: $target"
            ;;
    esac

    log "Building $image_name from $SOURCE_DIR..."

    # Build args
    local -a build_args=(
        "build"
        "-f" "$dockerfile"
        "-t" "${image_name}:latest"
    )

    # Add extra CA cert if present
    if [[ -f "${BUILD_DIR}/extra-ca.pem" ]]; then
        log "Using extra CA certificate"
        build_args+=("--secret" "id=ca_cert,src=${BUILD_DIR}/extra-ca.pem")
    fi

    # Copy entrypoint into source dir temporarily (needed as Docker build context file)
    cp "$entrypoint_script" "${SOURCE_DIR}/$(basename "$entrypoint_script")"

    build_args+=("$SOURCE_DIR")

    docker "${build_args[@]}"

    # Clean up copied entrypoint
    rm -f "${SOURCE_DIR}/$(basename "$entrypoint_script")"

    log "Built ${image_name}:latest"

    # Write build metadata
    TIMESTAMP=$(get_timestamp)
    cat > "${BUILD_DIR}/.last-build.json" << EOF
{
  "implementation": "${IMPL_NAME}",
  "target": "${target}",
  "image": "${image_name}:latest",
  "built_at": "${TIMESTAMP}",
  "source": {
    "info": "${SOURCE_INFO}",
    "commit": "${COMMIT:-unknown}"
  }
}
EOF
}

case "$TARGET" in
    relay)
        build_target relay
        ;;
    client)
        build_target client
        ;;
    all)
        build_target relay
        build_target client
        ;;
    *)
        error "Unknown target: $TARGET (must be relay, client, or all)"
        ;;
esac

log "Done."

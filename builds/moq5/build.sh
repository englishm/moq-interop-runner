#!/bin/bash
# build.sh - Build the MOQ5 (libmoq) interop test client Docker image
#
# Usage:
#   ./build.sh                          # Clone from GitHub, build client
#   ./build.sh --local ~/git/moq5     # Build from local checkout
#   ./build.sh --ref some-branch        # Build specific ref

set -euo pipefail

IMPL_NAME="moq5"
REPO_URL="https://github.com/openmoq/moq5"
DEFAULT_REF="main"

# libmoq's interop Dockerfile needs picotls/ + picoquic/ as siblings of the
# libmoq checkout. moq5 does not vendor them (no submodules), so the git-clone
# path fetches them here. Both carry their OWN submodules (picotls: cifra/
# micro-ecc), so the clone MUST recurse. Upstream master is sufficient — the
# former libmoq/drain-predicate picoquic fork is no longer required.
PICOQUIC_REPO="https://github.com/private-octopus/picoquic"
PICOQUIC_REF="master"
PICOTLS_REPO="https://github.com/h2o/picotls"
PICOTLS_REF="master"

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="${BUILD_DIR}/.sources"
RUNNER_ROOT="$(cd "${BUILD_DIR}/../.." && pwd)"

log() { echo "[build] $*" >&2; }
error() { echo "[build] ERROR: $*" >&2; exit 1; }

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

get_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Argument parsing
REF="" LOCAL_PATH="" CUSTOM_REPO=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --ref)      REF="$2"; shift 2;;
        --repo)     CUSTOM_REPO="$2"; shift 2;;
        --local)    LOCAL_PATH="$2"; shift 2;;
        --help|-h)
            echo "Usage: $0 [--ref REF|--local PATH] [--repo URL]"
            exit 0;;
        *)          error "Unknown option: $1";;
    esac
done

if [[ -n "$REF" && -n "$LOCAL_PATH" ]]; then error "Cannot use both --ref and --local"; fi
if [[ -n "$CUSTOM_REPO" && -n "$LOCAL_PATH" ]]; then error "Cannot use both --repo and --local"; fi
if [[ -n "$CUSTOM_REPO" ]]; then REPO_URL="$CUSTOM_REPO"; fi
if [[ -z "$REF" && -z "$LOCAL_PATH" ]]; then REF="$DEFAULT_REF"; fi

###############################################################################
# Source preparation
###############################################################################

if [[ -n "$LOCAL_PATH" ]]; then
    if [[ ! -d "$LOCAL_PATH" ]]; then error "Local path does not exist: $LOCAL_PATH"; fi
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
            log "Repo URL changed, re-cloning..."
            rm -rf "$SOURCE_DIR"
            git clone "$REPO_URL" "$SOURCE_DIR"
        else
            log "Updating existing clone..."
            git -C "$SOURCE_DIR" fetch origin
        fi
    else
        log "Cloning $REPO_URL..."
        git clone "$REPO_URL" "$SOURCE_DIR"
    fi

    log "Checking out ref: $REF"
    git -C "$SOURCE_DIR" checkout "$REF"
    git -C "$SOURCE_DIR" pull origin "$REF" 2>/dev/null || true

    # Fetch picotls + picoquic as siblings of the libmoq checkout. MUST recurse
    # submodules (picotls vendors cifra/micro-ecc; a non-recursive clone fails
    # the picotls cmake build). The staging step below detects these siblings.
    clone_dep() {
        local name="$1" url="$2" ref="$3" dir="${SOURCES_DIR}/$1"
        if [[ -d "$dir/.git" ]]; then
            log "Updating $name..."; git -C "$dir" fetch origin
        else
            log "Cloning $name ($url @ $ref)..."; git clone --recurse-submodules "$url" "$dir"
        fi
        git -C "$dir" checkout "$ref"
        git -C "$dir" submodule update --init --recursive
    }
    clone_dep picotls  "$PICOTLS_REPO"  "$PICOTLS_REF"
    clone_dep picoquic "$PICOQUIC_REPO" "$PICOQUIC_REF"
fi

SOURCE_COMMIT=$(get_git_commit "$SOURCE_DIR")
SOURCE_DIRTY=$(is_git_dirty "$SOURCE_DIR")

###############################################################################
# Docker build — uses libmoq's own Dockerfile
###############################################################################

IMAGE_NAME="moq5-client"

# The interop Dockerfile COPYs picotls/ picoquic/ libmoq/ as SIBLINGS from the
# build context. Two supported layouts:
#   (a) self-contained checkout — SOURCE_DIR vendors picotls/ + picoquic/ inside
#       it (e.g. a fresh `git clone` with submodules).
#   (b) workspace layout — picotls/ + picoquic/ are siblings of the libmoq
#       checkout (e.g. ~/Projects/MoQ/LibMoQ/{libmoq,picotls,picoquic}).
# For (b) we stage a clean, minimal context (source only) so we don't ship the
# multi-GB working tree (build-*/, .git/) to the Docker daemon.
DOCKERFILE_REL="tools/moq-interop-client/Dockerfile"
PARENT_DIR="$(cd "${SOURCE_DIR}/.." && pwd)"

if [[ -d "${SOURCE_DIR}/picotls" && -d "${SOURCE_DIR}/picoquic" ]]; then
    BUILD_CONTEXT="$SOURCE_DIR"
    DOCKERFILE="${SOURCE_DIR}/${DOCKERFILE_REL}"
    log "Self-contained checkout; context: ${BUILD_CONTEXT}"
elif [[ -d "${PARENT_DIR}/picotls" && -d "${PARENT_DIR}/picoquic" ]]; then
    log "Workspace layout detected; staging clean source-only build context"
    STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/libmoq-ctx.XXXXXX")"
    trap 'rm -rf "$STAGE_DIR"' EXIT
    STAGE_EXCLUDES=(--exclude='.git/' --exclude='build*/' --exclude='cmake-build-*/' \
        --exclude='.cache/' --exclude='.build/' --exclude='.deps/' \
        --exclude='node_modules/' --exclude='*.tar.gz')
    # Stage with the exact directory names the Dockerfile COPYs (picotls/picoquic/libmoq).
    rsync -a "${STAGE_EXCLUDES[@]}" "${PARENT_DIR}/picotls/"  "${STAGE_DIR}/picotls/"
    rsync -a "${STAGE_EXCLUDES[@]}" "${PARENT_DIR}/picoquic/" "${STAGE_DIR}/picoquic/"
    rsync -a "${STAGE_EXCLUDES[@]}" "${SOURCE_DIR}/"          "${STAGE_DIR}/libmoq/"
    BUILD_CONTEXT="$STAGE_DIR"
    DOCKERFILE="${STAGE_DIR}/libmoq/${DOCKERFILE_REL}"
    log "Staged context size: $(du -sh "$STAGE_DIR" 2>/dev/null | cut -f1)"
else
    error "Cannot find picotls/ and picoquic/ inside or alongside ${SOURCE_DIR}"
fi

log "Building ${IMAGE_NAME}:latest from libmoq workspace"
docker build -t "${IMAGE_NAME}:latest" \
    -f "${DOCKERFILE}" \
    "${BUILD_CONTEXT}"

# Build adapter image with env-var entrypoint for interop runner
log "Building ${IMAGE_NAME}-interop:latest adapter"
docker build -t "${IMAGE_NAME}-interop:latest" \
    -f "${BUILD_DIR}/Dockerfile.adapter" \
    "${BUILD_DIR}"

###############################################################################
# Provenance
###############################################################################

TIMESTAMP=$(get_timestamp)
RUNNER_COMMIT=$(get_git_commit "$RUNNER_ROOT")

PROVENANCE=$(jq -n \
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

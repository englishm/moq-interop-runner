#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$BUILD_DIR/.sources/moqxr"
REPO="https://github.com/openmoq/moqxr.git"
REF="v0.4.4"
LOCAL=""
REF_SET=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --ref) REF="$2"; REF_SET=true; shift 2 ;;
        --local) LOCAL="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$BUILD_DIR/.sources"
if [ -d "$SOURCE_DIR/.git" ]; then
    if [ -n "$LOCAL" ] &&
       [ "$(git -C "$LOCAL" rev-parse HEAD)" != "$(git -C "$SOURCE_DIR" rev-parse HEAD)" ]; then
        echo "Cached moqxr source differs from $LOCAL; move $SOURCE_DIR aside to change revisions" >&2
        exit 1
    fi
    if [ -z "$LOCAL" ]; then
        cached_repo="$(git -C "$SOURCE_DIR" remote get-url origin)"
        if [ "$REF_SET" = true ]; then
            if [ "$cached_repo" != "$REPO" ]; then
                echo "Cached moqxr source is from $cached_repo, not $REPO" >&2
                exit 1
            fi
            git -C "$SOURCE_DIR" fetch --depth 1 origin "$REF"
            git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
        else
            cached_ref_commit="$(git -C "$SOURCE_DIR" rev-parse "refs/tags/$REF^{commit}" 2>/dev/null || true)"
            if [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$cached_ref_commit" ]; then
                echo "Cached moqxr source is not at $REF; use --ref $REF to refresh" >&2
                exit 1
            fi
        fi
    fi
    echo "Reusing cached source at $SOURCE_DIR"
elif [ -e "$SOURCE_DIR" ]; then
    echo "Source directory exists but is not a Git checkout: $SOURCE_DIR" >&2
    exit 1
elif [ -n "$LOCAL" ]; then
    git clone --no-local "$LOCAL" "$SOURCE_DIR"
    git -C "$SOURCE_DIR" checkout --detach HEAD
else
    git clone --depth 1 --branch "$REF" "$REPO" "$SOURCE_DIR"
fi

echo "Building moqxr test client from $(git -C "$SOURCE_DIR" rev-parse --short HEAD)"
docker build --build-context "moqxr=$SOURCE_DIR" \
    -f "$BUILD_DIR/Dockerfile.client" \
    -t moqxr-interop-client:latest "$BUILD_DIR"

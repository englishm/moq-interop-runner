#!/bin/bash

set -euo pipefail

build_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner_root="$(cd "$build_dir/../.." && pwd)"
sources_dir="$build_dir/.sources"
repo_url="https://github.com/bergstroem/kvick-ai"
ref=""
local_path=""
target="relay"

usage() {
    cat <<'EOF'
Usage: build.sh [--ref REF] [--repo URL] [--local PATH] [--target relay]
EOF
}

while (($# > 0)); do
    case "$1" in
        --ref) ref="${2:?--ref requires a value}"; shift 2 ;;
        --repo) repo_url="${2:?--repo requires a value}"; shift 2 ;;
        --local) local_path="${2:?--local requires a value}"; shift 2 ;;
        --target) target="${2:?--target requires a value}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -n "$local_path" && -n "$ref" ]]; then
    echo "--local and --ref are mutually exclusive" >&2
    exit 2
fi
if [[ "$target" != "relay" ]]; then
    echo "unsupported target: $target" >&2
    exit 2
fi

if [[ -n "$local_path" ]]; then
    source_dir="$(cd "$local_path" && pwd)"
    source_type="local"
else
    ref="${ref:-main}"
    source_dir="$sources_dir/kvick"
    source_type="git"
    mkdir -p "$sources_dir"
    if [[ -e "$source_dir" && ! -d "$source_dir/.git" ]]; then
        echo "source path exists but is not the expected clone: $source_dir" >&2
        exit 2
    fi
    if [[ ! -d "$source_dir/.git" ]]; then
        git clone "$repo_url" "$source_dir"
    else
        existing_url="$(git -C "$source_dir" remote get-url origin)"
        if [[ "$existing_url" != "$repo_url" ]]; then
            echo "source clone remote differs: $existing_url" >&2
            exit 2
        fi
        git -C "$source_dir" fetch origin
    fi
    checkout_ref="$ref"
    if git -C "$source_dir" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
        checkout_ref="origin/$ref"
    fi
    git -C "$source_dir" checkout --detach "$checkout_ref"
fi

source_commit="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || printf unknown)"
source_dirty=false
if [[ -n "$(git -C "$source_dir" status --porcelain 2>/dev/null)" ]]; then
    source_dirty=true
fi

entrypoint_dest="$source_dir/.moq-interop-kvick-entrypoint.sh"
if [[ -e "$entrypoint_dest" ]]; then
    echo "refusing to overwrite $entrypoint_dest" >&2
    exit 2
fi
cleanup() {
    rm -f "$entrypoint_dest"
}
trap cleanup EXIT
cp "$build_dir/entrypoint-relay.sh" "$entrypoint_dest"

docker build \
    -f "$build_dir/Dockerfile.relay" \
    -t kvick-relay:latest \
    "$source_dir"

jq -n \
    --arg implementation kvick \
    --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg runner_commit "$(git -C "$runner_root" rev-parse HEAD 2>/dev/null || printf unknown)" \
    --arg source_type "$source_type" \
    --arg repository "$repo_url" \
    --arg ref "${ref:-local}" \
    --arg local_path "${local_path:-}" \
    --arg commit "$source_commit" \
    --argjson dirty "$source_dirty" \
    '{
      implementation: $implementation,
      timestamp: $timestamp,
      runner_commit: $runner_commit,
      source: {
        type: $source_type,
        repository: $repository,
        ref: $ref,
        local_path: (if $local_path == "" then null else $local_path end),
        commit: $commit,
        dirty: $dirty
      },
      images: [{target: "relay", image: "kvick-relay:latest"}]
    }' | tee "$build_dir/.last-build.json"

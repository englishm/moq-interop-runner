#!/usr/bin/env bash
# Build the Shaka Player browser test client from public sources:
# shaka-player from npm (--ref) and openmoq/moqxr (--moqxr-ref) for the publisher.
# Each image holds one browser and is tagged shaka-player-<browser>-interop-client:
#   --browser chromium|chrome|firefox   (default chromium)
#   --all-browsers                      build all three
#   --platform <p>                      passed to docker build (default: host)
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
REF="5.3.0"
MOQXR_REF="v0.4.4"
MOQXR_LOCAL=""
BROWSERS=(chromium)
PLATFORM=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ref) REF="${2#v}"; shift 2 ;;
        --moqxr-ref) MOQXR_REF="$2"; shift 2 ;;
        --moqxr-local) MOQXR_LOCAL="$2"; shift 2 ;;
        --browser) BROWSERS=("$2"); shift 2 ;;
        --all-browsers) BROWSERS=(chromium chrome firefox); shift ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --target) [ "$2" = client ] || { echo "Only the client target exists" >&2; exit 2; }; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
for browser in "${BROWSERS[@]}"; do
    case "$browser" in
        chromium|chrome|firefox) ;;
        *) echo "Unsupported browser: $browser (expected chromium, chrome or firefox)" >&2; exit 2 ;;
    esac
done

# Commit a tag points at; the peeled "^{}" entry of an annotated tag sorts last.
tag_commit() {
    git ls-remote "$1" "refs/tags/$2" "refs/tags/$2^{}" | tail -1 | cut -f1
}

args=(--build-arg "SHAKA_VERSION=$REF" --build-arg "MOQXR_REF=$MOQXR_REF")
[ -z "$PLATFORM" ] || args+=(--platform "$PLATFORM")
if [ -n "$MOQXR_LOCAL" ]; then
    args+=(--build-context "moqxr-src=$(cd "$MOQXR_LOCAL" && pwd)")
    moqxr_commit="$(git -C "$MOQXR_LOCAL" rev-parse HEAD)"
else
    moqxr_commit="$(tag_commit https://github.com/openmoq/moqxr.git "$MOQXR_REF")"
fi
shaka_commit="$(tag_commit https://github.com/shaka-project/shaka-player.git "v$REF")"

images=()
for browser in "${BROWSERS[@]}"; do
    image="shaka-player-$browser-interop-client:latest"
    echo "Building $image (shaka-player $REF, moqxr $MOQXR_REF)"
    docker build "${args[@]}" --build-arg "BROWSER=$browser" \
        -f "$BUILD_DIR/Dockerfile.client" -t "$image" "$BUILD_DIR"
    images+=("$image")
done

jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg runner "$(git -C "$RUNNER_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)" \
    --arg ref "$REF" --arg commit "${shaka_commit:-unknown}" \
    --arg moqxr_ref "$MOQXR_REF" --arg moqxr_commit "${moqxr_commit:-unknown}" \
    --arg moqxr_local "$MOQXR_LOCAL" \
    --args '{
        implementation: "shaka-player",
        timestamp: $ts,
        runner_commit: $runner,
        source: {
            type: "npm",
            repository: "https://github.com/shaka-project/shaka-player",
            ref: $ref,
            local_path: null,
            commit: $commit,
            dirty: false
        },
        components: {
            moqxr: {
                repository: "https://github.com/openmoq/moqxr",
                ref: $moqxr_ref,
                local_path: (if $moqxr_local == "" then null else $moqxr_local end),
                commit: $moqxr_commit
            }
        },
        images: [$ARGS.positional[] | { target: "client", image: . }]
    }' "${images[@]}" > "$BUILD_DIR/.last-build.json"
cat "$BUILD_DIR/.last-build.json"

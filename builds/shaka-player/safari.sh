#!/usr/bin/env bash
# Run the Shaka Player client in the host's Safari (macOS only; Safari has no
# headless mode, so a window opens). Safari is driven over WebDriver by
# client.mjs; the moqxr publisher runs from a shaka-player client image.
#
# Prerequisites: `sudo safaridriver --enable`, Safari > Develop > Allow Remote
# Automation, Node 18+, Docker, and a built image (./build.sh).
#
# Environment:
#   RELAY_URL            relay for Safari (default https://localhost:4443)
#   PUBLISHER_NETWORK    docker network for the publisher container (default
#                        "host" for a localhost relay, so it reaches a relay
#                        published from the Docker VM; else Docker's default).
#                        Or join a compose relay's network, e.g.
#                        PUBLISHER_NETWORK=<project>_default
#                        PUBLISHER_RELAY_URL=https://relay:4443
#                        For a relay running natively on macOS use
#                        PUBLISHER_NETWORK=bridge with host.docker.internal.
#                        Colima does not forward UDP ports to macOS, so Safari
#                        cannot reach a relay in Colima; Docker Desktop does.
#   PUBLISHER_RELAY_URL  relay for the publisher (default: RELAY_URL)
#   TLS_DISABLE_VERIFY   pin CERT_PATH via serverCertificateHashes and run the
#                        publisher --insecure (default 1 for localhost, else 0)
#   CERT_PATH            relay certificate (default <runner>/certs/cert.pem)
#   PUBLISHER_IMAGE      image holding /app/openmoq-publisher
#                        (default shaka-player-chromium-interop-client:latest)
#   MOQ_CLIENT_VERSION, TESTCASE, VERBOSE, MOQXR_PACKAGING  passed to client.mjs
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
# builds/*/.sources/ is gitignored.
CACHE_DIR="$BUILD_DIR/.sources/safari"

if [ "$(uname -s)" != Darwin ]; then
    echo "safari.sh needs macOS with Safari" >&2
    exit 2
fi
command -v node >/dev/null || { echo "node is required" >&2; exit 2; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }

# Same Shaka version as the Docker images.
SHAKA_VERSION="${SHAKA_VERSION:-$(sed -n 's/^ARG SHAKA_VERSION=//p' "$BUILD_DIR/Dockerfile.client")}"
installed="$(node -p "require('$CACHE_DIR/node_modules/shaka-player/package.json').version" 2>/dev/null || true)"
if [ "$installed" != "$SHAKA_VERSION" ]; then
    echo "Installing shaka-player@$SHAKA_VERSION into $CACHE_DIR" >&2
    mkdir -p "$CACHE_DIR"
    npm install --prefix "$CACHE_DIR" --no-fund --no-audit --no-save --loglevel=error \
        "shaka-player@$SHAKA_VERSION" >&2
fi

PUBLISHER_IMAGE="${PUBLISHER_IMAGE:-shaka-player-chromium-interop-client:latest}"
if ! docker image inspect "$PUBLISHER_IMAGE" >/dev/null 2>&1; then
    echo "Publisher image $PUBLISHER_IMAGE not found; build it with $BUILD_DIR/build.sh" >&2
    exit 2
fi

RELAY_URL="${RELAY_URL:-https://localhost:4443}"
relay_host="$(node -p "new URL(process.argv[1]).hostname" "$RELAY_URL")"
case "$relay_host" in
    localhost|127.0.0.1|'[::1]') local_relay=1 ;;
    *) local_relay=0 ;;
esac
if [ "$local_relay" = 1 ]; then
    export PUBLISHER_NETWORK="${PUBLISHER_NETWORK:-host}"
fi
export RELAY_URL
export PUBLISHER_RELAY_URL="${PUBLISHER_RELAY_URL:-$RELAY_URL}"
export TLS_DISABLE_VERIFY="${TLS_DISABLE_VERIFY:-$local_relay}"
export CERT_PATH="${CERT_PATH:-$RUNNER_ROOT/certs/cert.pem}"
export BROWSER=safari
export SHAKA_APP_DIR="$BUILD_DIR"
export SHAKA_DIST="$CACHE_DIR/node_modules/shaka-player/dist"
export MOQXR_FIXTURE=/app/fixture.mp4
export MOQXR_BIN="$BUILD_DIR/safari-publisher.sh"
export PUBLISHER_IMAGE
# Tags this run's publisher containers so they are removed even if the
# wrapper is killed without a chance to clean up.
export SAFARI_RUN_LABEL="shaka-safari-run=$$"

cleanup() {
    docker ps -aq --filter "label=$SAFARI_RUN_LABEL" | xargs docker rm -f >/dev/null 2>&1 || true
}
trap cleanup EXIT

node "$BUILD_DIR/client.mjs" "$@"

#!/bin/bash
# Install a pinned, repository-local container toolchain for macOS/Apple Silicon.
# No root privileges or global shell-profile changes are required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_ROOT="$RUNNER_ROOT/.local-tools"
BIN_DIR="$TOOLS_ROOT/bin"
LIMA_DIR="$TOOLS_ROOT/lima"
DOCKER_CONFIG_DIR="$TOOLS_ROOT/docker"
COMPOSE_PLUGIN_DIR="$DOCKER_CONFIG_DIR/cli-plugins"

COLIMA_VERSION="0.10.3"
COLIMA_SHA256="980ad8bf61a4ca370243f4cb41401a61276dcd2c2502bee7b9b86f9250169f34"
LIMA_VERSION="2.1.4"
LIMA_SHA256="14c5b283f1c5eb4078e5a300b8d241f69197a3e41326dfc685a69c9455917acf"
DOCKER_VERSION="29.6.2"
DOCKER_SHA256="86f86ad4b2119ec55aa50224f15ceb4c94a198f8ae153bb32318d7da589749da"
COMPOSE_VERSION="5.3.1"
COMPOSE_SHA256="32691ba1196d819fa68cbdc0aad9a5569e730a35ae40c6fdd8458110ecd69488"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "This bootstrap currently supports macOS on Apple Silicon only." >&2
    echo "Install Docker with Compose for this platform, then use the normal make targets." >&2
    exit 1
fi

for dependency in curl shasum tar; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "Missing required host command: $dependency" >&2
        exit 1
    fi
done

mkdir -p "$BIN_DIR" "$LIMA_DIR" "$COMPOSE_PLUGIN_DIR"

versions_match=false
if [ -f "$TOOLS_ROOT/versions" ]; then
    expected_versions=$(printf '%s\n' \
        "colima=$COLIMA_VERSION" \
        "lima=$LIMA_VERSION" \
        "docker=$DOCKER_VERSION" \
        "compose=$COMPOSE_VERSION")
    actual_versions=$(sed -n '1,4p' "$TOOLS_ROOT/versions")
    if [ "$actual_versions" = "$expected_versions" ] && \
       [ -x "$BIN_DIR/colima" ] && \
       [ -x "$LIMA_DIR/bin/limactl" ] && \
       [ -x "$BIN_DIR/docker" ] && \
       [ -x "$COMPOSE_PLUGIN_DIR/docker-compose" ]; then
        versions_match=true
    fi
fi

if [ "$versions_match" = true ]; then
    echo "Repository-local container toolchain is already installed."
    "$SCRIPT_DIR/local-container-env.sh" colima version
    "$SCRIPT_DIR/local-container-env.sh" docker --version
    "$SCRIPT_DIR/local-container-env.sh" docker compose version
    exit 0
fi

DOWNLOAD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/moq-container-tools.XXXXXX")
cleanup() {
    rm -rf "$DOWNLOAD_DIR"
}
trap cleanup EXIT

download_and_verify() {
    local url="$1"
    local destination="$2"
    local expected_sha="$3"

    echo "Downloading $url"
    curl --fail --location --retry 3 --output "$destination" "$url"
    local actual_sha
    actual_sha=$(shasum -a 256 "$destination" | awk '{print $1}')
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "SHA-256 mismatch for $url" >&2
        echo "  expected: $expected_sha" >&2
        echo "  actual:   $actual_sha" >&2
        exit 1
    fi
}

download_and_verify \
    "https://github.com/abiosoft/colima/releases/download/v${COLIMA_VERSION}/colima-Darwin-arm64" \
    "$DOWNLOAD_DIR/colima" "$COLIMA_SHA256"
download_and_verify \
    "https://github.com/lima-vm/lima/releases/download/v${LIMA_VERSION}/lima-${LIMA_VERSION}-Darwin-arm64.tar.gz" \
    "$DOWNLOAD_DIR/lima.tar.gz" "$LIMA_SHA256"
download_and_verify \
    "https://download.docker.com/mac/static/stable/aarch64/docker-${DOCKER_VERSION}.tgz" \
    "$DOWNLOAD_DIR/docker.tgz" "$DOCKER_SHA256"
download_and_verify \
    "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-darwin-aarch64" \
    "$DOWNLOAD_DIR/docker-compose" "$COMPOSE_SHA256"

install -m 0755 "$DOWNLOAD_DIR/colima" "$BIN_DIR/colima"
tar -xzf "$DOWNLOAD_DIR/lima.tar.gz" -C "$LIMA_DIR"
tar -xzf "$DOWNLOAD_DIR/docker.tgz" -C "$DOWNLOAD_DIR"
install -m 0755 "$DOWNLOAD_DIR/docker/docker" "$BIN_DIR/docker"
install -m 0755 "$DOWNLOAD_DIR/docker-compose" "$COMPOSE_PLUGIN_DIR/docker-compose"

printf '%s\n' \
    "colima=$COLIMA_VERSION" \
    "lima=$LIMA_VERSION" \
    "docker=$DOCKER_VERSION" \
    "compose=$COMPOSE_VERSION" > "$TOOLS_ROOT/versions"

echo "Installed repository-local container toolchain:"
"$SCRIPT_DIR/local-container-env.sh" colima version
"$SCRIPT_DIR/local-container-env.sh" docker --version
"$SCRIPT_DIR/local-container-env.sh" docker compose version
echo "Start it with: make local-runtime-start"

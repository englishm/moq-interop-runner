#!/bin/bash
# Run a command with the repository-local Colima/Docker toolchain.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_ROOT="$RUNNER_ROOT/.local-tools"
# Lima embeds its state path in a Unix socket name. A short stable symlink
# is not sufficient because Lima resolves symlinks. Keep only VM state in a
# short per-user location; all downloaded tools and caches remain in the repo.
COLIMA_HOME_PATH="${MOQT_COLIMA_HOME:-/Users/$(id -un)/.moq-interop-colima}"

export PATH="$TOOLS_ROOT/bin:$TOOLS_ROOT/lima/bin:$PATH"
export COLIMA_HOME="$COLIMA_HOME_PATH"
export COLIMA_CACHE_HOME="$TOOLS_ROOT/cache"
export LIMA_HOME="$COLIMA_HOME/_lima"
export DOCKER_CONFIG="$TOOLS_ROOT/docker"

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 COMMAND [ARG ...]" >&2
    exit 2
fi

exec "$@"

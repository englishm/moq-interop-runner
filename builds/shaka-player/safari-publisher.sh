#!/usr/bin/env bash
# MOQXR_BIN wrapper used by safari.sh: runs openmoq-publisher from
# PUBLISHER_IMAGE, on PUBLISHER_NETWORK when set. SIGTERM/SIGINT remove the
# container.
set -uo pipefail

name="shaka-safari-publisher-$$"
args=(--rm --init --name "$name")
[ -z "${SAFARI_RUN_LABEL:-}" ] || args+=(--label "$SAFARI_RUN_LABEL")
if [ -n "${PUBLISHER_NETWORK:-}" ]; then
    args+=(--network "$PUBLISHER_NETWORK")
fi
[ "${PUBLISHER_NETWORK:-}" = host ] || args+=(--add-host=host.docker.internal:host-gateway)
docker run "${args[@]}" --entrypoint /app/openmoq-publisher \
    "${PUBLISHER_IMAGE:-shaka-player-chromium-interop-client:latest}" "$@" &
pid=$!
trap 'docker rm -f "$name" >/dev/null 2>&1; wait "$pid"; exit 143' TERM INT
wait "$pid"

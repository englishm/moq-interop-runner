#!/bin/bash
# Translates interop runner env vars to libmoq's CLI args
set -euo pipefail

declare -a ARGS=()

if [ -n "${RELAY_URL:-}" ]; then
    ARGS+=("--relay" "$RELAY_URL")
fi

if [ -n "${TESTCASE:-}" ]; then
    ARGS+=("--test" "$TESTCASE")
else
    ARGS+=("--test" "setup-only")
fi

if [ "${TLS_DISABLE_VERIFY:-}" = "1" ] || [ "${TLS_DISABLE_VERIFY:-}" = "true" ]; then
    ARGS+=("--tls-disable-verify")
fi

if [ "${VERBOSE:-}" = "1" ] || [ "${VERBOSE:-}" = "true" ]; then
    ARGS+=("--verbose")
fi

exec moq-interop-client ${ARGS[@]+"${ARGS[@]}"}

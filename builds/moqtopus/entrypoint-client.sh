#!/bin/bash

set -euo pipefail

ARGS=()

if [ -n "${RELAY_URL:-}" ]; then
    ARGS+=(--relay "$RELAY_URL")
fi

if [ -n "${TESTCASE:-}" ]; then
    ARGS+=(--test "$TESTCASE")
fi

if [ "${TLS_DISABLE_VERIFY:-}" = "1" ] || [ "${TLS_DISABLE_VERIFY:-}" = "true" ]; then
    ARGS+=(--tls-disable-verify)
fi

if [ "${VERBOSE:-}" = "1" ] || [ "${VERBOSE:-}" = "true" ]; then
    ARGS+=(--verbose)
fi

exec /app/moqtopus-interop-client "${ARGS[@]}"

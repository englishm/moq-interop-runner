#!/bin/bash
# entrypoint-client.sh - Wrapper script for moq-test-client
# Translates standard MoQT interop environment variables to moq-test-client CLI
#
# Expected environment:
#   RELAY_URL          - URL of relay to test against (required)
#   TESTCASE           - Specific test case to run (optional, runs all if not set)
#   TLS_DISABLE_VERIFY - Set to 1 or true to disable TLS verification
#   VERBOSE            - Set to 1 or true for verbose output
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Build command line arguments from environment variables
declare -a ARGS=()

if [ -n "${RELAY_URL:-}" ]; then
    ARGS+=("--relay" "$RELAY_URL")
fi

if [ -n "${TESTCASE:-}" ]; then
    ARGS+=("--test" "$TESTCASE")
fi

if [ "${TLS_DISABLE_VERIFY:-}" = "1" ] || [ "${TLS_DISABLE_VERIFY:-}" = "true" ]; then
    ARGS+=("--tls-disable-verify")
fi

if [ "${VERBOSE:-}" = "1" ] || [ "${VERBOSE:-}" = "true" ]; then
    ARGS+=("--verbose")
fi

# Use ${ARGS[@]+"${ARGS[@]}"} for safe empty array handling
exec /app/moq-test-client ${ARGS[@]+"${ARGS[@]}"}

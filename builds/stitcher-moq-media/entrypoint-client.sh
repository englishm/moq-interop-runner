#!/bin/bash
# entrypoint-client.sh - Wrapper script for stitcher-moq-media-client
# Translates standard MoQT interop environment variables to CLI arguments
#
# Expected environment:
#   RELAY_URL          - URL of relay to test against (required)
#   TESTCASE           - Specific test case to run (optional, runs all if not set)
#   TLS_DISABLE_VERIFY - Set to 1 or true to disable TLS verification
#   VERBOSE            - Set to 1 or true for verbose output (tracing on stderr)
#   MOQ_CLIENT_VERSION - Comma-separated versions to offer (optional; default drafts 22-18)
#   MEDIA_FIXTURE_DIR  - Fixture directory (default /app/fixture, baked into the image)
#   MEDIA_IDLE_SECS    - Idle period of cmsf-late-join-idle-catalog (default 70)
#   MEDIA_RUN_ID       - Override the random run identifier (debugging)
#
# The MOQ_* and MEDIA_* variables are read by the binary itself.
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   127 - Test not supported by this client

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
exec /app/stitcher-moq-media-client ${ARGS[@]+"${ARGS[@]}"}

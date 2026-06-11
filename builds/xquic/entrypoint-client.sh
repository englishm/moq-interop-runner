#!/bin/bash
# entrypoint-client.sh - Wrapper for xquic MoQ interop test client
#
# Translates standard MoQT interop environment variables to CLI arguments.
#
# Environment variables:
#   RELAY_URL          - moqt://host:port (required)
#   TESTCASE           - Test case name (required)
#   TLS_DISABLE_VERIFY - "1" or "true" to skip cert verification
#   VERBOSE            - "1" or "true" for debug output
#
# Supported test cases:
#   setup-only, announce-only, subscribe-error,
#   announce-subscribe, subscribe-before-announce, publish-namespace-done
#
# Exit codes:
#   0   - Test passed
#   1   - Test failed
#   127 - Unsupported test case

set -euo pipefail

# Resolve hostname via DNS-over-HTTPS to bypass DNS pollution.
# Adds result to /etc/hosts so getaddrinfo() in the client picks it up.
resolve_via_doh() {
    local host="$1"
    # Skip if already an IP address
    if echo "$host" | grep -qP '^\d+\.\d+\.\d+\.\d+$'; then
        return
    fi
    local ip=""
    # Try Cloudflare DoH first, then Google DoH as fallback
    ip=$(curl -sf --max-time 5 "https://1.1.1.1/dns-query?name=${host}&type=A" \
         -H "Accept: application/dns-json" \
         | sed -n 's/.*"data":"\([0-9.]*\)".*/\1/p' | tail -1) || true
    if [ -z "$ip" ]; then
        ip=$(curl -sf --max-time 5 "https://dns.google/resolve?name=${host}&type=A" \
             | sed -n 's/.*"data":"\([0-9.]*\)".*/\1/p' | tail -1) || true
    fi
    if [ -n "$ip" ]; then
        echo "$ip $host" >> /etc/hosts
    fi
}

# Extract hostname from RELAY_URL and resolve it
if [ -n "${RELAY_URL:-}" ]; then
    relay_host=$(echo "$RELAY_URL" | sed -n 's|^moqt://\([^:/]*\).*|\1|p')
    if [ -n "$relay_host" ]; then
        resolve_via_doh "$relay_host"
    fi
fi

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

exec /app/moq_interop_client "${ARGS[@]}"

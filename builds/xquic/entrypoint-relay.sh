#!/bin/bash
# entrypoint-relay.sh - Wrapper script for xquic MoQ relay (moq_demo_server)
# Translates standard MoQT interop environment variables to xquic CLI arguments
#
# Expected environment:
#   MOQT_ROLE     - Role to run: relay (only relay supported)
#   MOQT_PORT     - Port to listen on (default: 4443)
#   MOQT_CERT     - Path to TLS certificate (default: /certs/cert.pem)
#   MOQT_KEY      - Path to TLS private key (default: /certs/priv.key)
#   MOQT_DRAFT    - Draft version: "14" for draft-14 (default: 14)
#   MOQT_LOG      - Log level: e/w/i/d (default: d)
#
# Expected mounts:
#   /certs/cert.pem - TLS certificate
#   /certs/priv.key - TLS private key
#
# Exit codes:
#   0   - Clean shutdown
#   1   - Configuration error
#   127 - Unsupported role

set -euo pipefail

ROLE="${MOQT_ROLE:-relay}"
PORT="${MOQT_PORT:-4443}"
CERT="${MOQT_CERT:-/certs/cert.pem}"
KEY="${MOQT_KEY:-/certs/priv.key}"
DRAFT="${MOQT_DRAFT:-14}"
LOG_LEVEL="${MOQT_LOG:-d}"

case "$ROLE" in
  relay)
    echo "Starting xquic MoQ relay on port $PORT"
    echo "  Cert:  $CERT"
    echo "  Key:   $KEY"
    echo "  Draft: $DRAFT"

    if [ ! -f "$CERT" ]; then
      echo "ERROR: Certificate not found at $CERT" >&2
      echo "Make sure /certs is mounted with cert.pem and priv.key" >&2
      exit 1
    fi
    if [ ! -f "$KEY" ]; then
      echo "ERROR: Private key not found at $KEY" >&2
      exit 1
    fi

    # xquic expects server.crt and server.key in CWD.
    # Copy to /tmp since the container may run as non-root without
    # write access to /app.
    cp "$CERT" /tmp/server.crt
    cp "$KEY"  /tmp/server.key
    cd /tmp

    # Build CLI arguments
    ARGS="-p $PORT -l $LOG_LEVEL"

    # Enable draft-14 mode (CLIENT_SETUP/SERVER_SETUP v14)
    if [ "$DRAFT" = "14" ]; then
      ARGS="$ARGS -V"
    fi

    echo "  Command: /app/moq_demo_relay_v14 $ARGS"
    # shellcheck disable=SC2086
    exec /app/moq_demo_relay_v14 $ARGS
    ;;

  *)
    echo "Role '$ROLE' not supported by xquic adapter" >&2
    echo "Supported roles: relay" >&2
    exit 127
    ;;
esac

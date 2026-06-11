#!/bin/bash
# entrypoint-relay.sh - Wrapper script for moq-rs relay
# Translates standard MoQT interop environment variables to moq-relay-ietf CLI
#
# Expected environment:
#   MOQT_ROLE     - Role to run: relay (required, only relay supported)
#   MOQT_PORT     - Port to listen on (default: 4443)
#   MOQT_CERT     - Path to TLS certificate (default: /certs/cert.pem)
#   MOQT_KEY      - Path to TLS private key (default: /certs/priv.key)
#   MOQT_MLOG_DIR - Directory for mlog files (default: /mlog)
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
MLOG_DIR="${MOQT_MLOG_DIR:-/mlog}"

case "$ROLE" in
  relay)
    echo "Starting moq-rs relay on port $PORT"
    echo "  Cert: $CERT"
    echo "  Key:  $KEY"
    echo "  Mlog: $MLOG_DIR"

    if [ ! -f "$CERT" ]; then
      echo "ERROR: Certificate not found at $CERT" >&2
      echo "Make sure /certs is mounted with cert.pem and priv.key" >&2
      exit 1
    fi
    if [ ! -f "$KEY" ]; then
      echo "ERROR: Private key not found at $KEY" >&2
      exit 1
    fi

    exec /app/moq-relay-ietf \
      --bind "0.0.0.0:$PORT" \
      --tls-cert "$CERT" \
      --tls-key "$KEY" \
      --mlog-dir "$MLOG_DIR"
    ;;

  *)
    echo "Role '$ROLE' not supported by moq-rs adapter" >&2
    echo "Supported roles: relay" >&2
    exit 127
    ;;
esac

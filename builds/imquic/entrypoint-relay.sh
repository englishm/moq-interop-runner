#!/bin/bash
# entrypoint-relay.sh - Wrapper script for imquic-moq-relay
# Translates standard MoQT interop environment variables to imquic-moq-relay CLI
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
    echo "Starting imquic-moq-relay on port $PORT"
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

    exec /app/imquic-moq-relay \
      -p "$PORT" -q -w \
      -c "$CERT" \
      -k "$KEY" \
      -Q "$MLOG_DIR" -J -l quic -l http3 -l moq
    ;;

  *)
    echo "Role '$ROLE' not supported by imquic adapter" >&2
    echo "Supported roles: relay" >&2
    exit 127
    ;;
esac

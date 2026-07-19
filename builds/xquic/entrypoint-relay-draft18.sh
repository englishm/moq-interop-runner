#!/bin/bash
# Run the xquic demo server as a draft-18 raw-QUIC interop relay.

set -euo pipefail

ROLE="${MOQT_ROLE:-relay}"
PORT="${MOQT_PORT:-4443}"
CERT="${MOQT_CERT:-/certs/cert.pem}"
KEY="${MOQT_KEY:-/certs/priv.key}"
LOG_LEVEL="${MOQT_LOG:-d}"

if [ "$ROLE" != "relay" ]; then
    echo "Role '$ROLE' not supported by the xquic draft-18 image" >&2
    exit 127
fi
if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
    echo "TLS certificate/key not found: $CERT / $KEY" >&2
    exit 1
fi

cp "$CERT" /tmp/server.crt
cp "$KEY" /tmp/server.key
cd /tmp

echo "Starting xquic draft-18 MoQ relay on UDP port $PORT"
exec /app/moq_demo_server -p "$PORT" -l "$LOG_LEVEL" -I

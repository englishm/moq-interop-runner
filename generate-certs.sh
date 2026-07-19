#!/bin/bash
# Generate TLS certificates for interop testing
# Following QUIC interop runner convention: /certs/cert.pem and /certs/priv.key
#
# Exit codes:
#   0 - Success
#   1 - Error generating certificates

set -euo pipefail

# Check dependencies
if ! command -v openssl &> /dev/null; then
    echo "Error: openssl is required but not installed" >&2
    exit 1
fi

CERTS_DIR="${1:-./certs}"

mkdir -p "$CERTS_DIR"

# Generate self-signed cert valid for localhost, relay hostname, and common test hostnames.
#
# ECDSA P-256 with a short (10-day) validity so the cert satisfies the WebTransport
# `serverCertificateHashes` policy (ECDSA key + <=14-day validity), letting browser
# and node/bun clients pin it by hash without a trusted CA.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$CERTS_DIR/priv.key" \
    -out "$CERTS_DIR/cert.pem" \
    -days 10 -nodes \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,DNS:relay,DNS:moq-relay,IP:127.0.0.1"

# These are ephemeral self-signed test certs, not production secrets.
# Use 644 so Docker containers running as a different UID can read them.
chmod 644 "$CERTS_DIR/priv.key"
chmod 644 "$CERTS_DIR/cert.pem"

echo "Generated certificates in $CERTS_DIR:"
echo "  - $CERTS_DIR/cert.pem (644)"
echo "  - $CERTS_DIR/priv.key (644)"

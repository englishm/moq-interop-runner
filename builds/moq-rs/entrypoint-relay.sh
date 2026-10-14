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
#   MOQT_SCOPE_CONFIG - Optional. Path to a CAT scope-config JSON file, e.g.
#                   /config/scope.json. When set, it's passed to the relay as
#                   --scope-config and the relay enforces CAT bearer tokens as
#                   configured. When unset, the relay runs without CAT, as before.
#                   Requires a moq-rs ref that has --scope-config and the
#                   auth-cat feature (the image enables it when available).
#
# Expected mounts:
#   /certs/cert.pem - TLS certificate
#   /certs/priv.key - TLS private key
#   /config/        - Only with MOQT_SCOPE_CONFIG: the scope-config JSON plus
#                     any pem_file it references (relative paths resolve
#                     against the config file's directory). Mount read-only;
#                     the files must be readable by uid 1000. Public keys only.
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
SCOPE_CONFIG="${MOQT_SCOPE_CONFIG:-}"

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

    RELAY_ARGS=(
      --bind "0.0.0.0:$PORT"
      --tls-cert "$CERT"
      --tls-key "$KEY"
      --mlog-dir "$MLOG_DIR"
    )

    if [ -n "$SCOPE_CONFIG" ]; then
      echo "  Scope config: $SCOPE_CONFIG"
      if [ ! -f "$SCOPE_CONFIG" ]; then
        echo "ERROR: MOQT_SCOPE_CONFIG is set but $SCOPE_CONFIG does not exist" >&2
        echo "Mount the scope-config JSON (and any pem_file it references), e.g. -v \"\$PWD/cat:/config:ro\"" >&2
        exit 1
      fi
      if [ ! -r "$SCOPE_CONFIG" ]; then
        echo "ERROR: $SCOPE_CONFIG is not readable by uid $(id -u)" >&2
        exit 1
      fi
      RELAY_HELP="$(/app/moq-relay-ietf --help 2>&1 || true)"
      if ! grep -q -- '--scope-config' <<<"$RELAY_HELP"; then
        echo "ERROR: MOQT_SCOPE_CONFIG is set but this moq-relay-ietf build has no --scope-config flag" >&2
        echo "Rebuild the image from a moq-rs ref that includes the scope-config change" >&2
        exit 1
      fi
      RELAY_ARGS+=(--scope-config "$SCOPE_CONFIG")
    fi

    exec /app/moq-relay-ietf "${RELAY_ARGS[@]}"
    ;;

  *)
    echo "Role '$ROLE' not supported by moq-rs adapter" >&2
    echo "Supported roles: relay" >&2
    exit 127
    ;;
esac

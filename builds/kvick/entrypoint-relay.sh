#!/bin/bash

set -euo pipefail

relay_bin="${KVICK_RELAY_BIN:-/app/moq-relay}"
relay_config="${KVICK_RELAY_CONFIG:-/tmp/kvick-relay.toml}"
port="${MOQT_PORT:-4443}"
cert="${MOQT_CERT:-/certs/cert.pem}"
key="${MOQT_KEY:-/certs/priv.key}"

if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    echo "invalid MOQT_PORT: $port" >&2
    exit 2
fi

cat > "$relay_config" <<EOF
[server]
bind = "0.0.0.0:$port"
max_connections = 64

[tls]
cert = "$cert"
key = "$key"

[namespace]
[namespace.""]
mode = "origin"

[cache]
# #3827 experiment lever: preserve delayed publication while beating strict
# external subscribe-error deadlines. The product default remains 2000 ms.
unknown_track_subscribe_grace_ms = 750

[auth]
mode = "allow_all"
EOF

exec "$relay_bin" --config "$relay_config"

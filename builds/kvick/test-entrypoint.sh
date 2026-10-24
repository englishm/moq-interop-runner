#!/bin/bash

set -euo pipefail

build_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(stat -c '%a' "$build_dir/entrypoint-relay.sh")" == "755" ]]
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fake_relay="$tmp_dir/fake-relay"
config="$tmp_dir/relay.toml"
args="$tmp_dir/args"

printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$@" > "$KVICK_TEST_ARGS"' > "$fake_relay"
chmod +x "$fake_relay"

KVICK_RELAY_BIN="$fake_relay" \
KVICK_RELAY_CONFIG="$config" \
KVICK_TEST_ARGS="$args" \
MOQT_PORT=5443 \
MOQT_CERT=/certs/test-cert.pem \
MOQT_KEY=/certs/test-key.pem \
    "$build_dir/entrypoint-relay.sh"

grep -Fq 'bind = "0.0.0.0:5443"' "$config"
grep -Fq 'cert = "/certs/test-cert.pem"' "$config"
grep -Fq 'key = "/certs/test-key.pem"' "$config"
grep -Fq '[namespace.""]' "$config"
grep -Fq 'unknown_track_subscribe_grace_ms = 750' "$config"
grep -Fxq -- '--config' "$args"
grep -Fxq -- "$config" "$args"

#!/bin/sh
# Forward every client's UDP flow to the relay. TLS and MoQT pass through
# untouched, so the relay's certificate and the client's URL are what they
# would be without the proxy. Each client address gets its own forked socat;
# -T ends it after 30 s without traffic.
set -eu

: "${MOQT_PORT:=4443}"
: "${MOQT_UPSTREAM_HOST:?MOQT_UPSTREAM_HOST is required}"
: "${MOQT_UPSTREAM_PORT:=4443}"

echo "udp-forward: :$MOQT_PORT -> $MOQT_UPSTREAM_HOST:$MOQT_UPSTREAM_PORT (draft ${MOQT_DRAFT:-unset})" >&2
exec socat -d -T 30 "UDP4-LISTEN:$MOQT_PORT,fork,reuseaddr" "UDP4:$MOQT_UPSTREAM_HOST:$MOQT_UPSTREAM_PORT"

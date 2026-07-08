#!/bin/bash
# Reproduce the aiomoqt WebTransport relay SIGSEGV and capture a native stack trace.
#
# Drives the aiomoqt WT relay (under gdb) with an interop client that triggers the
# crash on SUBSCRIBE. Default client = moxygen (crashes earliest, at test 3).
# Reuses the standard docker-compose.test.yml so the setup matches the real run.
#
# Usage: debug/aiomoqt-wt-segfault/run.sh [OUTDIR] [CLIENT_IMAGE]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

OUT="${1:-/tmp/aiomoqt-wt-segfault}"
CLIENT_IMAGE="${2:-ghcr.io/facebookexperimental/moxygen-interop-client:latest-amd64}"
DEBUG_MODE="${DEBUG_MODE:-gdb}"   # gdb (native bt) | valgrind (use-after-free + free site)
mkdir -p "$OUT"

echo "== certs =="
[ -f certs/cert.pem ] || ./generate-certs.sh ./certs

echo "== build debug relay (aiomoqt WT + gdb) =="
docker build -t aiomoqt-relay-wtdebug -f "$HERE/Dockerfile.relay-debug" "$HERE"

echo "== pull trigger client: $CLIENT_IMAGE =="
docker pull "$CLIENT_IMAGE" || echo "(pull failed; assuming present locally)"

echo "== run ($DEBUG_MODE): $CLIENT_IMAGE  ->  aiomoqt WT relay =="
RELAY_ENVFILE="$OUT/relay.env"
printf 'DEBUG_MODE=%s\n' "$DEBUG_MODE" > "$RELAY_ENVFILE"   # consumed via env_file passthrough
RELAY_IMAGE="aiomoqt-relay-wtdebug" \
CLIENT_IMAGE="$CLIENT_IMAGE" \
RELAY_URL="https://relay:4443" \
PINNED_RELAY_ENV_FILE="$RELAY_ENVFILE" \
TEST_TIMEOUT="${TEST_TIMEOUT:-180}" \
  docker compose -f docker-compose.test.yml up --abort-on-container-exit \
  > "$OUT/run.log" 2>&1 || true
docker compose -f docker-compose.test.yml down -v >/dev/null 2>&1 || true

echo "== extract stack trace =="
# Strip the compose "relay-1 | " prefix.
strip() { sed -E 's/^[a-z0-9_-]+ +\| ?//'; }
{
  echo "### aiomoqt WebTransport relay crash — captured ($DEBUG_MODE)"
  echo "client:  $CLIENT_IMAGE"
  echo
  if [ "$DEBUG_MODE" = "valgrind" ]; then
    echo "--- valgrind: first invalid access (read stack + FREE'd-by + alloc'd-at) ---"
    strip < "$OUT/run.log" | awk '/Invalid (read|write)/{f=1} f{print; if(++n>60) exit}'
  else
    echo "--- crash marker ---"
    grep -iE 'received signal SIGSEGV|exited with code|Fatal Python' "$OUT/run.log" | strip | head
    echo
    echo "--- faulting-thread native backtrace ---"
    sed -n '/received signal SIGSEGV/,/=== ALL THREADS ===/p' "$OUT/run.log" | strip | grep -E '^#[0-9]+ |signal SIGSEGV'
  fi
  echo
  echo "(full output in run.log)"
} | tee "$OUT/stacktrace.txt"

echo
echo "== done =="
echo "  full log:   $OUT/run.log"
echo "  stacktrace: $OUT/stacktrace.txt"

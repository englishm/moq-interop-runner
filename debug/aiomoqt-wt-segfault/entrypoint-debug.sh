#!/bin/sh
# Debug entrypoint for the aiomoqt WebTransport relay SIGSEGV.
# Mirrors the upstream relay command (docker-entrypoint.sh relay branch).
#
# DEBUG_MODE=gdb      (default) run under gdb -> native backtrace at the crash.
# DEBUG_MODE=valgrind          run under valgrind memcheck -> reports the INVALID
#                              READ with the FREE backtrace (the "who freed it"
#                              site), to confirm a use-after-free from a changed
#                              picoquic WT free requirement.
set -u
export PYTHONFAULTHANDLER=1 PYTHONMALLOC=malloc
ulimit -c unlimited 2>/dev/null || true

set -- python -m aiomoqt.examples.moq_interop_relay \
  --bind "${MOQT_BIND:-0.0.0.0}" \
  --port "${MOQT_PORT:-4443}" \
  --cert "${MOQT_CERT:-/certs/cert.pem}" \
  --key  "${MOQT_KEY:-/certs/priv.key}"
[ -n "${MOQT_QUIC:-}" ]  && set -- "$@" --quic
[ -n "${MOQT_DRAFT:-}" ] && set -- "$@" --draft "${MOQT_DRAFT}"

case "${DEBUG_MODE:-gdb}" in
  valgrind)
    echo "=== [debug] launching under valgrind memcheck: $* ==="
    # PYTHONMALLOC=malloc so Python allocations are visible to valgrind (no pymalloc
    # pool noise hiding the real block). Keep running past errors so we get the read
    # + its free backtrace even though the app may still fault afterwards.
    exec valgrind \
      --tool=memcheck --error-exitcode=0 --leak-check=no \
      --track-origins=yes --read-var-info=yes --num-callers=40 \
      --exit-on-first-error=no \
      "$@"
    ;;
  *)
    echo "=== [debug] launching under gdb: $* ==="
    exec gdb -q -batch \
      -ex 'set pagination off' -ex 'set confirm off' \
      -ex 'handle SIG32 SIG33 SIG34 SIGPWR nostop noprint pass' \
      -ex 'run' \
      -ex 'printf "\n\n=================== NATIVE BACKTRACE (faulting thread) ===================\n"' \
      -ex 'bt full' \
      -ex 'printf "\n=================== ALL THREADS ===================\n"' \
      -ex 'thread apply all bt' \
      -ex 'printf "\n=================== registers ===================\n"' \
      -ex 'info registers' \
      -ex 'quit' \
      --args "$@"
    ;;
esac

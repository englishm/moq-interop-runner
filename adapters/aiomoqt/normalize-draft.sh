#!/bin/sh
# Adapter shim (relay): the upstream aiomoqt entrypoint passes $MOQT_DRAFT straight
# to --draft, which accepts bare version numbers ("14", or a list "16,18"). The
# interop runner uses the draft-NN convention (e.g. MOQT_DRAFT=draft-14), so strip
# any "draft-" prefix(es) before handing off. Backward compatible: the image default
# ("14,16,18") and the existing harness (which injects nothing, so MOQT_DRAFT keeps
# the baked default) are unaffected. Absent MOQT_DRAFT -> advertise the full set.
set -eu
if [ -n "${MOQT_DRAFT:-}" ]; then
  MOQT_DRAFT="$(printf '%s' "$MOQT_DRAFT" | sed 's/draft-//g')"
  export MOQT_DRAFT
fi
exec /usr/local/bin/docker-entrypoint.sh "$@"

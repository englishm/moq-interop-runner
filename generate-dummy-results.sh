#!/bin/bash
# generate-dummy-results.sh - Synthesize a full-coverage per-draft results summary (POC).
#
# Until the version-pinned runner has real coverage, this fabricates a summary
# from implementations.json so the per-draft report can be shown fully populated.
# For every ELIGIBLE family pairing (both sides support the draft, per role) it
# emits a run per transport (local docker WT, plus the relay's remote transports)
# with deterministic placeholder pass/total. Clearly marked model: "DUMMY".
#
# Usage: ./generate-dummy-results.sh [implementations.json] > summary.json

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/implementations.json}"

jq '
  .implementations as $impl
  # Per-family config: client/relay draft sets, docker availability, relay remote transports.
  | (reduce ($impl | to_entries[]) as $e ({};
      ($e.value.family // $e.key) as $f
      | ($e.value.draft_versions // []) as $dv
      | (if $e.value.roles.client then
           .[$f].client = (((.[$f].client // []) + $dv) | unique)
           | .[$f].cdocker = ((.[$f].cdocker // false) or ($e.value.roles.client.docker != null))
         else . end)
      | (if $e.value.roles.relay then
           .[$f].relay = (((.[$f].relay // []) + $dv) | unique)
           | .[$f].rdocker = ((.[$f].rdocker // false) or ($e.value.roles.relay.docker != null))
           | .[$f].rtrans = (((.[$f].rtrans // []) + ([$e.value.roles.relay.remote[]?.transport])) | unique)
         else . end)
    )) as $fc
  | ($fc | to_entries | map(select(.value.client)) | map(.key) | sort) as $clients
  | ($fc | to_entries | map(select(.value.relay))  | map(.key) | sort) as $relays
  | [ $clients[] as $c | $relays[] as $r
      | ($fc[$c].client) as $cd | ($fc[$r].relay) as $rd
      | (($cd) - (($cd) - ($rd)))[] as $d            # drafts both support
      | (
          ((if ($fc[$c].cdocker and $fc[$r].rdocker) then ["docker"] else [] end))
          + (($fc[$r].rtrans // []) | map("remote-" + .))
        )[] as $mode
      | ((($c + $r + $d + $mode) | explode | add)) as $h
      | 6 as $total
      | (if ($h % 9 == 0) then 0 elif ($h % 4 == 0) then ($h % 6) else 6 end) as $passed
      | { client: $c, relay: $r, draft: $d, transport: $mode,
          passed: $passed, total: $total,
          status: (if $passed == $total then "pass" elif $passed == 0 then "fail" else "partial" end) }
    ]
  | { timestamp: "DUMMY (synthesized from implementations.json)",
      model: "version-pinned-dummy", runs: . }
' "$CONFIG"

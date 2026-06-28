#!/bin/bash
# generate-dummy-results.sh - Synthesize full-coverage per-draft results (POC).
#
# Until the version-pinned runner has real coverage, fabricate a summary from
# implementations.json so the per-draft report can be shown fully populated.
#
# Model: what is tested is protocol correctness per TRANSPORT (QUIC, WT). Whether
# a transport's recipe is local (docker) or remote (public endpoint) is not part
# of the result — it's recorded as `source` (shown on hover). A relay family
# offers at most one recipe per transport; when both a local and remote recipe
# exist we prefer the remote (public) one. Output marked model "DUMMY".
#
# Usage: ./generate-dummy-results.sh [implementations.json] > summary.json

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/implementations.json}"

jq '
  .implementations as $impl
  # Per-family: client/relay draft sets, client docker, and per-transport recipe
  # availability (local via docker.url scheme, remote via endpoint transport).
  | (reduce ($impl | to_entries[]) as $e ({};
      ($e.value.family // $e.key) as $f
      | ($e.value.draft_versions // []) as $dv
      | (if $e.value.roles.client then
           .[$f].client  = (((.[$f].client // []) + $dv) | unique)
           | .[$f].cdocker = ((.[$f].cdocker // false) or ($e.value.roles.client.docker != null))
         else . end)
      | (if $e.value.roles.relay then
           ($e.value.roles.relay) as $rr
           | .[$f].relay = (((.[$f].relay // []) + $dv) | unique)
           | .[$f].wt_local   = ((.[$f].wt_local   // false) or (($rr.docker != null) and (($rr.docker.url // "https") | startswith("https"))))
           | .[$f].quic_local = ((.[$f].quic_local // false) or (($rr.docker.url // "") | startswith("moqt")))
           | .[$f].wt_remote   = ((.[$f].wt_remote   // false) or (([ $rr.remote[]? | select(.transport == "webtransport") ] | length) > 0))
           | .[$f].quic_remote = ((.[$f].quic_remote // false) or (([ $rr.remote[]? | select(.transport == "quic") ] | length) > 0))
         else . end)
    )) as $fc
  | ($fc | to_entries | map(select(.value.client)) | map(.key) | sort) as $clients
  | ($fc | to_entries | map(select(.value.relay))  | map(.key) | sort) as $relays
  | [ $clients[] as $c | $relays[] as $r
      | ($fc[$c].client) as $cd | ($fc[$r].relay) as $rd
      | (($cd) - (($cd) - ($rd)))[] as $d                # drafts both support
      | ( [ { t: "QUIC",
              avail: (($fc[$r].quic_local // false) or ($fc[$r].quic_remote // false)),
              src:   (if ($fc[$r].quic_remote // false) then "remote" else "local" end) },
            { t: "WT",
              avail: (($fc[$r].wt_local // false) or ($fc[$r].wt_remote // false)),
              src:   (if ($fc[$r].wt_remote // false) then "remote" else "local" end) } ]
          | map(select(.avail)) )[] as $tp
      | ((($c + $r + $d + $tp.t) | explode | add)) as $h
      | 6 as $total
      | (if ($h % 9 == 0) then 0 elif ($h % 4 == 0) then ($h % 6) else 6 end) as $passed
      | { client: $c, relay: $r, draft: $d, transport: $tp.t, source: $tp.src,
          passed: $passed, total: $total,
          status: (if $passed == $total then "pass" elif $passed == 0 then "fail" else "partial" end) }
    ]
  | { timestamp: "DUMMY (synthesized from implementations.json)",
      model: "version-pinned-dummy", runs: . }
' "$CONFIG"

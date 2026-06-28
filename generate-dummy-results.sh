#!/bin/bash
# generate-dummy-results.sh - Synthesize full-coverage per-draft results (POC).
#
# Until the version-pinned runner has real coverage, fabricate a summary from
# implementations.json so the per-draft report can be shown fully populated.
#
# Model: what is tested is protocol correctness per TRANSPORT (QUIC, WT). Whether
# a transport's registration is local (docker) or remote (public endpoint) is not part
# of the result — it's recorded as `source` (shown on hover). A relay family
# offers at most one registration per transport; when both a local and remote registration
# exist we prefer the remote (public) one. Output marked model "DUMMY".
#
# Usage: ./generate-dummy-results.sh [implementations.json] > summary.json

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/implementations.json}"

jq '
  .implementations as $impl
  # Per-family: client/relay draft sets, client docker, and per-transport registration
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
           | .[$f].wt_url   = (.[$f].wt_url   // ([ $rr.remote[]? | select(.transport == "webtransport") | .url ][0]))
           | .[$f].quic_url = (.[$f].quic_url // ([ $rr.remote[]? | select(.transport == "quic") | .url ][0]))
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
      # POC states: intentional skip (~1/17); a registered remote endpoint that is
      # unreachable (~1/19 of remote); otherwise a real score (0/6 = connected, all failed).
      | (if ($h % 17 == 0)
         then { passed: null, total: null, status: "skip" }
         elif ($tp.src == "remote" and ($h % 19 == 0))
         then { passed: null, total: null, status: "conn-fail" }
         else (if ($h % 9 == 0) then 0 elif ($h % 4 == 0) then ($h % 6) else 6 end) as $p
              | { passed: $p, total: 6,
                  status: (if $p == 6 then "pass" elif $p == 0 then "fail" else "partial" end) }
         end) as $res
      | (if $tp.src == "remote"
         then (if $tp.t == "QUIC" then $fc[$r].quic_url else $fc[$r].wt_url end)
         else null end) as $url
      | (if $res.status == "conn-fail"
         then (if ($h % 2 == 0) then "connection refused" else "connection timed out" end)
         else null end) as $err
      | { client: $c, relay: $r, draft: $d, transport: $tp.t, source: $tp.src,
          url: $url, error: $err } + $res
    ]
  | { timestamp: "DUMMY (synthesized from implementations.json)",
      model: "version-pinned-dummy", runs: . }
' "$CONFIG"

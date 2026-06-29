#!/bin/bash
# generate-dummy-results.sh - Synthesize full-coverage results (POC).
#
# Emits two views (runs[].view):
#   "draft" - the version-pinned per-draft matrix. Each (client,relay,draft,transport)
#             cell, preferring the LOCAL (docker) recipe (version-confined, most
#             credible); falls back to the remote endpoint only when no local exists.
#   "open"  - "Open Relay Interop": for relays exposing a live/public endpoint, the
#             mutually NEGOTIATED draft (highest common) tested against that endpoint,
#             per remote transport. Real-world negotiation; client confines nothing.
#
# Marked model "DUMMY". Usage: ./generate-dummy-results.sh [implementations.json] > summary.json

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/implementations.json}"

jq '
  def status($p; $t): if $p == $t then "pass" elif $p == 0 then "fail" else "partial" end;
  def score($h): (if ($h % 9 == 0) then 0 elif ($h % 4 == 0) then ($h % 6) else 6 end);

  .implementations as $impl
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
      | (($cd) - (($cd) - ($rd))) as $common
      | (
          # ---- per-draft confined view (LOCAL preferred) ----
          ( $common[] as $d
            | ( { t: "QUIC", lo: ($fc[$r].quic_local // false), re: ($fc[$r].quic_remote // false), url: $fc[$r].quic_url },
                { t: "WT",   lo: ($fc[$r].wt_local   // false), re: ($fc[$r].wt_remote   // false), url: $fc[$r].wt_url } )
              | select(.lo or .re)
              | (if .lo then "local" else "remote" end) as $src
              | ((($c+$r+$d+.t) | explode | add)) as $h
              | (if ($h % 17 == 0) then {passed:null,total:null,status:"skip"}
                 elif (.re and (.lo|not) and ($h % 19 == 0)) then {passed:null,total:null,status:"conn-fail"}
                 else (score($h)) as $p | {passed:$p, total:6, status: status($p;6)} end) as $res
              | { view:"draft", client:$c, relay:$r, draft:$d, transport:.t, source:$src,
                  url: (if $src=="remote" then .url else null end),
                  error: (if $res.status=="conn-fail" then "connection refused" else null end) } + $res )
          ,
          # ---- open relay interop view (NEGOTIATED, live endpoint) ----
          ( ($common | sort_by(ltrimstr("draft-")|tonumber) | last) as $neg
            | select($neg != null and (($fc[$r].wt_remote // false) or ($fc[$r].quic_remote // false)))
            | ( { t:"QUIC", re:($fc[$r].quic_remote // false), url:$fc[$r].quic_url },
                { t:"WT",   re:($fc[$r].wt_remote   // false), url:$fc[$r].wt_url } )
              | select(.re)
              | ((($c+$r+"open"+.t) | explode | add)) as $h
              | (if ($h % 23 == 0) then {passed:null,total:null,status:"conn-fail"}
                 else (score($h)) as $p | {passed:$p, total:6, status: status($p;6)} end) as $res
              | { view:"open", client:$c, relay:$r, draft:$neg, transport:.t, source:"remote", url:.url,
                  error:(if $res.status=="conn-fail" then "connection timed out" else null end) } + $res )
        )
    ]
  | { timestamp: "DUMMY (synthesized from implementations.json)",
      model: "version-pinned-dummy", runs: . }
' "$CONFIG"

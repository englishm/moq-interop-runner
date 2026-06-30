#!/bin/bash
# seed-official-results.sh - Convert an official negotiated-run summary into the
# version-pinned renderer schema, so REAL results can be layered over the optimistic
# dummy baseline (see generate-dummy-results.sh, merge-results.sh).
#
# Input  : an official results summary (e.g. gh-pages results/<ts>/summary.json),
#          whose runs are {client, relay, version, mode, target, status}.
# Output : {runs:[...]} in renderer schema. Each negotiated result lands on its
#          negotiated-draft page (view:"draft", LOCAL preferred per transport); live
#          remote endpoints also populate Open Relay Interop (view:"open").
#
# Mapping: client/relay adapter -> family; mode -> transport+source
#   (remote-quic=QUIC/remote, remote-webtransport=WT/remote, docker=local with the
#   transport taken from the relay's registered docker.url scheme); version -> draft;
#   status pass->6/6, fail->0/6, skip->skip, timeout->conn-fail. On duplicate/
#   conflicting runs for a cell the WORST status wins (honest real status).
#
# Usage: ./seed-official-results.sh official-summary.json [implementations.json] > real.json

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY="${1:?usage: seed-official-results.sh official-summary.json [implementations.json]}"
CONFIG="${2:-$SCRIPT_DIR/implementations.json}"

jq -n --slurpfile s "$SUMMARY" --slurpfile cfg "$CONFIG" '
  def worst:
    if   (map(.status) | index("fail"))      then map(select(.status=="fail"))
    elif (map(.status) | index("conn-fail")) then map(select(.status=="conn-fail"))
    elif (map(.status) | index("skip"))      then map(select(.status=="skip"))
    else . end | .[0];

  ($cfg[0].implementations) as $impl
  | ($impl | to_entries | map({key:.key, value:(.value.family // .key)}) | from_entries) as $fam
  | ($impl | to_entries | map(select(.value.roles.relay))
       | map({key:.key, value: ((.value.roles.relay.docker.url // "https")
                                  | if startswith("moqt") then "QUIC" else "WT" end)})
       | from_entries) as $rtx
  | [ $s[0].runs[]?
      | ($fam[.client]) as $cf | ($fam[.relay]) as $rf
      | select($cf != null and $rf != null and (.version | type=="string"))
      | { cf:$cf, rf:$rf, draft:.version,
          t:   (if .mode=="remote-quic" then "QUIC"
                elif .mode=="remote-webtransport" then "WT"
                else ($rtx[.relay] // "WT") end),
          src: (if .mode=="docker" then "local" else "remote" end),
          url: (if .mode=="docker" then null else .target end),
          status: (if .status=="pass" then "pass"
                   elif .status=="skip" then "skip"
                   elif .status=="timeout" then "conn-fail"
                   else "fail" end),
          passed: (if .status=="pass" then 6 elif .status=="fail" then 0 else null end),
          total:  (if (.status=="pass" or .status=="fail") then 6 else null end) }
    ] as $n
  | ( $n | group_by([.cf,.rf,.draft,.t])
        | map( ((if any(.[]; .src=="local") then map(select(.src=="local")) else . end) | worst)
               | {view:"draft", client:.cf, relay:.rf, draft:.draft, transport:.t,
                  source:.src, status:.status, passed:.passed, total:.total, url:.url, error:null} ) ) as $draft
  | ( $n | map(select(.src=="remote")) | group_by([.cf,.rf,.draft,.t])
        | map( (worst)
               | {view:"open", client:.cf, relay:.rf, draft:.draft, transport:.t,
                  source:"remote", status:.status, passed:.passed, total:.total, url:.url, error:null} ) ) as $open
  | { timestamp: ($s[0].timestamp // "official"), model: "official-seed", runs: ($draft + $open) }
'

#!/bin/bash
# run-interop-pinned.sh - Version-pinned interop runner (POC, see ADR 003).
#
# Runs ALONGSIDE run-interop-tests.sh (both models coexist). Instead of one
# negotiated cell per (client, relay) pair, it tests the pinned cross-product
# (client@D, relay@D) per draft D.
#
# Hybrid coverage: a (C, R) pair is testable at draft D when both support D AND
# at least one side can be pinned to D (has a versions[D] overlay, or is a
# single-version impl == [D]), OR D is their highest common draft (the natural
# negotiated cell). Otherwise the cell is N/A.
#
# Effective per-side config (image/env/flags) is resolved by lib/resolve-config.sh
# from base -> versions[draft] -> peer_overrides.
#
# Usage:
#   ./run-interop-pinned.sh [--draft draft-16] [--client X] [--relay Y]
#                           [--docker-only] [--dry-run]
#
# Exit codes: 0 ok / 1 one or more test failures (non-dry runs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/implementations.json"

source "$SCRIPT_DIR/lib/resolve-config.sh"
source "$SCRIPT_DIR/lib/tap-parser.sh"

if [[ -t 1 ]]; then
  BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'
else
  BLUE='' GREEN='' YELLOW='' CYAN='' DIM='' NC=''
fi

DRY_RUN=false DOCKER_ONLY=false
DRAFT_FILTER="" CLIENT_FILTER="" RELAY_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --draft)   DRAFT_FILTER="$2"; shift 2 ;;
    --client)  CLIENT_FILTER="$2"; shift 2 ;;
    --relay)   RELAY_FILTER="$2"; shift 2 ;;
    --docker-only) DOCKER_ONLY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }

RESULTS_DIR="$SCRIPT_DIR/results/$(date +%Y-%m-%d_%H%M%S)-pinned"
SUMMARY_FILE="$RESULTS_DIR/summary.json"

#############################################################################
# Planning helpers
#############################################################################

# All drafts across the registry, ascending, optionally narrowed by --draft.
target_drafts() {
  if [ -n "$DRAFT_FILTER" ]; then echo "$DRAFT_FILTER"; return; fi
  jq -r '[.implementations[].draft_versions[]?] | unique
         | sort_by(ltrimstr("draft-")|tonumber) | .[]' "$CONFIG_FILE"
}

impls_with_role() {
  jq -r --arg role "$1" '.implementations | to_entries[]
         | select(.value.roles[$role]) | .key' "$CONFIG_FILE"
}

# Is (client C, relay R) testable at draft D? echoes "yes" or "no".
testable() {
  local c="$1" r="$2" d="$3"
  jq -r --arg c "$c" --arg r "$r" --arg d "$d" '
    .implementations as $i |
    ($i[$c].draft_versions // []) as $cv |
    ($i[$r].draft_versions // []) as $rv |
    ($cv - ($cv - $rv)) as $common |
    if ($common | index($d) | not) then "no"
    else
      # confinable to $d if: explicit versions[$d] entry, single-version impl,
      # or the role interpolates the standard MOQT_DRAFT into its config.
      (($i[$c].roles.client.versions[$d] != null) or ($cv == [$d])
         or ($i[$c].roles.client | tostring | test("MOQT_DRAFT"))) as $cpin |
      (($i[$r].roles.relay.versions[$d]  != null) or ($rv == [$d])
         or ($i[$r].roles.relay | tostring | test("MOQT_DRAFT"))) as $rpin |
      ($common | sort_by(ltrimstr("draft-")|tonumber) | last) as $maxc |
      (if ($cpin or $rpin or ($d == $maxc)) then "yes" else "no" end)
    end' "$CONFIG_FILE"
}

# Transports to exercise for (R, D): "docker" plus any version-pinned remotes.
pair_modes() {
  local c="$1" r="$2" d="$3"
  local client_img relay_img
  client_img=$(resolve_config "$CONFIG_FILE" "$c" client "$r" "$d" | jq -r '.image // empty')
  relay_img=$(resolve_config "$CONFIG_FILE" "$r" relay "$c" "$d" | jq -r '.image // empty')
  if [ -n "$client_img" ] && [ -n "$relay_img" ]; then echo "docker"; fi
  [ "$DOCKER_ONLY" = true ] && return
  # version-pinned remote endpoints (versions[d].remote) on the relay
  jq -r --arg r "$r" --arg d "$d" \
     '.implementations[$r].roles.relay.versions[$d].remote[]? | "remote-\(.transport)"' "$CONFIG_FILE"
}

#############################################################################
# Execution
#############################################################################

record_run() {
  # Emits the per-draft schema the renderer/merge expect.
  local c="$1" r="$2" d="$3" transport="$4" source="$5" status="$6" passed="$7" total="$8" url="${9:-}"
  local tmp; tmp=$(mktemp "${SUMMARY_FILE}.XXXXXX")
  jq --arg c "$c" --arg r "$r" --arg d "$d" --arg t "$transport" --arg src "$source" \
     --arg status "$status" --argjson passed "${passed:-null}" --argjson total "${total:-null}" \
     --arg url "$url" \
     '.runs += [{client:$c, relay:$r, draft:$d, transport:$t, source:$src,
                 status:$status, passed:$passed, total:$total,
                 url:(if $url=="" then null else $url end)}]' \
     "$SUMMARY_FILE" > "$tmp" && mv "$tmp" "$SUMMARY_FILE" || rm -f "$tmp"
}

run_docker_test() {
  # Resolve both sides, inject env into docker-compose, run, parse TAP.
  local c="$1" r="$2" d="$3"
  local crc rrc cimg rimg
  crc=$(resolve_config "$CONFIG_FILE" "$c" client "$r" "$d")
  rrc=$(resolve_config "$CONFIG_FILE" "$r" relay  "$c" "$d")
  cimg=$(jq -r '.image' <<<"$crc"); rimg=$(jq -r '.image' <<<"$rrc")

  # Local docker transport from the relay's docker.url scheme (moqt:// = QUIC, else H3/WT).
  local relay_url transport
  relay_url=$(jq -r --arg r "$r" '.implementations[$r].roles.relay.docker.url // "https"' "$CONFIG_FILE")
  case "$relay_url" in moqt://*) transport=QUIC ;; *) transport=WT ;; esac
  local log="$RESULTS_DIR/${c}_to_${r}_${d}_${transport}.log"

  # Resolved env -> per-test env files consumed by docker-compose (env_file).
  local renv_file cenv_file
  renv_file="$RESULTS_DIR/.env.${c}_to_${r}_${d}.relay"
  cenv_file="$RESULTS_DIR/.env.${c}_to_${r}_${d}.client"
  jq -r '.env_args[]' <<<"$rrc" > "$renv_file"
  jq -r '.env_args[]' <<<"$crc" > "$cenv_file"

  local status="fail"
  if RELAY_IMAGE="$rimg" CLIENT_IMAGE="$cimg" \
     PINNED_RELAY_ENV_FILE="$renv_file" PINNED_CLIENT_ENV_FILE="$cenv_file" \
     run_with_timeout "${TEST_TIMEOUT:-120}" \
        docker compose -f "$SCRIPT_DIR/docker-compose.test.yml" up --abort-on-container-exit \
        > "$log" 2>&1; then
    status="pass"
  else
    [ "$?" -eq 124 ] && status="timeout"
  fi

  # Prefer real TAP counts; refine status from them.
  local passed="" total=""
  if parse_tap_file "$log" && [ "$TAP_TOTAL" -gt 0 ]; then
    passed=$TAP_PASSED; total=$TAP_TOTAL
    if [ "$passed" = "$total" ]; then status=pass
    elif [ "$passed" = "0" ]; then status=fail
    else status=partial; fi
  fi
  record_run "$c" "$r" "$d" "$transport" local "$status" "$passed" "$total"
  echo "$status"
}

# Minimal timeout wrapper (GNU/macOS).
run_with_timeout() {
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"; return $?; fi
  "$@"
}

#############################################################################
# Main
#############################################################################

CLIENTS=$(impls_with_role client); [ -n "$CLIENT_FILTER" ] && CLIENTS="$CLIENT_FILTER"
RELAYS=$(impls_with_role relay);   [ -n "$RELAY_FILTER" ]  && RELAYS="$RELAY_FILTER"

echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   MoQT Interop — version-pinned matrix (POC)   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
$DRY_RUN && echo -e "Mode: ${YELLOW}dry run${NC}"

if [ "$DRY_RUN" != true ]; then
  mkdir -p "$RESULTS_DIR"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{runs: [], timestamp: $ts, model: "version-pinned"}' > "$SUMMARY_FILE"
fi

TOTAL=0 PASS=0 FAIL=0
for d in $(target_drafts); do
  echo -e "\n${CYAN}── ${d} ──${NC}"
  any=false
  for c in $CLIENTS; do
    for r in $RELAYS; do
      [ "$(testable "$c" "$r" "$d")" = "yes" ] || continue
      modes=$(pair_modes "$c" "$r" "$d"); [ -z "$modes" ] && continue
      any=true
      cimg=$(resolve_config "$CONFIG_FILE" "$c" client "$r" "$d" | jq -r '.image // "-"')
      rimg=$(resolve_config "$CONFIG_FILE" "$r" relay  "$c" "$d" | jq -r '.image // "-"')
      cenv=$(resolve_config "$CONFIG_FILE" "$c" client "$r" "$d" | jq -rc '.env_args')
      renv=$(resolve_config "$CONFIG_FILE" "$r" relay  "$c" "$d" | jq -rc '.env_args')
      while IFS= read -r mode; do
        [ -z "$mode" ] && continue
        TOTAL=$((TOTAL+1))
        if [ "$DRY_RUN" = true ]; then
          echo -e "  ${GREEN}${c}${NC} → ${GREEN}${r}${NC}  ${DIM}${mode}${NC}"
          echo -e "      ${DIM}client:${NC} ${cimg}  ${DIM}env:${NC} ${cenv}"
          echo -e "      ${DIM}relay :${NC} ${rimg}  ${DIM}env:${NC} ${renv}"
        else
          if [ "$mode" = "docker" ]; then
            st=$(run_docker_test "$c" "$r" "$d")
            [ "$st" = "pass" ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
            echo -e "  ${c} → ${r} ${DIM}${mode}${NC}: ${st}"
          else
            echo -e "  ${c} → ${r} ${DIM}${mode}${NC}: ${YELLOW}remote exec not in POC scope${NC}"
          fi
        fi
      done <<< "$modes"
    done
  done
  $any || echo -e "  ${DIM}(no testable pairings)${NC}"
done

echo ""
echo -e "${BLUE}Planned cells: ${TOTAL}${NC}"
if [ "$DRY_RUN" != true ]; then
  echo -e "${GREEN}Pass: ${PASS}${NC}  Fail: ${FAIL}"
  echo -e "Results: $RESULTS_DIR"
  [ "$FAIL" -gt 0 ] && exit 1
fi
exit 0

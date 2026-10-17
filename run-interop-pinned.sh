#!/bin/bash
# run-interop-pinned.sh - Run docker client x relay pairs confined to one draft.
#
# For each draft D, every docker client and docker relay that both register
# draft-D run once with each side confined to D where its registration allows:
# a per-draft image (confine.images), a single registered draft, or confine.env /
# confine.args rendered with ${MOQT_DRAFT} (draft-NN) and ${MOQT_DRAFT_NUM} (NN).
# A side that can't be confined runs as registered; the run records which sides
# were confined. Pairs are never dropped for lack of confinement.
#
# Usage:
#   ./run-interop-pinned.sh [--draft N]... [--relay NAME] [--client NAME] [--dry-run]
#
# Results: results/pinned-<timestamp>/ with <client>_to_<relay>_d<N>.log and a
# summary.json whose runs carry pinned_draft and confined (both|client|relay|none).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/implementations.json"
DRAFTS=()
RELAY_FILTER=""
CLIENT_FILTER=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --draft) [[ -n "${2:-}" ]] || { echo "Error: --draft requires a value"; exit 1; }
                 DRAFTS+=("${2#draft-}"); shift 2 ;;
        --relay) RELAY_FILTER="$2"; shift 2 ;;
        --client) CLIENT_FILTER="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h)
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo "Error: jq is required"; exit 1; }

# Default: every even draft some docker relay registers.
if [ ${#DRAFTS[@]} -eq 0 ]; then
    while read -r d; do DRAFTS+=("$d"); done < <(jq -r '
        [.implementations[] | select(.roles.relay.docker.image?) | .draft_versions[]
         | ltrimstr("draft-") | tonumber | select(. % 2 == 0)] | unique | reverse | .[]' "$CONFIG_FILE")
fi

docker_impls() {
    jq -r --arg role "$1" '.implementations | to_entries[] | select(.value.roles[$role].docker.image?) | .key' "$CONFIG_FILE"
}

supports() {
    jq -e --arg impl "$1" --arg d "draft-$2" '.implementations[$impl].draft_versions | index($d) != null' "$CONFIG_FILE" >/dev/null
}

# Print {confined, image, env, args} for one side of a run at draft $3.
side_config() {
    jq -c --arg impl "$1" --arg role "$2" --arg d "draft-$3" --arg n "$3" '
        def render: gsub("\\$\\{MOQT_DRAFT_NUM\\}"; $n) | gsub("\\$\\{MOQT_DRAFT\\}"; $d);
        .implementations[$impl] as $i | $i.roles[$role] as $r | ($r.confine // {}) as $c |
        (($c.drafts // [$d]) | index($d) != null) as $allowed |
        if $c.images[$d]? then
            {confined: true, method: "image", image: $c.images[$d], env: {}, args: []}
        elif ($i.draft_versions | length) == 1 and $i.draft_versions[0] == $d then
            {confined: true, method: "single-draft", image: $r.docker.image, env: {}, args: []}
        elif $allowed and ((($c.env // {}) | length) > 0 or (($c.args // []) | length) > 0) then
            {confined: true, method: "env/args", image: $r.docker.image,
             env: (($c.env // {}) | map_values(render)),
             args: (($c.args // []) | map(render))}
        else
            {confined: false, method: "none", image: $r.docker.image, env: {}, args: []}
        end' "$CONFIG_FILE"
}

relay_url() {
    jq -r --arg impl "$1" '.implementations[$impl].roles.relay.docker.url // "https://relay:4443"' "$CONFIG_FILE"
}

run_with_timeout() {
    local seconds="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"; return $?; fi
    if command -v gtimeout >/dev/null 2>&1; then gtimeout "$seconds" "$@"; return $?; fi
    "$@"
}

mapfile -t CLIENTS < <(if [ -n "$CLIENT_FILTER" ]; then echo "$CLIENT_FILTER"; else docker_impls client; fi)
mapfile -t RELAYS < <(if [ -n "$RELAY_FILTER" ]; then echo "$RELAY_FILTER"; else docker_impls relay; fi)

RESULTS_DIR="$SCRIPT_DIR/results/pinned-$(date +%Y-%m-%d_%H%M%S)"
SUMMARY_FILE="$RESULTS_DIR/summary.json"
if [ "$DRY_RUN" != true ]; then
    mkdir -p "$RESULTS_DIR"
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson drafts "$(printf '%s\n' "${DRAFTS[@]}" | jq -sc 'map(tonumber)')" \
        '{runs: [], pinned: true, drafts: $drafts, timestamp: $ts}' > "$SUMMARY_FILE"
fi

TOTAL=0; PASSED=0; FAILED=0; SKIPPED=0
echo "Drafts: ${DRAFTS[*]}"
for d in "${DRAFTS[@]}"; do
    for relay in "${RELAYS[@]}"; do
        supports "$relay" "$d" || continue
        for client in "${CLIENTS[@]}"; do
            supports "$client" "$d" || continue
            cside=$(side_config "$client" client "$d")
            rside=$(side_config "$relay" relay "$d")
            cpin=$(jq -r .confined <<< "$cside"); rpin=$(jq -r .confined <<< "$rside")
            case "$cpin$rpin" in
                truetrue) confined=both ;; truefalse) confined=client ;;
                falsetrue) confined=relay ;; *) confined=none ;;
            esac
            cimg=$(jq -r .image <<< "$cside"); rimg=$(jq -r .image <<< "$rside")
            url=$(relay_url "$relay")
            echo "draft-$d  $client -> $relay  confined=$confined  ($cimg | $rimg)"
            [ "$DRY_RUN" = true ] && continue

            TOTAL=$((TOTAL + 1))
            log="$RESULTS_DIR/${client}_to_${relay}_d${d}.log"
            status=pass; exit_code=0; skip_reason=""
            for img in "$cimg" "$rimg"; do
                if ! docker image inspect "$img" >/dev/null 2>&1; then
                    status=skip; skip_reason="image unavailable: $img"
                fi
            done
            if [ "$status" = skip ]; then
                SKIPPED=$((SKIPPED + 1)); echo "  SKIP ($skip_reason)"
            else
                override="$RESULTS_DIR/.override-${client}_to_${relay}_d${d}.yml"
                # Only a registration's own env/args go in; JSON is valid compose YAML.
                jq -n --argjson c "$cside" --argjson r "$rside" '
                    def svc($s): (if ($s.env | length) > 0 then {environment: $s.env} else {} end)
                        + (if ($s.args | length) > 0 then {command: $s.args} else {} end);
                    {services: ({"test-client": svc($c), relay: svc($r)} | with_entries(select(.value != {})))}' > "$override"
                if run_with_timeout "${TEST_TIMEOUT:-120}" make test RELAY_IMAGE="$rimg" CLIENT_IMAGE="$cimg" \
                        RELAY_URL="$url" COMPOSE_OVERRIDE="$override" > "$log" 2>&1; then
                    PASSED=$((PASSED + 1)); echo "  PASS"
                else
                    exit_code=$?
                    status=$([ "$exit_code" -eq 124 ] && echo timeout || echo fail)
                    FAILED=$((FAILED + 1)); echo "  ${status^^} (exit $exit_code)"
                fi
                rm -f "$override"
            fi
            tmp=$(mktemp "$SUMMARY_FILE.XXXXXX")
            jq --arg client "$client" --arg relay "$relay" --argjson d "$d" --arg confined "$confined" \
               --arg cmethod "$(jq -r .method <<< "$cside")" --arg rmethod "$(jq -r .method <<< "$rside")" \
               --arg cimg "$cimg" --arg rimg "$rimg" --arg url "$url" --arg status "$status" \
               --argjson exit_code "$exit_code" --arg skip_reason "$skip_reason" '
                .runs += [{client: $client, relay: $relay, mode: "d\($d)", version: "draft-\($d)",
                           pinned_draft: $d, confined: $confined, client_confine: $cmethod, relay_confine: $rmethod,
                           client_image: $cimg, relay_image: $rimg,
                           target: $url, status: $status, exit_code: $exit_code}
                          + (if $skip_reason != "" then {skip_reason: $skip_reason} else {} end)]' \
               "$SUMMARY_FILE" > "$tmp" && mv "$tmp" "$SUMMARY_FILE"
        done
    done
done

[ "$DRY_RUN" = true ] && exit 0
echo ""
echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
echo "Results: $RESULTS_DIR"
exit 0

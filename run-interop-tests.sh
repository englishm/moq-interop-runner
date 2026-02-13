#!/bin/bash
# run-interop-tests.sh - Run MoQT interop tests across client x relay pairs
#
# For each (client, relay) pair, predicts the negotiated version as the newest
# draft version both sides support. This matches wire behavior -- the runner
# cannot control version negotiation.
#
# Pairs are classified relative to a target version (at / ahead / behind)
# and can be filtered or sorted by that classification.
#
# Exit codes:
#   0 - All tests passed (or no tests run)
#   1 - One or more test failures occurred

set -euo pipefail

# NOTE: This script intentionally avoids mapfile/readarray for macOS compatibility.
# macOS ships with Bash 3.2 (due to GPLv3 licensing) which lacks these builtins.
# While users can install newer Bash via Homebrew, we prefer zero-friction setup.
# See: https://apple.stackexchange.com/questions/193411/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/implementations.json"
RESULTS_DIR="$SCRIPT_DIR/results/$(date +%Y-%m-%d_%H%M%S)"

# Colors for output (only if stdout is a TTY)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# Parse arguments
DOCKER_ONLY=false
REMOTE_ONLY=false
LIST_ONLY=false
DRY_RUN=false
TRANSPORT_FILTER=""
TARGET_VERSION=""  # Will be read from config if not specified
RELAY_FILTER=""    # Filter to specific relay implementation
CLIENT_FILTER=""   # Filter to specific client implementation
CLASSIFICATION_FILTER=""  # "", "at", "ahead", or "behind"

while [[ $# -gt 0 ]]; do
    case $1 in
        --docker-only) DOCKER_ONLY=true; shift ;;
        --remote-only) REMOTE_ONLY=true; shift ;;
        --list) LIST_ONLY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --transport)
            [[ -n "${2:-}" ]] || { echo "Error: --transport requires a value"; exit 1; }
            TRANSPORT_FILTER="$2"; shift 2
            ;;
        --quic-only) TRANSPORT_FILTER="quic"; shift ;;
        --webtransport-only) TRANSPORT_FILTER="webtransport"; shift ;;
        --only-at-target)
            [ -n "$CLASSIFICATION_FILTER" ] && { echo "Error: only one --only-* flag allowed"; exit 1; }
            CLASSIFICATION_FILTER="at"; shift ;;
        --only-ahead-of-target)
            [ -n "$CLASSIFICATION_FILTER" ] && { echo "Error: only one --only-* flag allowed"; exit 1; }
            CLASSIFICATION_FILTER="ahead"; shift ;;
        --only-behind-target)
            [ -n "$CLASSIFICATION_FILTER" ] && { echo "Error: only one --only-* flag allowed"; exit 1; }
            CLASSIFICATION_FILTER="behind"; shift ;;
        --target-version)
            [[ -n "${2:-}" ]] || { echo "Error: --target-version requires a value"; exit 1; }
            TARGET_VERSION="$2"; shift 2
            ;;
        --relay)
            [[ -n "${2:-}" ]] || { echo "Error: --relay requires a value"; exit 1; }
            RELAY_FILTER="$2"; shift 2
            ;;
        --client)
            [[ -n "${2:-}" ]] || { echo "Error: --client requires a value"; exit 1; }
            CLIENT_FILTER="$2"; shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --docker-only             Only test Docker images"
            echo "  --remote-only             Only test remote endpoints"
            echo "  --transport TYPE          Filter remote endpoints by transport (quic or webtransport)"
            echo "  --quic-only               Filter remote endpoints to raw QUIC only (moqt://)"
            echo "  --webtransport-only       Filter remote endpoints to WebTransport only (https://)"
            echo "  --target-version VER      Target draft version for classification (default: from config)"
            echo "  --relay NAME              Only test specific relay implementation"
            echo "  --client NAME             Only test specific client implementation"
            echo "  --only-at-target          Only test pairs that negotiate the target version"
            echo "  --only-ahead-of-target    Only test pairs negotiating ahead of the target"
            echo "  --only-behind-target      Only test pairs negotiating behind the target"
            echo "  --dry-run                 Show computed test plan without executing"
            echo "  --list                    List available implementations and exit"
            echo "  --help                    Show this help"
            echo ""
            echo "Notes:"
            echo "  Transport filters (--transport, --quic-only, --webtransport-only) only affect"
            echo "  remote endpoints. Docker tests are unaffected. Use --remote-only to skip Docker."
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate flag combinations
if [ -n "$TRANSPORT_FILTER" ] && [ "$TRANSPORT_FILTER" != "quic" ] && [ "$TRANSPORT_FILTER" != "webtransport" ]; then
    echo "Error: --transport must be 'quic' or 'webtransport' (got: $TRANSPORT_FILTER)"
    exit 1
fi

if [ -n "$TRANSPORT_FILTER" ] && [ "$DOCKER_ONLY" = true ]; then
    echo "Warning: --transport has no effect with --docker-only (transport filters apply to remote endpoints only)" >&2
fi

if [ "$DOCKER_ONLY" = true ] && [ "$REMOTE_ONLY" = true ]; then
    echo "Error: --docker-only and --remote-only are mutually exclusive"
    exit 1
fi

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required. Install with: brew install jq"
    exit 1
fi

# Read target version from config if not specified via CLI
if [ -z "$TARGET_VERSION" ]; then
    TARGET_VERSION=$(jq -r '.current_target // "draft-16"' "$CONFIG_FILE")
fi

# Validate target version format
if ! [[ "$TARGET_VERSION" =~ ^draft-[0-9]+$ ]]; then
    echo "Error: --target-version must be in format 'draft-NN' (got: $TARGET_VERSION)"
    exit 1
fi

# Validate all draft_versions in config follow draft-NN format
bad_versions=$(jq -r '
    .implementations | to_entries[] |
    .key as $impl |
    .value.draft_versions[]? |
    select(test("^draft-[0-9]+$") | not) |
    "\($impl): \(.)"
' "$CONFIG_FILE")
if [ -n "$bad_versions" ]; then
    echo "Error: malformed draft_versions in implementations.json (must be draft-NN):"
    echo "$bad_versions"
    exit 1
fi

# List implementations with version info
list_implementations() {
    echo -e "${BLUE}Available MoQT Implementations:${NC}"
    echo ""
    jq -r '.implementations | to_entries[] |
        "  \(.key):\n    Name: \(.value.name)\n    Versions: \(.value.draft_versions | join(", "))\n    Roles: \(.value.roles | keys | join(", "))\n"' \
        "$CONFIG_FILE"
}

if [ "$LIST_ONLY" = true ]; then
    list_implementations
    exit 0
fi

# Create results directory (skip for dry run)
if [ "$DRY_RUN" != true ]; then
    mkdir -p "$RESULTS_DIR"
fi

#############################################################################
# Helper Functions
#############################################################################

# Get all implementations with a specific role
get_impls_with_role() {
    local role="$1"
    jq -r --arg role "$role" '.implementations | to_entries[] | select(.value.roles[$role] != null) | .key' "$CONFIG_FILE"
}

# Compute the version a (client, relay) pair will negotiate.
# Returns the newest shared draft version, or empty string if none.
compute_negotiated_version() {
    local client="$1"
    local relay="$2"
    jq -r --arg client "$client" --arg relay "$relay" '
        (.implementations[$client].draft_versions // []) as $cv |
        (.implementations[$relay].draft_versions // []) as $rv |
        # Find shared versions
        [$cv[] | select(. as $v | $rv | index($v))] |
        if length == 0 then ""
        else
            # Return the newest (highest draft number)
            sort_by(ltrimstr("draft-") | tonumber) | reverse | .[0]
        end
    ' "$CONFIG_FILE"
}

# Classify a version relative to the target.
# Returns: "at", "ahead", "behind", or "none" (if version is empty)
classify_version() {
    local version="$1"
    local target="$2"
    if [ -z "$version" ]; then
        echo "none"
        return
    fi
    local v_num="${version#draft-}"
    local t_num="${target#draft-}"
    if [ "$v_num" -eq "$t_num" ]; then
        echo "at"
    elif [ "$v_num" -gt "$t_num" ]; then
        echo "ahead"
    else
        echo "behind"
    fi
}

# Check if a Docker image exists locally.
# Returns 0 if the image is available, 1 otherwise.
image_exists() {
    local image="$1"
    docker image inspect "$image" &>/dev/null
}

# Track images that were referenced but not available.
# Accumulated during planning, printed as a consolidated warning at the end.
MISSING_IMAGES=()

# Record a missing image (deduplicated).
record_missing_image() {
    local image="$1"
    for existing in "${MISSING_IMAGES[@]+"${MISSING_IMAGES[@]}"}"; do
        [ "$existing" = "$image" ] && return
    done
    MISSING_IMAGES+=("$image")
}

# List runnable endpoints for a relay, one per line.
# Output format: mode|target|tls_disable
# Respects DOCKER_ONLY, REMOTE_ONLY, and TRANSPORT_FILTER.
list_endpoints() {
    local relay="$1"

    # Docker endpoint
    if [ "$REMOTE_ONLY" != true ]; then
        local docker_image=$(jq -r --arg relay "$relay" '.implementations[$relay].roles.relay.docker.image // empty' "$CONFIG_FILE")
        if [ -n "$docker_image" ]; then
            if image_exists "$docker_image"; then
                echo "docker|$docker_image|false"
            else
                record_missing_image "$docker_image"
                echo "docker-skip|$docker_image|false"
            fi
        fi
    fi

    # Remote endpoints
    if [ "$DOCKER_ONLY" != true ]; then
        local remote_count=$(jq -r --arg relay "$relay" '.implementations[$relay].roles.relay.remote | length // 0' "$CONFIG_FILE")
        if [ "$remote_count" -gt 0 ]; then
        for i in $(seq 0 $((remote_count - 1))); do
            local url=$(jq -r --arg relay "$relay" --argjson i "$i" '.implementations[$relay].roles.relay.remote[$i].url' "$CONFIG_FILE")
            local transport=$(jq -r --arg relay "$relay" --argjson i "$i" '.implementations[$relay].roles.relay.remote[$i].transport // "unknown"' "$CONFIG_FILE")
            local tls_disable=$(jq -r --arg relay "$relay" --argjson i "$i" '.implementations[$relay].roles.relay.remote[$i].tls_disable_verify // false' "$CONFIG_FILE")
            local endpoint_status=$(jq -r --arg relay "$relay" --argjson i "$i" '.implementations[$relay].roles.relay.remote[$i].status // "active"' "$CONFIG_FILE")

            # Skip inactive endpoints
            [ "$endpoint_status" = "inactive" ] && continue

            # Apply transport filter
            if [ -n "$TRANSPORT_FILTER" ] && [ "$transport" != "$TRANSPORT_FILTER" ]; then
                continue
            fi

            echo "remote-$transport|$url|$tls_disable"
        done
        fi
    fi
}

# Format classification for display
format_classification() {
    local classification="$1"
    case "$classification" in
        at)     echo -e "${GREEN}at-target${NC}" ;;
        ahead)  echo -e "${CYAN}ahead${NC}" ;;
        behind) echo -e "${YELLOW}behind${NC}" ;;
        *)      echo "none" ;;
    esac
}

#############################################################################
# Test Execution
#############################################################################

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# Initialize summary JSON (skip for dry run)
if [ "$DRY_RUN" != true ]; then
    SUMMARY_FILE="$RESULTS_DIR/summary.json"
    jq -n --arg version "$TARGET_VERSION" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{runs: [], target_version: $version, timestamp: $ts}' > "$SUMMARY_FILE"
fi

run_test() {
    local client="$1"
    local relay="$2"
    local version="$3"
    local classification="$4"  # "at", "ahead", or "behind"
    local mode="$5"      # "docker" or "remote-quic" or "remote-webtransport"
    local target="$6"    # image name or URL
    local tls_disable="${7:-false}"

    TOTAL=$((TOTAL + 1))

    # Determine display mode (strip -skip suffix for display)
    local display_mode="${mode%-skip}"
    local test_id="${client}_to_${relay}_${display_mode}"
    local result_file="$RESULTS_DIR/${test_id}.log"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Test: $client → $relay${NC}"
    echo -e "Version: $version | Mode: $display_mode"
    echo -e "Target: $target"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Handle skipped tests (image unavailable)
    if [[ "$mode" == *-skip ]]; then
        local skip_reason
        if [[ "$mode" == "docker-skip" ]]; then
            skip_reason="relay image unavailable: $target"
        else
            local skip_client_image
            skip_client_image=$(jq -r --arg c "$client" '.implementations[$c].roles.client.docker.image // empty' "$CONFIG_FILE")
            skip_reason="client image unavailable: $skip_client_image"
        fi
        echo -e "${YELLOW}⊘ SKIP ($skip_reason)${NC}"
        SKIPPED=$((SKIPPED + 1))
        echo ""

        # Record skip in summary
        local tmp_file
        tmp_file=$(mktemp "${SUMMARY_FILE}.XXXXXX")
        if jq --arg client "$client" \
              --arg relay "$relay" \
              --arg version "$version" \
              --arg classification "$classification" \
              --arg mode "$display_mode" \
              --arg target "$target" \
              --arg skip_reason "$skip_reason" \
              '.runs += [{"client": $client, "relay": $relay, "version": $version, "classification": $classification, "mode": $mode, "target": $target, "status": "skip", "exit_code": 0, "skip_reason": $skip_reason}]' \
              "$SUMMARY_FILE" > "$tmp_file"; then
            mv "$tmp_file" "$SUMMARY_FILE"
        else
            rm -f "$tmp_file"
        fi
        return
    fi

    local status="unknown"
    local exit_code=0

    # Resolve client Docker image from implementations.json
    local client_image
    client_image=$(jq -r --arg c "$client" '.implementations[$c].roles.client.docker.image // empty' "$CONFIG_FILE")
    if [ -z "$client_image" ]; then
        echo -e "${YELLOW}⊘ SKIP (no client docker image configured for $client)${NC}"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    if [[ "$mode" == "docker" ]]; then
        if make test RELAY_IMAGE="$target" CLIENT_IMAGE="$client_image" > "$result_file" 2>&1; then
            status="pass"
            PASSED=$((PASSED + 1))
            echo -e "${GREEN}✓ PASSED${NC}"
        else
            exit_code=$?
            status="fail"
            FAILED=$((FAILED + 1))
            echo -e "${RED}✗ FAILED (exit code: $exit_code)${NC}"
        fi
    else
        # Build make arguments as array to avoid word splitting issues
        local -a make_args=("test-external" "RELAY_URL=$target" "CLIENT_IMAGE=$client_image")
        [ "$tls_disable" = "true" ] && make_args+=("TLS_DISABLE_VERIFY=1")

        if make "${make_args[@]}" > "$result_file" 2>&1; then
            status="pass"
            PASSED=$((PASSED + 1))
            echo -e "${GREEN}✓ PASSED${NC}"
        else
            exit_code=$?
            status="fail"
            FAILED=$((FAILED + 1))
            echo -e "${RED}✗ FAILED (exit code: $exit_code)${NC}"
        fi
    fi

    # Append to summary (using mktemp for safe atomic update)
    local tmp_file
    tmp_file=$(mktemp "${SUMMARY_FILE}.XXXXXX")
    if jq --arg client "$client" \
          --arg relay "$relay" \
          --arg version "$version" \
          --arg classification "$classification" \
          --arg mode "$mode" \
          --arg target "$target" \
          --arg status "$status" \
          --argjson exit_code "$exit_code" \
          '.runs += [{"client": $client, "relay": $relay, "version": $version, "classification": $classification, "mode": $mode, "target": $target, "status": $status, "exit_code": $exit_code}]' \
          "$SUMMARY_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$SUMMARY_FILE"
    else
        rm -f "$tmp_file"
        return 1
    fi

    echo ""
}

#############################################################################
# Main: Plan, Filter, Sort, Execute
#############################################################################

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              MoQT Interop Tests                             ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Target version: ${CYAN}$TARGET_VERSION${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "Mode: ${YELLOW}dry run${NC}"
else
    echo -e "Results: $RESULTS_DIR"
fi
if [ -n "$CLASSIFICATION_FILTER" ]; then
    echo -e "Filter: only ${CLASSIFICATION_FILTER}-target pairs"
fi
echo ""

# Get all clients and relays
if [ -n "$CLIENT_FILTER" ]; then
    CLIENTS_ARR=("$CLIENT_FILTER")
else
    CLIENTS_ARR=()
    while IFS= read -r line; do
        [ -n "$line" ] && CLIENTS_ARR+=("$line")
    done < <(get_impls_with_role "client")
fi

if [ -n "$RELAY_FILTER" ]; then
    RELAYS_ARR=("$RELAY_FILTER")
else
    RELAYS_ARR=()
    while IFS= read -r line; do
        [ -n "$line" ] && RELAYS_ARR+=("$line")
    done < <(get_impls_with_role "relay")
fi

echo -e "${BLUE}Clients:${NC} ${CLIENTS_ARR[*]}"
echo -e "${BLUE}Relays:${NC} ${RELAYS_ARR[*]}"
echo ""

#############################################################################
# Phase 1: Compute test plan
#############################################################################

echo -e "${BLUE}── Test Plan ──${NC}"
echo ""

# Build plan as parallel arrays (Bash 3.2 compatible)
# Each entry represents a single runnable test (one endpoint of one pair)
PLAN_CLIENT=()
PLAN_RELAY=()
PLAN_VERSION=()
PLAN_CLASS=()
PLAN_MODE=()
PLAN_TARGET=()
PLAN_TLS=()

for client in "${CLIENTS_ARR[@]}"; do
    for relay in "${RELAYS_ARR[@]}"; do
        version=$(compute_negotiated_version "$client" "$relay")
        classification=$(classify_version "$version" "$TARGET_VERSION")

        if [ "$classification" = "none" ]; then
            echo -e "  $client → $relay: ${YELLOW}no shared version, skipping${NC}"
            continue
        fi

        class_display=$(format_classification "$classification")

        # Apply classification filter
        if [ -n "$CLASSIFICATION_FILTER" ] && [ "$classification" != "$CLASSIFICATION_FILTER" ]; then
            echo -e "  $client → $relay: $version ($class_display) ${YELLOW}-- filtered (--only-${CLASSIFICATION_FILTER}-target)${NC}"
            continue
        fi

        # Check client image availability (applies to all endpoints for this client)
        client_image=$(jq -r --arg c "$client" '.implementations[$c].roles.client.docker.image // empty' "$CONFIG_FILE")
        client_image_missing=false
        if [ -n "$client_image" ] && ! image_exists "$client_image"; then
            client_image_missing=true
            record_missing_image "$client_image"
        fi

        # Enumerate runnable endpoints for this pair
        endpoints=$(list_endpoints "$relay")
        if [ -z "$endpoints" ]; then
            echo -e "  $client → $relay: $version ($class_display) ${YELLOW}-- no runnable endpoints${NC}"
            continue
        fi

        echo -e "  $client → $relay: $version ($class_display)"
        while IFS='|' read -r mode target tls_disable; do
            [ -z "$mode" ] && continue

            # Determine if this test will be skipped
            effective_mode="$mode"
            if [ "$mode" = "docker-skip" ]; then
                echo -e "    ${YELLOW}docker  $target  [SKIP: relay image unavailable]${NC}"
            elif [ "$client_image_missing" = true ]; then
                effective_mode="${mode}-skip"
                echo -e "    ${YELLOW}$mode  $target  [SKIP: client image unavailable ($client_image)]${NC}"
            else
                echo -e "    $mode  $target"
            fi

            PLAN_CLIENT+=("$client")
            PLAN_RELAY+=("$relay")
            PLAN_VERSION+=("$version")
            PLAN_CLASS+=("$classification")
            PLAN_MODE+=("$effective_mode")
            PLAN_TARGET+=("$target")
            PLAN_TLS+=("$tls_disable")
        done <<< "$endpoints"
    done
done

echo ""

# Sort plan: at-target first, then ahead, then behind
SORTED_INDICES=()
if [ ${#PLAN_CLASS[@]} -gt 0 ]; then
    for class in at ahead behind; do
        for i in $(seq 0 $((${#PLAN_CLASS[@]} - 1))); do
            if [ "${PLAN_CLASS[$i]}" = "$class" ]; then
                SORTED_INDICES+=("$i")
            fi
        done
    done
fi

RUN_COUNT=${#SORTED_INDICES[@]}
echo -e "${BLUE}Runs planned: $RUN_COUNT${NC}"
echo ""

#############################################################################
# Phase 2: Execute (or show dry-run summary)
#############################################################################

if [ "$DRY_RUN" = true ]; then
    if [ "$RUN_COUNT" -eq 0 ]; then
        echo "No tests to run."
    else
        echo -e "${BLUE}── Execution Order ──${NC}"
        echo ""
        local_n=1
        for idx in "${SORTED_INDICES[@]}"; do
            class_display=$(format_classification "${PLAN_CLASS[$idx]}")
            dry_mode="${PLAN_MODE[$idx]}"
            if [[ "$dry_mode" == *-skip ]]; then
                echo -e "  $local_n. ${PLAN_CLIENT[$idx]} → ${PLAN_RELAY[$idx]}  ${PLAN_VERSION[$idx]} ($class_display)  ${dry_mode%-skip}  ${PLAN_TARGET[$idx]}  ${YELLOW}[SKIP: image unavailable]${NC}"
            else
                echo -e "  $local_n. ${PLAN_CLIENT[$idx]} → ${PLAN_RELAY[$idx]}  ${PLAN_VERSION[$idx]} ($class_display)  $dry_mode  ${PLAN_TARGET[$idx]}"
            fi
            local_n=$((local_n + 1))
        done
        echo ""
        echo "Run without --dry-run to execute."
    fi
    exit 0
fi

for idx in "${SORTED_INDICES[@]}"; do
    run_test "${PLAN_CLIENT[$idx]}" "${PLAN_RELAY[$idx]}" "${PLAN_VERSION[$idx]}" \
             "${PLAN_CLASS[$idx]}" "${PLAN_MODE[$idx]}" "${PLAN_TARGET[$idx]}" "${PLAN_TLS[$idx]}"
done

#############################################################################
# Summary
#############################################################################

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                        TEST SUMMARY${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Total:   $TOTAL"
echo -e "${GREEN}Passed:  $PASSED${NC}"
echo -e "${RED}Failed:  $FAILED${NC}"
if [ "$SKIPPED" -gt 0 ]; then
    echo -e "${YELLOW}Skipped: $SKIPPED${NC}"
fi
echo ""

# Print consolidated missing images warning
if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  WARNING: ${#MISSING_IMAGES[@]} Docker image(s) not found — $SKIPPED test(s) skipped${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    for img in "${MISSING_IMAGES[@]}"; do
        echo -e "${YELLOW}    - $img${NC}"
    done
    echo ""
    echo -e "  To build adapter images:  ${CYAN}make build-adapters${NC}"
    echo -e "  To build from source:     ${CYAN}make build-impl IMPL=<name>${NC}"
    echo ""
fi

echo -e "Results saved to: $RESULTS_DIR"
echo -e "Summary JSON: $SUMMARY_FILE"

# Exit with failure if any tests failed
[ $FAILED -gt 0 ] && exit 1
exit 0

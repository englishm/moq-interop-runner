#!/bin/bash
# Run all six draft-18 cases in both xquic roles against five local Docker
# implementations, retaining TAP logs, relay logs, and tcpdump captures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XQUIC_CLIENT_LOCAL_IMAGE="xquic-moq-client-draft-18:latest"
XQUIC_CLIENT_IMAGE="ghcr.io/englishm/moq-interop-runner-xquic-moq-client-draft-18:latest"
XQUIC_RELAY_LOCAL_IMAGE="xquic-moq-relay-draft-18:latest"
XQUIC_RELAY_IMAGE="ghcr.io/englishm/moq-interop-runner-xquic-moq-relay-draft-18:latest"
AIOMOQT_RELAY_IMAGE="aiomoqt-interop-relay-draft-18:local"
CAPTURE_IMAGE="${CAPTURE_IMAGE:-nicolaka/netshoot:latest}"
CLIENT_TIMEOUT_SECONDS="${CLIENT_TIMEOUT_SECONDS:-60}"
SERVER_CLIENT_TIMEOUT_SECONDS="${SERVER_CLIENT_TIMEOUT_SECONDS:-30}"
HOST_PORT="${HOST_PORT:-4443}"

TESTCASES=(
    setup-only
    announce-only
    publish-namespace-done
    subscribe-error
    announce-subscribe
    subscribe-before-announce
)
CLIENT_RELAYS=(
    aiomoqt-relay-quic
    imquic
    moq-rs-draft-18
    moqx
    moxygen
)
SERVER_CLIENTS=(
    aiomoqt
    imquic
    moq-rs-draft-18
    moqx
    moxygen
)

for command_name in docker jq rg git; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "$command_name is required." >&2
        exit 1
    fi
done
if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not available." >&2
    exit 1
fi

if [ -n "${XQUIC_SOURCE:-}" ]; then
    if [ ! -d "$XQUIC_SOURCE" ]; then
        echo "XQUIC_SOURCE does not exist: $XQUIC_SOURCE" >&2
        exit 1
    fi
    "$RUNNER_ROOT/builds/xquic/build.sh" --local "$XQUIC_SOURCE" --target client-draft-18
    "$RUNNER_ROOT/builds/xquic/build.sh" --local "$XQUIC_SOURCE" --target relay-draft-18
fi

if ! docker image inspect "$XQUIC_CLIENT_LOCAL_IMAGE" >/dev/null 2>&1; then
    echo "Missing xquic client image: $XQUIC_CLIENT_LOCAL_IMAGE" >&2
    echo "Set XQUIC_SOURCE=/absolute/path/to/xquic to build the current checkout." >&2
    exit 1
fi
if ! docker image inspect "$XQUIC_RELAY_LOCAL_IMAGE" >/dev/null 2>&1; then
    echo "Missing xquic relay image: $XQUIC_RELAY_LOCAL_IMAGE" >&2
    echo "Set XQUIC_SOURCE=/absolute/path/to/xquic to build the current checkout." >&2
    exit 1
fi
docker tag "$XQUIC_CLIENT_LOCAL_IMAGE" "$XQUIC_CLIENT_IMAGE"
docker tag "$XQUIC_RELAY_LOCAL_IMAGE" "$XQUIC_RELAY_IMAGE"

relay_image() {
    if [ "$1" = "aiomoqt-relay-quic" ]; then
        echo "$AIOMOQT_RELAY_IMAGE"
        return
    fi
    jq -r --arg relay "$1" '.implementations[$relay].roles.relay.docker.image // empty' \
        "$RUNNER_ROOT/implementations.json"
}

ensure_image() {
    local image="$1"
    if docker image inspect "$image" >/dev/null 2>&1; then
        return
    fi
    case "$image" in
        ghcr.io/*)
            if ! docker pull "$image"; then
                docker pull --platform linux/amd64 "$image"
            fi
            ;;
        *)
            echo "Missing local adapter image: $image" >&2
            echo "Build the existing adapters first with: make build-adapters" >&2
            exit 1
            ;;
    esac
}

docker build \
    -f "$RUNNER_ROOT/builds/xquic/Dockerfile.aiomoqt-relay-draft18" \
    -t "$AIOMOQT_RELAY_IMAGE" \
    "$RUNNER_ROOT/builds/xquic" >/dev/null

for relay in "${CLIENT_RELAYS[@]}"; do
    image=$(relay_image "$relay")
    if [ -z "$image" ]; then
        echo "No Docker relay image registered for $relay" >&2
        exit 1
    fi
    ensure_image "$image"
done
if ! docker image inspect "$CAPTURE_IMAGE" >/dev/null 2>&1; then
    docker pull "$CAPTURE_IMAGE"
fi

if [ ! -f "$RUNNER_ROOT/certs/cert.pem" ] || [ ! -f "$RUNNER_ROOT/certs/priv.key" ]; then
    "$RUNNER_ROOT/generate-certs.sh" "$RUNNER_ROOT/certs"
fi

timestamp=$(date +%Y-%m-%d_%H%M%S)
RESULT_DIR="${RESULT_DIR:-$RUNNER_ROOT/results/${timestamp}-xquic-draft18-full-docker}"
mkdir -p "$RESULT_DIR/client" "$RESULT_DIR/server"
RESULT_DIR="$(cd "$RESULT_DIR" && pwd)"
SUMMARY_FILE="$RESULT_DIR/summary.json"
REPORT_FILE="$RESULT_DIR/report.html"

xquic_repo="${XQUIC_SOURCE:-$RUNNER_ROOT/../xquic}"
if [ -d "$xquic_repo/.git" ]; then
    xquic_commit=$(git -C "$xquic_repo" rev-parse HEAD)
    xquic_branch=$(git -C "$xquic_repo" branch --show-current)
else
    xquic_commit="unknown"
    xquic_branch="unknown"
fi
runner_commit=$(git -C "$RUNNER_ROOT" rev-parse HEAD)

jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg runner_commit "$runner_commit" \
    --arg xquic_commit "$xquic_commit" \
    --arg xquic_branch "$xquic_branch" \
    --argjson port "$HOST_PORT" \
    '{target_version:"draft-18", timestamp:$ts, runner_commit:$runner_commit,
      xquic_commit:$xquic_commit, xquic_branch:$xquic_branch,
      server_listen_port:$port,
      testcases:[],
      peers:{"xquic-client":[], "xquic-server":[]}, runs:[]}' \
    > "$SUMMARY_FILE"

# jq cannot receive both fixed options and the Bash array via --args portably
# after named arguments on every supported jq version, so populate the stable
# case/peer arrays explicitly in a second atomic update.
tmp_summary=$(mktemp "${SUMMARY_FILE}.XXXXXX")
jq \
    --argjson testcases \
        '["setup-only","announce-only","publish-namespace-done",
         "subscribe-error","announce-subscribe","subscribe-before-announce"]' \
    --argjson client_peers \
        '["aiomoqt-relay-quic","imquic","moq-rs-draft-18","moqx","moxygen"]' \
    --argjson server_peers \
        '["aiomoqt","imquic","moq-rs-draft-18","moqx","moxygen"]' \
    '.testcases=$testcases | .peers["xquic-client"]=$client_peers |
     .peers["xquic-server"]=$server_peers' \
    "$SUMMARY_FILE" > "$tmp_summary"
mv "$tmp_summary" "$SUMMARY_FILE"

append_result() {
    local direction="$1"
    local peer="$2"
    local testcase="$3"
    local status="$4"
    local exit_code="$5"
    local log="$6"
    local relay_log="$7"
    local pcap="$8"
    local pcap_bytes="$9"
    local image="${10}"
    local evidence="${11}"
    local tmp_file

    tmp_file=$(mktemp "${SUMMARY_FILE}.XXXXXX")
    jq \
        --arg direction "$direction" \
        --arg peer "$peer" \
        --arg testcase "$testcase" \
        --arg status "$status" \
        --arg log "$log" \
        --arg relay_log "$relay_log" \
        --arg pcap "$pcap" \
        --arg image "$image" \
        --arg evidence "$evidence" \
        --argjson exit_code "$exit_code" \
        --argjson pcap_bytes "$pcap_bytes" \
        '.runs += [{direction:$direction, peer:$peer, testcase:$testcase,
                    status:$status, exit_code:$exit_code, log:$log,
                    relay_log:$relay_log, pcap:$pcap,
                    pcap_bytes:$pcap_bytes, image:$image,
                    evidence:$evidence}]' \
        "$SUMMARY_FILE" > "$tmp_file"
    mv "$tmp_file" "$SUMMARY_FILE"
}

tap_case_status() {
    local logfile="$1"
    local testcase="$2"
    if rg -q "^[[:space:]]*not ok [0-9]+ - ${testcase}([[:space:]]|$)" "$logfile"; then
        echo "fail"
    elif rg -q "^[[:space:]]*ok [0-9]+ - ${testcase}([[:space:]]|$)" "$logfile"; then
        echo "pass"
    else
        echo "missing"
    fi
}

CURRENT_NETWORK=""
CURRENT_RELAY_CONTAINER=""
CURRENT_CAPTURE_CONTAINER=""
CURRENT_CLIENT_CONTAINER=""
CURRENT_CERT_LOADER_CONTAINER=""
CURRENT_CERT_VOLUME=""
CURRENT_CAPTURE_VOLUME=""
cleanup_client_run() {
    [ -n "$CURRENT_CLIENT_CONTAINER" ] && docker rm -f "$CURRENT_CLIENT_CONTAINER" >/dev/null 2>&1 || true
    [ -n "$CURRENT_CAPTURE_CONTAINER" ] && docker rm -f "$CURRENT_CAPTURE_CONTAINER" >/dev/null 2>&1 || true
    [ -n "$CURRENT_RELAY_CONTAINER" ] && docker rm -f "$CURRENT_RELAY_CONTAINER" >/dev/null 2>&1 || true
    [ -n "$CURRENT_CERT_LOADER_CONTAINER" ] && docker rm -f "$CURRENT_CERT_LOADER_CONTAINER" >/dev/null 2>&1 || true
    [ -n "$CURRENT_NETWORK" ] && docker network rm "$CURRENT_NETWORK" >/dev/null 2>&1 || true
    [ -n "$CURRENT_CERT_VOLUME" ] && docker volume rm "$CURRENT_CERT_VOLUME" >/dev/null 2>&1 || true
    [ -n "$CURRENT_CAPTURE_VOLUME" ] && docker volume rm "$CURRENT_CAPTURE_VOLUME" >/dev/null 2>&1 || true
    CURRENT_NETWORK=""
    CURRENT_RELAY_CONTAINER=""
    CURRENT_CAPTURE_CONTAINER=""
    CURRENT_CLIENT_CONTAINER=""
    CURRENT_CERT_LOADER_CONTAINER=""
    CURRENT_CERT_VOLUME=""
    CURRENT_CAPTURE_VOLUME=""
}
trap cleanup_client_run EXIT

gate_failed=0
suffix="$$"
for relay in "${CLIENT_RELAYS[@]}"; do
    image=$(relay_image "$relay")
    safe_relay=$(printf '%s' "$relay" | tr -c 'a-zA-Z0-9_.-' '-')
    CURRENT_NETWORK="xquic-full-${safe_relay}-${suffix}"
    CURRENT_RELAY_CONTAINER="xquic-full-relay-${safe_relay}-${suffix}"
    CURRENT_CAPTURE_CONTAINER="xquic-full-capture-${safe_relay}-${suffix}"
    CURRENT_CLIENT_CONTAINER="xquic-full-client-${safe_relay}-${suffix}"
    CURRENT_CERT_LOADER_CONTAINER="xquic-full-certs-${safe_relay}-${suffix}"
    CURRENT_CERT_VOLUME="xquic-full-certs-${safe_relay}-${suffix}"
    CURRENT_CAPTURE_VOLUME="xquic-full-capture-${safe_relay}-${suffix}"
    log_rel="client/xquic-to-${relay}.log"
    relay_log_rel="client/${relay}-relay.log"
    pcap_rel="client/xquic-to-${relay}.pcap"
    log_file="$RESULT_DIR/$log_rel"
    relay_log_file="$RESULT_DIR/$relay_log_rel"
    pcap_file="$RESULT_DIR/$pcap_rel"

    echo "Client matrix: xquic-draft-18 -> $relay"
    docker network create "$CURRENT_NETWORK" >/dev/null
    docker volume create "$CURRENT_CERT_VOLUME" >/dev/null
    docker volume create "$CURRENT_CAPTURE_VOLUME" >/dev/null
    docker create --name "$CURRENT_CERT_LOADER_CONTAINER" \
        -v "$CURRENT_CERT_VOLUME:/certs" ubuntu:22.04 true >/dev/null
    docker cp "$RUNNER_ROOT/certs/cert.pem" \
        "$CURRENT_CERT_LOADER_CONTAINER:/certs/cert.pem"
    docker cp "$RUNNER_ROOT/certs/priv.key" \
        "$CURRENT_CERT_LOADER_CONTAINER:/certs/priv.key"
    docker rm "$CURRENT_CERT_LOADER_CONTAINER" >/dev/null
    CURRENT_CERT_LOADER_CONTAINER=""
    docker run -d \
        --name "$CURRENT_RELAY_CONTAINER" \
        --network "$CURRENT_NETWORK" \
        --network-alias relay \
        -v "$CURRENT_CERT_VOLUME:/certs:ro" \
        -e MOQT_ROLE=relay \
        -e MOQT_PORT=4443 \
        "$image" >/dev/null

    healthy=false
    for attempt in $(seq 1 35); do
        state=$(docker inspect --format '{{.State.Status}}' "$CURRENT_RELAY_CONTAINER" 2>/dev/null || true)
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CURRENT_RELAY_CONTAINER" 2>/dev/null || true)
        if [ "$health" = "healthy" ] || { [ "$health" = "none" ] && [ "$state" = "running" ] && [ "$attempt" -ge 5 ]; }; then
            healthy=true
            break
        fi
        if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
            break
        fi
        sleep 1
    done

    if [ "$healthy" != true ]; then
        docker logs "$CURRENT_RELAY_CONTAINER" > "$relay_log_file" 2>&1 || true
        echo "  relay failed to become healthy"
        for testcase in "${TESTCASES[@]}"; do
            append_result "xquic-client" "$relay" "$testcase" "missing" 125 \
                "$log_rel" "$relay_log_rel" "$pcap_rel" 0 "$image" \
                "External relay did not become healthy"
        done
        gate_failed=$((gate_failed + 6))
        cleanup_client_run
        continue
    fi

    docker run -d \
        --name "$CURRENT_CAPTURE_CONTAINER" \
        --network "container:$CURRENT_RELAY_CONTAINER" \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        -v "$CURRENT_CAPTURE_VOLUME:/captures" \
        "$CAPTURE_IMAGE" \
        tcpdump -i any -s 0 -U -w "/captures/$(basename "$pcap_file")" \
            udp port 4443 >/dev/null
    sleep 1

    set +e
    docker run --name "$CURRENT_CLIENT_CONTAINER" \
        --network "$CURRENT_NETWORK" \
        -v "$CURRENT_CERT_VOLUME:/certs:ro" \
        -e RELAY_URL="moqt://relay:4443" \
        -e DRAFT=18 \
        -e MOQT_DRAFT=18 \
        -e TLS_DISABLE_VERIFY=1 \
        -e VERBOSE=1 \
        "$XQUIC_CLIENT_IMAGE" > "$log_file" 2>&1 &
    docker_pid=$!
    deadline=$((SECONDS + CLIENT_TIMEOUT_SECONDS))
    timed_out=0
    while kill -0 "$docker_pid" >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            timed_out=1
            docker rm -f "$CURRENT_CLIENT_CONTAINER" >/dev/null 2>&1
            wait "$docker_pid" >/dev/null 2>&1
            break
        fi
        sleep 1
    done
    if [ "$timed_out" -eq 1 ]; then
        client_exit=124
        echo "client timed out after ${CLIENT_TIMEOUT_SECONDS}s" >> "$log_file"
    else
        wait "$docker_pid"
        client_exit=$?
    fi
    set -e
    docker rm -f "$CURRENT_CLIENT_CONTAINER" >/dev/null 2>&1 || true
    CURRENT_CLIENT_CONTAINER=""

    docker logs "$CURRENT_RELAY_CONTAINER" > "$relay_log_file" 2>&1 || true
    docker stop --time 5 "$CURRENT_CAPTURE_CONTAINER" >/dev/null 2>&1 || true
    docker cp "$CURRENT_CAPTURE_CONTAINER:/captures/$(basename "$pcap_file")" \
        "$pcap_file" >/dev/null 2>&1 || true
    docker rm "$CURRENT_CAPTURE_CONTAINER" >/dev/null 2>&1 || true
    CURRENT_CAPTURE_CONTAINER=""
    pcap_bytes=$(wc -c < "$pcap_file" 2>/dev/null || echo 0)
    if [ "$pcap_bytes" -le 24 ]; then
        gate_failed=$((gate_failed + 1))
    fi

    for testcase in "${TESTCASES[@]}"; do
        case_status=$(tap_case_status "$log_file" "$testcase")
        evidence="TAP result parsed from the fresh xquic client run; container exit $client_exit"
        if [ "$pcap_bytes" -le 24 ]; then
            evidence="$evidence; packet capture is empty"
        fi
        append_result "xquic-client" "$relay" "$testcase" "$case_status" "$client_exit" \
            "$log_rel" "$relay_log_rel" "$pcap_rel" "$pcap_bytes" "$image" "$evidence"
        if [ "$case_status" != "pass" ]; then
            gate_failed=$((gate_failed + 1))
        fi
    done
    cleanup_client_run
done

server_clients_string="${SERVER_CLIENTS[*]}"
for testcase in "${TESTCASES[@]}"; do
    server_case_dir="$RESULT_DIR/server/$testcase"
    echo "Server matrix: five clients -> xquic-draft-18 ($testcase)"
    set +e
    RESULT_DIR="$server_case_dir" \
        CLIENTS="$server_clients_string" \
        CLIENT_TIMEOUT_SECONDS="$SERVER_CLIENT_TIMEOUT_SECONDS" \
        HOST_PORT="$HOST_PORT" \
        "$RUNNER_ROOT/scripts/test-xquic-server-draft18.sh" "$testcase"
    server_gate_exit=$?
    set -e

    server_summary="$server_case_dir/summary.json"
    pcap_rel="server/$testcase/xquic-server-draft18-${testcase}.pcap"
    pcap_file="$RESULT_DIR/$pcap_rel"
    pcap_bytes=$(wc -c < "$pcap_file" 2>/dev/null || echo 0)
    if [ ! -f "$server_summary" ]; then
        for client in "${SERVER_CLIENTS[@]}"; do
            append_result "xquic-server" "$client" "$testcase" "missing" "$server_gate_exit" \
                "server/$testcase/${client}_to_xquic-draft-18_docker.log" \
                "server/$testcase/relay.log" "$pcap_rel" "$pcap_bytes" "$XQUIC_RELAY_IMAGE" \
                "Server-side case gate did not produce summary.json"
            gate_failed=$((gate_failed + 1))
        done
        continue
    fi

    for client in "${SERVER_CLIENTS[@]}"; do
        status=$(jq -r --arg client "$client" '.runs[]? | select(.client == $client) | .status' "$server_summary" | head -n 1)
        exit_code=$(jq -r --arg client "$client" '.runs[]? | select(.client == $client) | .exit_code' "$server_summary" | head -n 1)
        evidence=$(jq -r --arg client "$client" '.runs[]? | select(.client == $client) | .evidence // empty' "$server_summary" | head -n 1)
        client_image=$(jq -r --arg client "$client" '.runs[]? | select(.client == $client) | .client_image // empty' "$server_summary" | head -n 1)
        if [ -z "$status" ]; then
            status="missing"
            exit_code=125
            evidence="No result row was produced for the external client"
        fi
        [ -n "$evidence" ] || evidence="Fresh external-client TAP result; server case gate exit $server_gate_exit"
        append_result "xquic-server" "$client" "$testcase" "$status" "$exit_code" \
            "server/$testcase/${client}_to_xquic-draft-18_docker.log" \
            "server/$testcase/relay.log" "$pcap_rel" "$pcap_bytes" "$client_image" "$evidence"
        if [ "$status" != "pass" ]; then
            gate_failed=$((gate_failed + 1))
        fi
    done
    if [ "$pcap_bytes" -le 24 ]; then
        gate_failed=$((gate_failed + 1))
    fi
done

CASE_SUMMARY_FILE="$RESULT_DIR/case-summary.json"
mv "$SUMMARY_FILE" "$CASE_SUMMARY_FILE"

# Convert the 60 case-level gate rows into the runner's normal ten-run shape:
# one six-test TAP log for each client/relay pair. generate-report.sh can then
# render this run with exactly the same matrix and detail format as published
# moq-interop-runner reports, while case-summary.json retains full evidence.
jq '{target_version, timestamp, runner_commit, xquic_commit, xquic_branch,
     server_listen_port, case_summary:"case-summary.json", runs:[]}' \
    "$CASE_SUMMARY_FILE" > "$SUMMARY_FILE"

append_standard_run() {
    local client="$1"
    local relay="$2"
    local status="$3"
    local exit_code="$4"
    local target="$5"
    local evidence="$6"
    local pcap="$7"
    local pcap_bytes="$8"
    local tmp_file

    tmp_file=$(mktemp "${SUMMARY_FILE}.XXXXXX")
    jq \
        --arg client "$client" \
        --arg relay "$relay" \
        --arg status "$status" \
        --arg target "$target" \
        --arg evidence "$evidence" \
        --arg pcap "$pcap" \
        --argjson exit_code "$exit_code" \
        --argjson pcap_bytes "$pcap_bytes" \
        '.runs += [{client:$client, relay:$relay, version:"draft-18",
                    classification:"at", mode:"docker", target:$target,
                    status:$status, exit_code:$exit_code,
                    evidence:$evidence, pcap:$pcap,
                    pcap_bytes:$pcap_bytes}]' \
        "$SUMMARY_FILE" > "$tmp_file"
    mv "$tmp_file" "$SUMMARY_FILE"
}

for direction in xquic-client xquic-server; do
    while IFS= read -r peer; do
        if [ "$direction" = "xquic-client" ]; then
            standard_client="xquic-draft-18"
            standard_relay="$peer"
        else
            standard_client="$peer"
            standard_relay="xquic-draft-18"
        fi
        aggregate_log="$RESULT_DIR/${standard_client}_to_${standard_relay}_docker.log"
        printf 'TAP version 14\n1..6\n' > "$aggregate_log"

        case_number=0
        pair_passed=0
        pair_exit=0
        pair_image=""
        pair_pcap=""
        pair_pcap_bytes=0
        first_failure=""
        while IFS= read -r testcase; do
            case_number=$((case_number + 1))
            row=$(jq -c \
                --arg direction "$direction" \
                --arg peer "$peer" \
                --arg testcase "$testcase" \
                '[.runs[] | select(.direction==$direction and .peer==$peer and .testcase==$testcase)][0]' \
                "$CASE_SUMMARY_FILE")
            case_status=$(printf '%s' "$row" | jq -r '.status // "missing"')
            case_exit=$(printf '%s' "$row" | jq -r '.exit_code // 125')
            source_log=$(printf '%s' "$row" | jq -r '.log // "unavailable"')
            case_evidence=$(printf '%s' "$row" | jq -r '.evidence // empty')
            [ -n "$pair_image" ] || pair_image=$(printf '%s' "$row" | jq -r '.image // empty')
            [ -n "$pair_pcap" ] || pair_pcap=$(printf '%s' "$row" | jq -r '.pcap // empty')
            if [ "$pair_pcap_bytes" -eq 0 ]; then
                pair_pcap_bytes=$(printf '%s' "$row" | jq -r '.pcap_bytes // 0')
            fi

            if [ "$case_status" = "pass" ]; then
                pair_passed=$((pair_passed + 1))
                printf 'ok %s - %s\n' "$case_number" "$testcase" >> "$aggregate_log"
            else
                [ "$pair_exit" -ne 0 ] || pair_exit="$case_exit"
                [ -n "$first_failure" ] || first_failure="$testcase: $case_status (exit $case_exit)"
                printf 'not ok %s - %s\n' "$case_number" "$testcase" >> "$aggregate_log"
            fi
            printf '    # source log: %s\n' "$source_log" >> "$aggregate_log"
            [ -n "$case_evidence" ] && printf '    # evidence: %s\n' "$case_evidence" >> "$aggregate_log"
        done < <(jq -r '.testcases[]' "$CASE_SUMMARY_FILE")

        if [ "$pair_passed" -eq 6 ]; then
            pair_status="pass"
            pair_exit=0
            pair_evidence="6/6 draft-18 cases passed; tcpdump: $pair_pcap ($pair_pcap_bytes bytes)"
        else
            pair_status="fail"
            [ "$pair_exit" -ne 0 ] || pair_exit=1
            pair_evidence="$pair_passed/6 draft-18 cases passed; $first_failure; tcpdump: $pair_pcap ($pair_pcap_bytes bytes)"
        fi
        append_standard_run "$standard_client" "$standard_relay" "$pair_status" \
            "$pair_exit" "$pair_image" "$pair_evidence" "$pair_pcap" "$pair_pcap_bytes"
    done < <(jq -r --arg direction "$direction" '.peers[$direction][]' "$CASE_SUMMARY_FILE")
done

"$RUNNER_ROOT/generate-report.sh" "$RESULT_DIR"

total=$(jq '.runs | length' "$SUMMARY_FILE")
passed=$(jq '[.runs[] | select(.status == "pass")] | length' "$SUMMARY_FILE")
failed=$(jq '[.runs[] | select(.status == "fail")] | length' "$SUMMARY_FILE")
case_total=$(jq '.runs | length' "$CASE_SUMMARY_FILE")
case_passed=$(jq '[.runs[] | select(.status == "pass")] | length' "$CASE_SUMMARY_FILE")
case_failed=$(jq '[.runs[] | select(.status != "pass")] | length' "$CASE_SUMMARY_FILE")
echo "Results directory: $RESULT_DIR"
echo "HTML report: $REPORT_FILE"
echo "Summary JSON: $SUMMARY_FILE"
echo "Pair runs: $total; passed: $passed; failed: $failed"
echo "Case executions: $case_total; passed: $case_passed; failed/missing: $case_failed"
echo "Server listen port: ${HOST_PORT}/udp"

[ "$gate_failed" -eq 0 ]

#!/bin/bash
# Run one xquic draft-18 relay case against the default or CLIENTS-selected
# interop clients. Keep the TAP logs, HTML report, relay log, and packet trace.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_RELAY_IMAGE="xquic-moq-relay-draft-18:latest"
REGISTERED_RELAY_IMAGE="ghcr.io/englishm/moq-interop-runner-xquic-moq-relay-draft-18:latest"
AIOMOQT_DRAFT18_IMAGE="aiomoqt-interop-client-draft-18:local"
MOXYGEN_DRAFT18_IMAGE="moxygen-interop-client-draft-18:local"
CAPTURE_IMAGE="${CAPTURE_IMAGE:-nicolaka/netshoot:latest}"
HOST_PORT="${HOST_PORT:-4443}"
CLIENT_TIMEOUT_SECONDS="${CLIENT_TIMEOUT_SECONDS:-60}"

TESTCASE="${1:-}"
case "$TESTCASE" in
    setup-only|announce-only|publish-namespace-done|subscribe-error|announce-subscribe|subscribe-before-announce)
        ;;
    *)
        echo "Usage: $0 <testcase>" >&2
        exit 2
        ;;
esac

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Docker is required and its daemon must be running." >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required." >&2
    exit 1
fi

if [ -n "${XQUIC_SOURCE:-}" ]; then
    "$RUNNER_ROOT/builds/xquic/build.sh" \
        --local "$XQUIC_SOURCE" \
        --target relay-draft-18
fi

if ! docker image inspect "$LOCAL_RELAY_IMAGE" >/dev/null 2>&1; then
    echo "Missing local relay image: $LOCAL_RELAY_IMAGE" >&2
    echo "Build it with XQUIC_SOURCE=/absolute/path/to/xquic." >&2
    exit 1
fi
docker tag "$LOCAL_RELAY_IMAGE" "$REGISTERED_RELAY_IMAGE"

docker build \
    -f "$RUNNER_ROOT/builds/xquic/Dockerfile.aiomoqt-client-draft18" \
    -t "$AIOMOQT_DRAFT18_IMAGE" \
    "$RUNNER_ROOT/builds/xquic" >/dev/null

docker build --platform linux/amd64 \
    -f "$RUNNER_ROOT/builds/xquic/Dockerfile.moxygen-client-draft18" \
    -t "$MOXYGEN_DRAFT18_IMAGE" \
    "$RUNNER_ROOT/builds/xquic" >/dev/null

client_image() {
    local client="$1"
    if [ "$client" = "aiomoqt" ]; then
        echo "$AIOMOQT_DRAFT18_IMAGE"
        return
    fi
    if [ "$client" = "moxygen" ]; then
        echo "$MOXYGEN_DRAFT18_IMAGE"
        return
    fi
    jq -r --arg client "$client" \
        '.implementations[$client].roles.client.docker.image // empty' \
        "$RUNNER_ROOT/implementations.json"
}

client_testcase() {
    local client="$1"
    local testcase="$2"
    if [ "$client" = "moq-rs-draft-18" ]; then
        case "$testcase" in
            announce-only)
                echo "publish-namespace-only"
                return
                ;;
            announce-subscribe)
                echo "publish-namespace-subscribe"
                return
                ;;
            subscribe-before-announce)
                echo "subscribe-before-publish-namespace"
                return
                ;;
        esac
    fi
    echo "$testcase"
}

CLIENTS="${CLIENTS:-aiomoqt moq-rs-draft-18 moxygen xquic-draft-18}"
for client in $CLIENTS; do
    image=$(client_image "$client")
    if [ -z "$image" ]; then
        echo "No client image registered for $client" >&2
        exit 1
    fi
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        if ! docker pull "$image"; then
            docker pull --platform linux/amd64 "$image"
        fi
    fi
done
if ! docker image inspect "$CAPTURE_IMAGE" >/dev/null 2>&1; then
    docker pull "$CAPTURE_IMAGE"
fi

if [ ! -f "$RUNNER_ROOT/certs/cert.pem" ] || [ ! -f "$RUNNER_ROOT/certs/priv.key" ]; then
    "$RUNNER_ROOT/generate-certs.sh" "$RUNNER_ROOT/certs"
fi

timestamp=$(date +%Y-%m-%d_%H%M%S)
RESULT_DIR="${RESULT_DIR:-$RUNNER_ROOT/results/${timestamp}-xquic-server-draft18-${TESTCASE}}"
mkdir -p "$RESULT_DIR"
RESULT_DIR="$(cd "$RESULT_DIR" && pwd)"
SUMMARY_FILE="$RESULT_DIR/summary.json"
PCAP_FILE="$RESULT_DIR/xquic-server-draft18-${TESTCASE}.pcap"

suffix="$$"
NETWORK="xquic-draft18-${TESTCASE}-${suffix}"
RELAY_CONTAINER="xquic-draft18-relay-${suffix}"
CAPTURE_CONTAINER="xquic-draft18-capture-${suffix}"
CERT_LOADER_CONTAINER="xquic-draft18-certs-${suffix}"
CERT_VOLUME="xquic-draft18-certs-${suffix}"
CAPTURE_VOLUME="xquic-draft18-capture-${suffix}"
ACTIVE_CLIENT_CONTAINER=""

cleanup() {
    if [ -n "$ACTIVE_CLIENT_CONTAINER" ]; then
        docker rm -f "$ACTIVE_CLIENT_CONTAINER" >/dev/null 2>&1 || true
    fi
    docker rm -f "$CAPTURE_CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$RELAY_CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$CERT_LOADER_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$CERT_VOLUME" >/dev/null 2>&1 || true
    docker volume rm "$CAPTURE_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

jq -n \
    --arg version "draft-18" \
    --arg testcase "$TESTCASE" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pcap "$(basename "$PCAP_FILE")" \
    --argjson port "$HOST_PORT" \
    '{runs: [], target_version: $version, testcase: $testcase,
      timestamp: $ts, pcap: $pcap, server_listen_port: $port}' \
    > "$SUMMARY_FILE"

docker network create "$NETWORK" >/dev/null
docker volume create "$CERT_VOLUME" >/dev/null
docker volume create "$CAPTURE_VOLUME" >/dev/null
docker create --name "$CERT_LOADER_CONTAINER" \
    -v "$CERT_VOLUME:/certs" ubuntu:22.04 true >/dev/null
docker cp "$RUNNER_ROOT/certs/cert.pem" \
    "$CERT_LOADER_CONTAINER:/certs/cert.pem"
docker cp "$RUNNER_ROOT/certs/priv.key" \
    "$CERT_LOADER_CONTAINER:/certs/priv.key"
docker rm "$CERT_LOADER_CONTAINER" >/dev/null

docker run -d \
    --name "$RELAY_CONTAINER" \
    --network "$NETWORK" \
    --network-alias relay \
    -p "${HOST_PORT}:4443/udp" \
    -v "$CERT_VOLUME:/certs:ro" \
    -e MOQT_ROLE=relay \
    -e MOQT_PORT=4443 \
    "$REGISTERED_RELAY_IMAGE" >/dev/null

healthy=false
for _attempt in $(seq 1 30); do
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$RELAY_CONTAINER" 2>/dev/null || true)
    if [ "$health" = "healthy" ]; then
        healthy=true
        break
    fi
    if [ "$health" = "exited" ] || [ "$health" = "dead" ]; then
        break
    fi
    sleep 1
done
if [ "$healthy" != true ]; then
    docker logs "$RELAY_CONTAINER" > "$RESULT_DIR/relay.log" 2>&1 || true
    echo "xquic relay did not become healthy; see $RESULT_DIR/relay.log" >&2
    exit 1
fi

docker run -d \
    --name "$CAPTURE_CONTAINER" \
    --network "container:$RELAY_CONTAINER" \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    -v "$CAPTURE_VOLUME:/captures" \
    "$CAPTURE_IMAGE" \
    tcpdump -i any -s 0 -U -w "/captures/$(basename "$PCAP_FILE")" \
        udp port 4443 >/dev/null
sleep 1

failed=0
for client in $CLIENTS; do
    image=$(client_image "$client")
    effective_testcase=$(client_testcase "$client" "$TESTCASE")
    log_file="$RESULT_DIR/${client}_to_xquic-draft-18_docker.log"
    client_container="xquic-draft18-client-${client}-${suffix}"
    ACTIVE_CLIENT_CONTAINER="$client_container"

    namespace_done_before=0
    namespace_cleanup_before=0
    request_error_before=0
    if [ "$TESTCASE" = "publish-namespace-done" ]; then
        namespace_done_before=$(docker logs "$RELAY_CONTAINER" 2>&1 \
            | grep -c 'draft18_relay_namespace_done' || true)
        namespace_cleanup_before=$(docker logs "$RELAY_CONTAINER" 2>&1 \
            | grep -c 'draft18_relay_namespace_cleanup source:session_close' || true)
    elif [ "$TESTCASE" = "subscribe-error" ]; then
        request_error_before=$(docker logs "$RELAY_CONTAINER" 2>&1 \
            | grep -c 'draft18_relay_request_error' || true)
    fi

    echo "Running $TESTCASE: $client -> xquic-draft-18"
    set +e
    docker run --name "$client_container" \
        --network "$NETWORK" \
        -v "$CERT_VOLUME:/certs:ro" \
        -e RELAY_URL="moqt://relay:4443" \
        -e TESTCASE="$effective_testcase" \
        -e DRAFT=18 \
        -e MOQT_DRAFT=18 \
        -e TLS_DISABLE_VERIFY=1 \
        -e VERBOSE=1 \
        "$image" > "$log_file" 2>&1 &
    docker_pid=$!
    deadline=$((SECONDS + CLIENT_TIMEOUT_SECONDS))
    timed_out=0
    while kill -0 "$docker_pid" >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            timed_out=1
            docker rm -f "$client_container" >/dev/null 2>&1
            wait "$docker_pid" >/dev/null 2>&1
            break
        fi
        sleep 1
    done
    if [ "$timed_out" -eq 1 ]; then
        exit_code=124
        echo "client timed out after ${CLIENT_TIMEOUT_SECONDS}s" >> "$log_file"
    else
        wait "$docker_pid"
        exit_code=$?
    fi
    docker rm -f "$client_container" >/dev/null 2>&1
    ACTIVE_CLIENT_CONTAINER=""
    set -e

    evidence=""
    if [ "$TESTCASE" = "publish-namespace-done" ]; then
        # The relay entrypoint line-buffers stdout, so this checks server-side
        # state after the client has finished instead of trusting TAP alone.
        sleep 1
        namespace_done_after=$(docker logs "$RELAY_CONTAINER" 2>&1 \
            | grep -c 'draft18_relay_namespace_done' || true)
        namespace_cleanup_after=$(docker logs "$RELAY_CONTAINER" 2>&1 \
            | grep -c 'draft18_relay_namespace_cleanup source:session_close' || true)
        if [ "$namespace_done_after" -gt "$namespace_done_before" ]; then
            evidence="Relay removed the namespace after an explicit request withdrawal"
        elif [ "$namespace_cleanup_after" -gt "$namespace_cleanup_before" ]; then
            evidence="Relay removed the namespace on session close; no request withdrawal was observed"
        else
            evidence="No relay-side namespace removal was observed"
        fi
    elif [ "$TESTCASE" = "subscribe-error" ]; then
        sleep 1
        request_error_after=$(docker logs "$RELAY_CONTAINER" 2>&1 \
            | grep -c 'draft18_relay_request_error' || true)
        if [ "$request_error_after" -gt "$request_error_before" ]; then
            evidence="Relay returned REQUEST_ERROR (DOES_NOT_EXIST) on the SUBSCRIBE request stream"
        else
            evidence="No relay-side REQUEST_ERROR was observed"
        fi
    fi

    if [ "$exit_code" -eq 0 ]; then
        status="pass"
        echo "  PASS"
    else
        status="fail"
        failed=$((failed + 1))
        echo "  FAIL (exit $exit_code)"
    fi

    tmp_summary=$(mktemp "${SUMMARY_FILE}.XXXXXX")
    jq \
        --arg client "$client" \
        --arg testcase "$TESTCASE" \
        --arg status "$status" \
        --arg target "$REGISTERED_RELAY_IMAGE" \
        --arg client_image "$image" \
        --arg client_testcase "$effective_testcase" \
        --arg evidence "$evidence" \
        --argjson exit_code "$exit_code" \
        '.runs += [{client: $client, relay: "xquic-draft-18",
                    version: "draft-18", classification: "at", mode: "docker",
                    target: $target, client_image: $client_image,
                    client_testcase: $client_testcase, testcase: $testcase,
                    status: $status, exit_code: $exit_code,
                    evidence: $evidence}]' \
        "$SUMMARY_FILE" > "$tmp_summary"
    mv "$tmp_summary" "$SUMMARY_FILE"
done

docker stop --time 5 "$RELAY_CONTAINER" >/dev/null 2>&1 || true
docker logs "$RELAY_CONTAINER" > "$RESULT_DIR/relay.log" 2>&1 || true
docker cp "$RELAY_CONTAINER:/tmp/slog" \
    "$RESULT_DIR/relay-xquic.log" >/dev/null 2>&1 || true
docker stop --time 5 "$CAPTURE_CONTAINER" >/dev/null 2>&1 || true
docker cp "$CAPTURE_CONTAINER:/captures/$(basename "$PCAP_FILE")" \
    "$PCAP_FILE" >/dev/null
docker rm "$CAPTURE_CONTAINER" >/dev/null 2>&1 || true

pcap_size=$(wc -c < "$PCAP_FILE" 2>/dev/null || echo 0)
if [ "$pcap_size" -le 24 ]; then
    echo "Packet capture is empty: $PCAP_FILE" >&2
    failed=$((failed + 1))
fi

"$RUNNER_ROOT/generate-report.sh" "$RESULT_DIR"

echo "Results directory: $RESULT_DIR"
echo "HTML report: $RESULT_DIR/report.html"
echo "Packet capture: $PCAP_FILE ($pcap_size bytes)"
echo "Server listen port: ${HOST_PORT}/udp"

[ "$failed" -eq 0 ]

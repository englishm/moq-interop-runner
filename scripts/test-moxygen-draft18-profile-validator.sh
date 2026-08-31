#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE="$ROOT_DIR/docs/moxygen-draft18-support-profile.json"
SCHEMA="$ROOT_DIR/docs/moxygen-draft18-support-profile.schema.json"
PROFILE_VALIDATOR="$ROOT_DIR/scripts/validate-moxygen-draft18-profile.sh"
RESULT_VALIDATOR="$ROOT_DIR/scripts/validate-moxygen-draft18-result.sh"
SCHEMA_VALIDATOR="$ROOT_DIR/scripts/validate-moxygen-draft18-schema.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

expect_profile_failure() {
  local name=$1
  local filter=$2
  local mutated="$TMP_DIR/profile-mutated.json"

  jq "$filter" "$PROFILE" > "$mutated"
  if "$PROFILE_VALIDATOR" "$mutated" "$SCHEMA" >/dev/null 2>&1; then
    echo "ERROR: profile mutation passed: $name" >&2
    exit 1
  fi
}

expect_schema_failure() {
  local name=$1
  local filter=$2
  local mutated="$TMP_DIR/schema-mutated.json"

  jq "$filter" "$SCHEMA" > "$mutated"
  if "$SCHEMA_VALIDATOR" "$PROFILE" "$mutated" >/dev/null 2>&1; then
    echo "ERROR: schema mutation passed: $name" >&2
    exit 1
  fi
}

expect_result_failure() {
  local name=$1
  local filter=$2
  local mutated="$TMP_DIR/result-mutated.json"

  jq "$filter" "$TMP_DIR/result-valid.json" > "$mutated"
  if "$RESULT_VALIDATOR" "$mutated" "$PROFILE" >/dev/null 2>&1; then
    echo "ERROR: result mutation passed: $name" >&2
    exit 1
  fi
}

jq -n '
  def deployment($name; $role): {
    name: $name,
    role: $role,
    visibility: "reproducible",
    version: "test-v1",
    source_sha: "1111111111111111111111111111111111111111",
    image_digest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    opaque: null
  };
  def evidence($id; $category; $kind; $producer): {
    id: $id,
    category: $category,
    kind: $kind,
    sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    media_type: "application/json",
    byte_length: 1,
    producer: $producer,
    captured_at_utc: "2026-08-31T12:00:00Z",
    locator: ("artifact:" + $id)
  };
  {
    identity: {
      record_id: "record-1",
      run_id: "run-1",
      profile_id: "moxygen-draft18-support-profile",
      profile_version: "1.0.0",
      profile_revision: 1,
      gate_id: "MOXYGEN-D18-DG-001",
      gate_revision: 1,
      driver_binding: "independent_moq_test_client",
      source_binding: null
    },
    disposition: "intended",
    execution: "completed",
    evaluator_verdict: "pass",
    claimed_outcome: "pass",
    failure_classification: "none",
    independence_class: "independent-generator-and-oracle",
    reproducibility: "reproducible",
    evidence_integrity_verification: "verified",
    provenance_verification: "verified",
    opaque_limitations: [],
    protocol: {transport: "raw-quic", negotiated_draft: "draft-18", transport_alpn: "moqt-18", webtransport_protocol: null},
    revisions: {
      schema_version: "1.0.0",
      profile_version: "1.0.0",
      profile_revision: 1,
      gate_revision: 1,
      normative_draft_sha: "cb2e772fd8ca8cbe7550b1765c269be89fb1c886",
      moxygen_declaration_baseline_sha: "0d886e3e907e2236a6d927afefd09bb0c3dc8211",
      moq_rs_review_baseline_sha: "b01d3f6707e3a74f69905722b451a08cbb3364f3",
      runner_sha: "2222222222222222222222222222222222222222",
      driver_landing_sha: "3333333333333333333333333333333333333333"
    },
    deployments: {
      publisher: deployment("fixture-publisher"; "publisher"),
      relay: deployment("relay-under-test"; "relay"),
      subscriber: deployment("fixture-subscriber"; "subscriber")
    },
    assertions: [{
      id: "assertion-1",
      description: "fixture matched",
      basis: "profile-fixture-requirement",
      status: "pass",
      expected: {matched: true},
      observed: {matched: true},
      evidence_ids: ["ev-object"]
    }],
    evidence: [
      evidence("ev-ready"; "publisher-readiness"; "control-trace"; "publisher"),
      evidence("ev-control"; "control-observations"; "control-trace"; "subscriber"),
      evidence("ev-object"; "object-observations"; "object-trace"; "subscriber"),
      evidence("ev-stream"; "delivery-observations"; "serve-model"; "subscriber"),
      evidence("ev-tap"; "tap14"; "tap14"; "driver"),
      evidence("ev-logs"; "process-logs"; "process-log"; "runner"),
      evidence("ev-metadata"; "reproduction-metadata"; "metadata"; "runner")
    ],
    reproduction: {
      command: ["moq-test-client", "--test", "moqt18-subscribe-group-basic"],
      environment: {TLS_DISABLE_VERIFY: "0"},
      relay_endpoint: "moqt://relay.example:443",
      per_case_timeout_ms: 10000
    },
    started_at_utc: "2026-08-31T12:00:00Z",
    duration_ms: 100
  }
' > "$TMP_DIR/result-valid.json"

"$PROFILE_VALIDATOR" "$PROFILE" "$SCHEMA" >/dev/null
"$RESULT_VALIDATOR" "$TMP_DIR/result-valid.json" "$PROFILE" >/dev/null
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-valid.json" >/dev/null

jq '.protocol = {transport:"webtransport",negotiated_draft:"draft-18",transport_alpn:"h3",webtransport_protocol:"moqt-18"}' \
  "$TMP_DIR/result-valid.json" > "$TMP_DIR/result-valid-webtransport.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-valid-webtransport.json" "$PROFILE" >/dev/null
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-valid-webtransport.json" >/dev/null

jq '.claimed_outcome = "pass" | .evaluator_verdict = "fail" | .failure_classification = "profile-mismatch" | .assertions[0].status = "fail"' \
  "$TMP_DIR/result-valid.json" > "$TMP_DIR/result-claim-overruled.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-claim-overruled.json" "$PROFILE" >/dev/null

jq '
  .identity.driver_binding = "moxygen_driver" |
  .identity.source_binding = {case_id:"MOXYGEN-D18-CASE-001",ordinal:1,source_name:"Basic subscribe with default parameters"} |
  .independence_class = "moxygen-driver-binding" |
  .evaluator_verdict = "inconclusive" |
  .claimed_outcome = "fail" |
  .failure_classification = "driver-inconclusive" |
  .assertions[0].status = "not-observed"
' "$TMP_DIR/result-valid.json" > "$TMP_DIR/result-ordering-inconclusive.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-ordering-inconclusive.json" "$PROFILE" >/dev/null

expect_profile_failure "unknown top-level key" '.unexpected = true'
expect_profile_failure "unknown nested gate key" '.gates[0].unexpected = true'
expect_profile_failure "case inventory drift" '.cases[0].source_name = "changed"'
expect_profile_failure "moxygen vector drift" '.gates[0].bindings.moxygen_driver.vector.object_ids = [0]'
expect_profile_failure "independent vector drift" '.gates[6].bindings.independent_moq_test_client.vector.groups = [0]'
expect_profile_failure "bogus normative reference" '.gates[0].normative_references += ["999"]'
expect_profile_failure "accept-anything semantic contract" '.gates[0].semantic_contract.success_criteria = ["Anything passes."]'
expect_profile_failure "forbidden Object Property" '.gates[0].bindings.independent_moq_test_client.vector.object_properties_by_object = {"0":[{"type":16384,"type_hex":"0x4000","value_kind":"integer","value":1,"value_hex":"0x1"}]}'
expect_profile_failure "slow timeout reduced" '.execution_policy.intended_case_timeouts_ms["MOXYGEN-D18-CASE-044"] = 10000'
expect_profile_failure "fake executable landing" '.provenance.executable_landings.rust_diagnostic_gates = {"status":"resolved","sha":"4444444444444444444444444444444444444444"}'
expect_profile_failure "reduced profile evidence categories" 'del(.required_evidence["tap14"]) | .gates[].evidence -= ["tap14"]'
expect_schema_failure "state_model schema regression" '.properties.result_record_contract.properties.state_model.required -= ["evaluator_verdict"]'
expect_schema_failure "semantic contract opened" '.definitions.semantic_contract.additionalProperties = true'

expect_result_failure "TBD executable SHA" '.revisions.driver_landing_sha = "TBD"'
expect_result_failure "unknown result key" '.unexpected = true'
expect_result_failure "unknown nested evidence key" '.evidence[0].unexpected = true'
expect_result_failure "duplicate evidence ID" '.evidence[1].id = .evidence[0].id'
expect_result_failure "missing evidence category" '.evidence |= map(select(.category != "tap14"))'
expect_result_failure "dangling evidence reference" '.assertions[0].evidence_ids = ["missing"]'
expect_result_failure "bad digest" '.evidence[0].sha256 = "bad"'
expect_result_failure "zero-length evidence" '.evidence[0].byte_length = 0'
expect_result_failure "category-incompatible kind" '.evidence[4].kind = "metadata"'
expect_result_failure "category-incompatible producer" '.evidence[4].producer = "runner"'
expect_result_failure "pass with failed assertion" '.assertions[0].status = "fail"'
expect_result_failure "pass with submitted evidence integrity" '.evidence_integrity_verification = "submitted"'
expect_result_failure "pass with submitted provenance" '.provenance_verification = "submitted"'
expect_result_failure "wrong deployment role" '.deployments.publisher.role = "subscriber"'
expect_result_failure "opaque result without opaque deployment" '.reproducibility = "opaque" | .opaque_limitations = ["unknown image"]'
expect_result_failure "wrong per-gate timeout" '.reproduction.per_case_timeout_ms = 30000'
expect_result_failure "bad raw QUIC protocol tuple" '.protocol.transport_alpn = "h3"'
expect_result_failure "bad WebTransport protocol tuple" '.protocol = {transport:"webtransport",negotiated_draft:"draft-18",transport_alpn:"moqt-18",webtransport_protocol:null}'
expect_result_failure "fractional duration" '.duration_ms = 1.5'
expect_result_failure "fractional evidence length" '.evidence[0].byte_length = 1.5'
expect_result_failure "fractional timeout" '.reproduction.per_case_timeout_ms = 10000.5'
expect_result_failure "bad evidence kind" '.evidence[0].kind = "unknown"'
expect_result_failure "empty evidence media type" '.evidence[0].media_type = ""'
expect_result_failure "empty assertion description" '.assertions[0].description = ""'
expect_result_failure "untrimmed assertion description" '.assertions[0].description = " fixture matched"'
expect_result_failure "invalid evidence timestamp" '.evidence[0].captured_at_utc = "2026-02-30T12:00:00Z"'
expect_result_failure "invalid result timestamp" '.started_at_utc = "not-a-date"'
expect_result_failure "invalid relay endpoint" '.reproduction.relay_endpoint = "ftp://relay.example"'
expect_result_failure "untrimmed command" '.reproduction.command[0] = " moq-test-client"'
expect_result_failure "non-object expected value" '.assertions[0].expected = "matched"'
expect_result_failure "bad reproduction command type" '.reproduction.command = "moq-test-client"'
expect_result_failure "bad reproduction environment value" '.reproduction.environment.TLS_DISABLE_VERIFY = 1'

echo "Validated profile/result mutation suite: all representative corruptions rejected"

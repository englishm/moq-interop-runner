#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE="$ROOT_DIR/docs/moxygen-relay-support-profile.json"
SCHEMA="$ROOT_DIR/docs/moxygen-relay-support-profile.schema.json"
PROFILE_VALIDATOR="$ROOT_DIR/scripts/validate-moxygen-profile.sh"
RESULT_VALIDATOR="$ROOT_DIR/scripts/validate-moxygen-result.sh"
SCHEMA_VALIDATOR="$ROOT_DIR/scripts/validate-moxygen-schema.sh"
PROFILE_DOCUMENT="$ROOT_DIR/docs/MOXYGEN-RELAY-SUPPORT-PROFILE.md"
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

expect_schema_profile_failure() {
  local name=$1
  local filter=$2
  local mutated="$TMP_DIR/schema-profile-mutated.json"

  jq "$filter" "$PROFILE" > "$mutated"
  if "$SCHEMA_VALIDATOR" "$mutated" "$SCHEMA" >/dev/null 2>&1; then
    echo "ERROR: profile mutation passed schema validation: $name" >&2
    exit 1
  fi
}

expect_schema_profile_success() {
  local name=$1
  local filter=$2
  local mutated="$TMP_DIR/schema-profile-valid.json"

  jq "$filter" "$PROFILE" > "$mutated"
  if ! "$SCHEMA_VALIDATOR" "$mutated" "$SCHEMA" >/dev/null 2>&1; then
    echo "ERROR: valid profile mutation failed schema validation: $name" >&2
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

expect_result_profile_failure() {
  local name=$1
  local filter=$2
  local mutated="$TMP_DIR/result-profile-mutated.json"

  jq "$filter" "$PROFILE" > "$mutated"
  if "$RESULT_VALIDATOR" "$TMP_DIR/result-valid.json" "$mutated" >/dev/null 2>&1; then
    echo "ERROR: result accepted invalid profile state: $name" >&2
    exit 1
  fi
}

expect_schema_result_failure() {
  local name=$1
  local filter=$2
  local mutated="$TMP_DIR/schema-result-mutated.json"

  jq "$filter" "$TMP_DIR/result-valid.json" > "$mutated"
  if "$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$mutated" >/dev/null 2>&1; then
    echo "ERROR: result mutation passed schema validation: $name" >&2
    exit 1
  fi
}

expect_target_reference_failure() {
  local reference="$TMP_DIR/target-reference.json"

  jq '.current_target = "draft-19"' "$ROOT_DIR/implementations.json" > "$reference"
  if "$PROFILE_VALIDATOR" "$PROFILE" "$SCHEMA" "$reference" >/dev/null 2>&1; then
    echo "ERROR: mismatched target-draft reference passed" >&2
    exit 1
  fi
}

expect_document_review_failure() {
  local stale_document="$TMP_DIR/profile-stale-review.md"

  sed -e 's/^\*\*Target Draft\*\*: `draft-18`$/**Target Draft**: `draft-19`/' \
    -e 's/^\*\*Identifier Semantics Reviewed For\*\*: `draft-18`$/**Identifier Semantics Reviewed For**: `draft-19`/' \
    "$PROFILE_DOCUMENT" > "$stale_document"
  if PROFILE_DOCUMENT="$stale_document" "$PROFILE_VALIDATOR" "$PROFILE" "$SCHEMA" >/dev/null 2>&1; then
    echo "ERROR: stale prose identifier review target passed" >&2
    exit 1
  fi
}

jq -n '
  def deployment($name; $role; $source_sha): {
    name: $name,
    role: $role,
    visibility: "reproducible",
    version: "test-v1",
    source_sha: $source_sha,
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
  def assertion($id; $description): {
    id: $id,
    description: $description,
    basis: "profile-fixture-requirement",
    status: "pass",
    expected: {matched: true},
    observed: {matched: true},
    evidence_ids: ["ev-object"]
  };
  {
    identity: {
      record_id: "record-1",
      run_id: "run-1",
      profile_id: "moxygen-relay-support-profile",
      profile_version: "1.0.0",
      profile_revision: 1,
      target_draft: "draft-18",
      gate_id: "subscribe-one-subgroup-per-group",
      gate_revision: 1,
      driver_binding: "independent_driver",
      source_binding: null
    },
    disposition: "intended",
    execution: "completed",
    evaluator_verdict: "pass",
    claimed_outcome: "pass",
    failure_classification: "none",
    independence_class: "independent-driver-binding",
    reproducibility: "reproducible",
    evidence_integrity_verification: "verified",
    provenance_verification: "verified",
    opaque_limitations: [],
    protocol: {transport: "raw-quic", negotiated_draft: "draft-18", transport_alpn: "moqt-18", webtransport_protocol: null},
    revisions: {
      schema_version: "1.0.0",
      profile_version: "1.0.0",
      profile_revision: 1,
      target_draft: "draft-18",
      gate_revision: 1,
      normative_draft_sha: "cb2e772fd8ca8cbe7550b1765c269be89fb1c886",
      moxygen_declaration_baseline_sha: "0d886e3e907e2236a6d927afefd09bb0c3dc8211",
      driver_review_baseline_sha: "b01d3f6707e3a74f69905722b451a08cbb3364f3",
      runner_sha: "2222222222222222222222222222222222222222",
      driver_landing_sha: "3333333333333333333333333333333333333333"
    },
    deployments: {
      publisher: deployment("fixture-publisher"; "publisher"; "3333333333333333333333333333333333333333"),
      relay: deployment("relay-under-test"; "relay"; "1111111111111111111111111111111111111111"),
      subscriber: deployment("fixture-subscriber"; "subscriber"; "3333333333333333333333333333333333333333")
    },
    phase_timings_ms: {setup_ms: 7000, readiness_ms: 9000, delivery_terminal_ms: 9000},
    assertions: [
      assertion("subscribe-one-subgroup-per-group.subscription-accepted"; "subscription accepted"),
      assertion("subscribe-one-subgroup-per-group.objects-preserved-exactly-once"; "objects preserved exactly once"),
      assertion("subscribe-one-subgroup-per-group.subgroups-framed-and-closed"; "subgroups framed and closed")
    ],
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
      command: ["controlled-driver", "--test", "subscribe-one-subgroup-per-group"],
      environment: {TLS_DISABLE_VERIFY: "0"},
      relay_endpoint: "moqt://relay.example:443",
      per_case_timeout_ms: 22000
    },
    started_at_utc: "2026-08-31T12:00:00Z",
    duration_ms: 25000
  }
' > "$TMP_DIR/result-valid.json"

"$PROFILE_VALIDATOR" "$PROFILE" "$SCHEMA" >/dev/null
"$RESULT_VALIDATOR" "$TMP_DIR/result-valid.json" "$PROFILE"
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-valid.json" >/dev/null

jq '.protocol = {transport:"webtransport",negotiated_draft:"draft-18",transport_alpn:"h3",webtransport_protocol:"moqt-18"}' \
  "$TMP_DIR/result-valid.json" > "$TMP_DIR/result-valid-webtransport.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-valid-webtransport.json" "$PROFILE" >/dev/null
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-valid-webtransport.json" >/dev/null

jq '.duration_ms = 50000' "$TMP_DIR/result-valid.json" > "$TMP_DIR/result-valid-aggregate-duration.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-valid-aggregate-duration.json" "$PROFILE" >/dev/null
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-valid-aggregate-duration.json" >/dev/null

jq '.claimed_outcome = "pass" | .evaluator_verdict = "fail" | .failure_classification = "profile-mismatch" | .assertions[0].status = "fail"' \
  "$TMP_DIR/result-valid.json" > "$TMP_DIR/result-claim-overruled.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-claim-overruled.json" "$PROFILE" >/dev/null
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-claim-overruled.json" >/dev/null

jq '.evaluator_verdict = "inconclusive" | .claimed_outcome = "inconclusive" | .failure_classification = "none" | .evidence_integrity_verification = "submitted"' \
  "$TMP_DIR/result-valid.json" > "$TMP_DIR/result-valid-inconclusive-unverified.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-valid-inconclusive-unverified.json" "$PROFILE" >/dev/null
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-valid-inconclusive-unverified.json" >/dev/null

jq '.evaluator_verdict = "unsupported" | .claimed_outcome = "unsupported" | .failure_classification = "none" | .assertions = [] | .phase_timings_ms = {}' \
  "$TMP_DIR/result-valid.json" > "$TMP_DIR/result-valid-unsupported.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-valid-unsupported.json" "$PROFILE" >/dev/null
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-valid-unsupported.json" >/dev/null

jq '.phase_timings_ms = {setup_ms:7000,readiness_ms:9000} | .duration_ms = 16000' \
  "$TMP_DIR/result-claim-overruled.json" > "$TMP_DIR/result-valid-fail-partial-timing.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-valid-fail-partial-timing.json" "$PROFILE" >/dev/null
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-valid-fail-partial-timing.json" >/dev/null

jq '
  .identity.driver_binding = "moxygen_driver" |
  .identity.source_binding = {case_id:"subscribe-one-subgroup-per-group",ordinal:1,source_name:"Basic subscribe with default parameters"} |
  .independence_class = "moxygen-driver-binding" |
  .reproduction.per_case_timeout_ms = 10000 |
  .revisions.driver_review_baseline_sha = "0d886e3e907e2236a6d927afefd09bb0c3dc8211" |
  .phase_timings_ms = {publisher_readiness_ms:9000,case_ms:9000} |
  .evaluator_verdict = "inconclusive" |
  .claimed_outcome = "fail" |
  .failure_classification = "driver-inconclusive" |
  .assertions[0].status = "not-observed"
' "$TMP_DIR/result-valid.json" > "$TMP_DIR/result-ordering-inconclusive.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-ordering-inconclusive.json" "$PROFILE" >/dev/null
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-ordering-inconclusive.json" >/dev/null

jq '.phase_timings_ms = {publisher_readiness_ms:9000} | .duration_ms = 9000' \
  "$TMP_DIR/result-ordering-inconclusive.json" > "$TMP_DIR/result-valid-moxygen-inconclusive-partial-timing.json"
"$RESULT_VALIDATOR" "$TMP_DIR/result-valid-moxygen-inconclusive-partial-timing.json" "$PROFILE" >/dev/null
"$SCHEMA_VALIDATOR" "$PROFILE" "$SCHEMA" "$TMP_DIR/result-valid-moxygen-inconclusive-partial-timing.json" >/dev/null

expect_profile_failure "unknown top-level key" '.unexpected = true'
expect_profile_failure "unknown nested gate key" '.gates[0].unexpected = true'
expect_profile_failure "gate and source semantic IDs diverged" '.gates[0].moxygen_source_binding_id = .cases[1].id'
expect_profile_failure "stale identifier review target" '.identifier_history.reviewed_for_target = "draft-19"'
expect_profile_failure "fake verified support missing metadata" '.support_verification.state = "verified"'
expect_profile_failure "invalidated support missing invalidation metadata" '.support_verification.state = "invalidated"'
expect_profile_failure "support invalidation predates verification" '.support_verification.state = "invalidated" | .support_verification.verified_at = "2026-08-31T12:00:00Z" | .support_verification.invalidated_at = "2026-08-31T11:00:00Z" | .support_verification.invalidation_reason = "Evidence invalidated."'
expect_profile_failure "unverified support claims gate coverage" '.support_verification.verified_gate_ids = [.gates[0].id]'
expect_profile_failure "support verification target mismatch" '.support_verification.target_draft = "draft-19"'
expect_profile_failure "empty support invalidation conditions" '.support_verification.invalidation_conditions = []'
expect_profile_failure "retired semantic-test ID reuse" '.identifier_history.retired_ids = [{kind:"semantic-test",id:.cases[0].id,last_valid_target:"draft-17",last_valid_profile_revision:1,reason:"Semantics changed."}]'
expect_profile_failure "retired profile ID reuse" '.identifier_history.retired_ids = [{kind:"profile",id:.profile.id,last_valid_target:"draft-17",last_valid_profile_revision:1,reason:"Semantics changed."}]'
expect_profile_failure "same retired replacement" '.identifier_history.retired_ids = [{kind:"semantic-test",id:"retired-example",last_valid_target:"draft-17",last_valid_profile_revision:1,reason:"Semantics changed.",replacement_id:"retired-example"}]'
expect_profile_failure "semantic-policy weakening" '.identifier_policy.semantic_change = "Semantic changes may retain an ID."'
expect_profile_failure "oracle-policy weakening" '.oracle.semantic_layer = "Any implementation behavior is acceptable."'
expect_profile_failure "result-semantic-policy weakening" '.result_semantics[0].meaning = "The driver claimed success."'
expect_profile_failure "result-identity-policy weakening" '.result_record_contract.identity_rule = "The gate ID alone defines historical meaning."'
expect_profile_failure "swapped binding gate timeouts" '.execution_policy.diagnostic_gate_timeouts_ms[] |= {moxygen_driver:.independent_driver,independent_driver:.moxygen_driver}'
expect_profile_failure "zero client readiness margin" '.execution_policy.independent_driver_timeout_components_ms.client_readiness_margin = 0 | .execution_policy.independent_driver_timeout_components_ms.client_readiness_ceiling = 10000 | .execution_policy.diagnostic_gate_timeouts_ms[].independent_driver = 20000'
expect_profile_failure "independent total mismatch" '.execution_policy.diagnostic_gate_timeouts_ms[].independent_driver = 21000'
expect_profile_failure "version-specific source binding ID" '.cases[0].id = ("subscribe-" + "draft-" + "18-group-basic")'
expect_profile_failure "version-specific gate ID" '.gates[0].id = ("subscribe-" + "d" + "18-group-basic")'
expect_profile_failure "version-specific function name" '.gates[0].bindings.independent_driver.planned_function = ("test_" + "moqt" + "18_subscribe_group_basic")'
expect_profile_failure "case inventory drift" '.cases[0].source_name = "changed"'
expect_profile_failure "moxygen vector drift" '.gates[0].bindings.moxygen_driver.vector.object_ids = [0]'
expect_profile_failure "independent vector drift" '.gates[6].bindings.independent_driver.vector.groups = [0]'
expect_profile_failure "controlled implementation identity drift" '.gates[0].bindings.independent_driver.implementation = "other-driver"'
expect_profile_failure "controlled repository drift" '.gates[0].bindings.independent_driver.repository = "https://example.invalid/driver"'
expect_profile_failure "independence classification weakened" '.gates[0].bindings.independent_driver.independence_classification = "shared-generator"'
expect_profile_failure "shortened payload alias" '.gates[1].bindings.independent_driver.vector.payloads.items[0].ascii = "one-subgroup-s40-o4"'
expect_profile_failure "namespace differs from semantic ID" '.gates[0].bindings.independent_driver.vector.namespace_prefix = "moq-test/interop/other" | .gates[0].bindings.independent_driver.vector.namespace_rule = "moq-test/interop/other/{publisher_cid}"'
expect_profile_failure "bogus normative reference" '.gates[0].gate_normative_references += ["999"]'
expect_profile_failure "accept-anything semantic contract" '.gates[0].semantic_contract.success_criteria = ["Anything passes."]'
expect_profile_failure "forbidden Object Property" '.gates[0].bindings.independent_driver.vector.object_properties_by_object = {"0":[{"type":16384,"type_hex":"0x4000","value_kind":"integer","value":1,"value_hex":"0x1"}]}'
expect_profile_failure "slow timeout reduced" '.execution_policy.intended_case_timeouts_ms["subscribe-low-frequency-updates"] = 10000'
expect_profile_failure "fake executable landing" '.provenance.executable_landings.independent_driver = {"status":"resolved","sha":"4444444444444444444444444444444444444444"}'
expect_profile_failure "reduced profile evidence categories" 'del(.required_evidence["tap14"]) | .gates[].evidence -= ["tap14"]'
expect_schema_failure "state_model schema regression" '.properties.result_record_contract.properties.state_model.required -= ["evaluator_verdict"]'
expect_schema_failure "semantic contract opened" '.definitions.semantic_contract.additionalProperties = true'
expect_schema_profile_success "retired identifier with RFC target and replacement" '.identifier_history.retired_ids = [{kind:"semantic-test",id:"retired-example",last_valid_target:"rfc-9999",last_valid_profile_revision:1,reason:"Semantics changed.",replacement_id:"replacement-example"}]'
expect_schema_profile_success "fully described profile-wide verified support" '.support_verification.state = "verified" | .support_verification.verified_at = "2026-08-31T12:00:00Z" | .support_verification.verified_gate_ids = [.gates[].id] | .support_verification.driver_binding = "independent_driver" | .support_verification.pinned_implementation_revision = {source_sha:"4444444444444444444444444444444444444444",image_digest:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"} | .support_verification.verified_subject = "relay-under-test" | .support_verification.verified_role = "relay" | .support_verification.result_links = [.gates | to_entries[] | . as $entry | {gate_id:$entry.value.id,locator:("artifact:" + $entry.value.id + ".json"),sha256:([range(0;64)] | map(($entry.key + 1 | tostring)) | join(""))}] | .support_verification.evidence_links = [{locator:"https://example.invalid/evidence.json",sha256:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}]'
expect_schema_profile_failure "one-gate verification cannot verify profile" '.support_verification.state = "verified" | .support_verification.verified_at = "2026-08-31T12:00:00Z" | .support_verification.verified_gate_ids = [.gates[0].id] | .support_verification.driver_binding = "independent_driver" | .support_verification.pinned_implementation_revision = {source_sha:"4444444444444444444444444444444444444444",image_digest:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"} | .support_verification.verified_subject = "relay-under-test" | .support_verification.verified_role = "relay" | .support_verification.result_links = [{gate_id:.gates[0].id,locator:"artifact:one-gate.json",sha256:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}] | .support_verification.evidence_links = [{locator:"artifact:evidence.json",sha256:"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}]'
expect_schema_profile_failure "fake verified support missing metadata" '.support_verification.state = "verified"'
expect_schema_profile_failure "invalidated support missing invalidation metadata" '.support_verification.state = "invalidated"'
expect_schema_profile_failure "unverified support claims gate coverage" '.support_verification.verified_gate_ids = [.gates[0].id]'
expect_result_profile_failure "support invalidation predates verification" '.support_verification.verified_at = "2026-08-31T12:00:00Z" | .support_verification.invalidated_at = "2026-08-31T11:00:00Z"'
expect_schema_profile_failure "support verification target mismatch" '.support_verification.target_draft = "draft-19"'
expect_schema_profile_failure "empty support invalidation conditions" '.support_verification.invalidation_conditions = []'
expect_schema_profile_failure "stale identifier review target" '.identifier_history.reviewed_for_target = "draft-19"'
expect_schema_profile_failure "semantic-policy weakening" '.identifier_policy.semantic_change = "Semantic changes may retain an ID."'
expect_schema_profile_failure "swapped binding gate timeouts" '.execution_policy.diagnostic_gate_timeouts_ms[] |= {moxygen_driver:.independent_driver,independent_driver:.moxygen_driver}'
expect_schema_profile_failure "zero client readiness margin" '.execution_policy.independent_driver_timeout_components_ms.client_readiness_margin = 0 | .execution_policy.independent_driver_timeout_components_ms.client_readiness_ceiling = 10000 | .execution_policy.diagnostic_gate_timeouts_ms[].independent_driver = 20000'
expect_schema_profile_failure "independent total mismatch" '.execution_policy.diagnostic_gate_timeouts_ms[].independent_driver = 21000'
expect_schema_profile_failure "version-specific source binding ID" '.cases[0].id = ("subscribe-" + "draft-" + "18-group-basic")'
expect_schema_profile_failure "version-specific gate ID" '.gates[0].id = ("subscribe-" + "d" + "18-group-basic")'
expect_schema_profile_failure "version-specific function name" '.gates[0].bindings.independent_driver.planned_function = ("test_" + "moqt" + "18_subscribe_group_basic")'
expect_schema_profile_failure "controlled implementation identity drift" '.gates[0].bindings.independent_driver.implementation = "other-driver"'
expect_schema_result_failure "swapped independent timeout" '.reproduction.per_case_timeout_ms = 10000'
expect_schema_result_failure "old independent timeout" '.reproduction.per_case_timeout_ms = 20000'
expect_schema_result_failure "independent readiness phase exceeds maximum" '.phase_timings_ms.readiness_ms = 12001'
expect_schema_result_failure "independent delivery phase exceeds maximum" '.phase_timings_ms.delivery_terminal_ms = 10001'
expect_schema_result_failure "single arbitrary assertion" '.assertions = [(.assertions[0] | .id = "arbitrary-assertion")]'
expect_schema_result_failure "pass missing delivery phase" 'del(.phase_timings_ms.delivery_terminal_ms)'
expect_schema_result_failure "fail with empty assertions" '.evaluator_verdict = "fail" | .claimed_outcome = "fail" | .failure_classification = "protocol-contradiction" | .assertions = []'
expect_schema_result_failure "fail with all-pass assertions" '.evaluator_verdict = "fail" | .claimed_outcome = "fail" | .failure_classification = "protocol-contradiction"'
expect_schema_result_failure "fail with failed integrity" '.evaluator_verdict = "fail" | .claimed_outcome = "fail" | .failure_classification = "protocol-contradiction" | .assertions[0].status = "fail" | .evidence_integrity_verification = "failed"'
expect_schema_result_failure "fully verified all-pass inconclusive" '.evaluator_verdict = "inconclusive" | .claimed_outcome = "inconclusive" | .failure_classification = "none"'
expect_schema_result_failure "unsupported evaluator with non-unsupported claim" '.evaluator_verdict = "unsupported" | .failure_classification = "none"'
expect_schema_result_failure "unsupported claim with pass evaluator" '.claimed_outcome = "unsupported"'
expect_schema_result_failure "unsupported with all-pass assertions" '.evaluator_verdict = "unsupported" | .claimed_outcome = "unsupported" | .failure_classification = "none"'
expect_schema_result_failure "unsupported contradiction classification" '.evaluator_verdict = "unsupported" | .claimed_outcome = "unsupported" | .failure_classification = "protocol-contradiction" | .assertions = []'
expect_target_reference_failure
expect_document_review_failure

expect_result_failure "TBD executable SHA" '.revisions.driver_landing_sha = "TBD"'
expect_result_failure "driver review SHA differs from selected binding" '.revisions.driver_review_baseline_sha = "0d886e3e907e2236a6d927afefd09bb0c3dc8211"'
expect_result_failure "unknown result key" '.unexpected = true'
expect_result_failure "missing target draft identity" 'del(.identity.target_draft)'
expect_result_failure "version-specific gate ID" '.identity.gate_id = ("subscribe-" + "draft-" + "18-group-basic")'
expect_result_failure "target draft revision mismatch" '.revisions.target_draft = "draft-19"'
expect_result_failure "unknown nested evidence key" '.evidence[0].unexpected = true'
expect_result_failure "duplicate evidence ID" '.evidence[1].id = .evidence[0].id'
expect_result_failure "missing evidence category" '.evidence |= map(select(.category != "tap14"))'
expect_result_failure "dangling evidence reference" '.assertions[0].evidence_ids = ["missing"]'
expect_result_failure "bad digest" '.evidence[0].sha256 = "bad"'
expect_result_failure "zero-length evidence" '.evidence[0].byte_length = 0'
expect_result_failure "category-incompatible kind" '.evidence[4].kind = "metadata"'
expect_result_failure "category-incompatible producer" '.evidence[4].producer = "runner"'
expect_result_failure "pass with failed assertion" '.assertions[0].status = "fail"'
expect_result_failure "pass with one required assertion" '.assertions = [.assertions[0]]'
expect_result_failure "single arbitrary assertion" '.assertions = [(.assertions[0] | .id = "arbitrary-assertion")]'
expect_result_failure "pass missing delivery phase" 'del(.phase_timings_ms.delivery_terminal_ms)'
expect_result_failure "assertion from unrelated gate" '.assertions[0].id = "subscribe-one-subgroup-per-object.subscription-accepted"'
expect_result_failure "fail with empty assertions" '.evaluator_verdict = "fail" | .claimed_outcome = "fail" | .failure_classification = "protocol-contradiction" | .assertions = []'
expect_result_failure "fail with all-pass assertions" '.evaluator_verdict = "fail" | .claimed_outcome = "fail" | .failure_classification = "protocol-contradiction"'
expect_result_failure "fail with failed integrity" '.evaluator_verdict = "fail" | .claimed_outcome = "fail" | .failure_classification = "protocol-contradiction" | .assertions[0].status = "fail" | .evidence_integrity_verification = "failed"'
expect_result_failure "fully verified all-pass inconclusive" '.evaluator_verdict = "inconclusive" | .claimed_outcome = "inconclusive" | .failure_classification = "none"'
expect_result_failure "unsupported evaluator with non-unsupported claim" '.evaluator_verdict = "unsupported" | .failure_classification = "none" | .assertions = []'
expect_result_failure "unsupported claim with pass evaluator" '.claimed_outcome = "unsupported"'
expect_result_failure "unsupported with all-pass assertions" '.evaluator_verdict = "unsupported" | .claimed_outcome = "unsupported" | .failure_classification = "none"'
expect_result_failure "unsupported contradiction classification" '.evaluator_verdict = "unsupported" | .claimed_outcome = "unsupported" | .failure_classification = "protocol-contradiction" | .assertions = []'
expect_result_failure "pass with submitted evidence integrity" '.evidence_integrity_verification = "submitted"'
expect_result_failure "pass with submitted provenance" '.provenance_verification = "submitted"'
expect_result_failure "independent readiness phase exceeds maximum" '.phase_timings_ms.readiness_ms = 12001'
expect_result_failure "independent delivery phase exceeds maximum" '.phase_timings_ms.delivery_terminal_ms = 10001'
expect_result_failure "independent result uses moxygen case phase" '.phase_timings_ms.case_ms = 1'
expect_result_failure "aggregate duration below sequential phases" '.duration_ms = 24999'
expect_result_failure "driver SHA differs from publisher" '.deployments.publisher.source_sha = "4444444444444444444444444444444444444444"'
expect_result_failure "inconclusive contradiction classification" '.evaluator_verdict = "inconclusive" | .claimed_outcome = "inconclusive" | .failure_classification = "protocol-contradiction"'
expect_result_failure "harness error contradiction classification" '.evaluator_verdict = "harness-error" | .claimed_outcome = "harness-error" | .failure_classification = "mixed"'
expect_result_failure "wrong deployment role" '.deployments.publisher.role = "subscriber"'
expect_result_failure "opaque result without opaque deployment" '.reproducibility = "opaque" | .opaque_limitations = ["unknown image"]'
expect_result_failure "swapped independent timeout" '.reproduction.per_case_timeout_ms = 10000'
expect_result_failure "old independent timeout" '.reproduction.per_case_timeout_ms = 20000'
expect_result_failure "wrong per-gate timeout" '.reproduction.per_case_timeout_ms = 30000'
expect_result_failure "bad raw QUIC protocol tuple" '.protocol.transport_alpn = "h3"'
expect_result_failure "bad WebTransport protocol tuple" '.protocol = {transport:"webtransport",negotiated_draft:"draft-18",transport_alpn:"moqt-18",webtransport_protocol:null}'
expect_result_failure "fractional duration" '.duration_ms = 1.5'
expect_result_failure "fractional evidence length" '.evidence[0].byte_length = 1.5'
expect_result_failure "fractional timeout" '.reproduction.per_case_timeout_ms = 22000.5'
expect_result_failure "bad evidence kind" '.evidence[0].kind = "unknown"'
expect_result_failure "empty evidence media type" '.evidence[0].media_type = ""'
expect_result_failure "empty assertion description" '.assertions[0].description = ""'
expect_result_failure "untrimmed assertion description" '.assertions[0].description = " fixture matched"'
expect_result_failure "invalid evidence timestamp" '.evidence[0].captured_at_utc = "2026-02-30T12:00:00Z"'
expect_result_failure "invalid result timestamp" '.started_at_utc = "not-a-date"'
expect_result_failure "invalid relay endpoint" '.reproduction.relay_endpoint = "ftp://relay.example"'
expect_result_failure "untrimmed command" '.reproduction.command[0] = " controlled-driver"'
expect_result_failure "non-object expected value" '.assertions[0].expected = "matched"'
expect_result_failure "bad reproduction command type" '.reproduction.command = "controlled-driver"'
expect_result_failure "bad reproduction environment value" '.reproduction.environment.TLS_DISABLE_VERIFY = 1'

echo "Validated profile/result mutation suite: all representative corruptions rejected"

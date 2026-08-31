#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RESULT=${1:-}
PROFILE=${2:-"$ROOT_DIR/docs/moxygen-relay-support-profile.json"}

if [[ -z "$RESULT" ]]; then
  echo "Usage: $0 RESULT.json [PROFILE.json]" >&2
  exit 2
fi

for command in jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "ERROR: $command is required" >&2
    exit 1
  fi
done

for file in "$RESULT" "$PROFILE"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: missing file: $file" >&2
    exit 1
  fi
  jq empty "$file"
done

if ! jq -e --slurpfile profile "$PROFILE" '
  def full_sha: type == "string" and test("^[0-9a-f]{40}$");
  def digest: type == "string" and test("^[0-9a-f]{64}$");
  def image_digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
  def identifier: type == "string" and test("^[A-Za-z0-9._:-]+$");
  def locator: type == "string" and test("^(file://|https://|artifact:)[^\\s]+$");
  def integer: type == "number" and floor == .;
  def nonempty_string: type == "string" and length > 0;
  def trimmed_nonempty: nonempty_string and . == gsub("^\\s+|\\s+$"; "");
  def utc_timestamp:
    type == "string" and endswith("Z") and
    (. as $value | (try fromdateiso8601 catch null) as $epoch | ($epoch | type) == "number" and ($epoch | todateiso8601) == $value);
  def compatible_evidence:
    if .category == "publisher-readiness" then
      (.kind == "control-trace" or .kind == "serve-model") and (.producer == "publisher" or .producer == "relay" or .producer == "subscriber" or .producer == "driver")
    elif .category == "control-observations" then
      .kind == "control-trace" and (.producer == "publisher" or .producer == "relay" or .producer == "subscriber" or .producer == "driver")
    elif .category == "object-observations" then
      (.kind == "object-trace" or .kind == "serve-model") and (.producer == "publisher" or .producer == "relay" or .producer == "subscriber" or .producer == "driver")
    elif .category == "delivery-observations" then
      (.kind == "stream-trace" or .kind == "serve-model") and (.producer == "publisher" or .producer == "relay" or .producer == "subscriber" or .producer == "driver")
    elif .category == "tap14" then .kind == "tap14" and .producer == "driver"
    elif .category == "process-logs" then
      (.kind == "stdout" or .kind == "stderr" or .kind == "process-log") and (.producer == "publisher" or .producer == "relay" or .producer == "subscriber" or .producer == "runner" or .producer == "driver")
    elif .category == "reproduction-metadata" then .kind == "metadata" and (.producer == "runner" or .producer == "driver")
    else false end;
  def deployment_keys: keys == ["image_digest","name","opaque","role","source_sha","version","visibility"];
  def valid_deployment($role):
    deployment_keys and
    .role == $role and
    (.name | trimmed_nonempty) and
    (.version | trimmed_nonempty) and
    if .visibility == "reproducible" then
      (.source_sha | full_sha) and (.image_digest | image_digest) and .opaque == null
    elif .visibility == "opaque" then
      ((.source_sha == null) or (.source_sha | full_sha)) and
      .image_digest == null and
      (.opaque | keys == ["limitations","locator","observed_version","reason"]) and
      (.opaque.reason | trimmed_nonempty) and
      (.opaque.locator | trimmed_nonempty) and
      (.opaque.observed_version | trimmed_nonempty) and
      (.opaque.limitations | type == "array" and length > 0) and
      all(.opaque.limitations[]; trimmed_nonempty)
    else false end;

  $profile[0] as $p |
  . as $r |
  ($p.gates[] | select(.id == $r.identity.gate_id)) as $gate |
  (.phase_timings_ms | keys) as $phase_keys |
  (if $p.support_verification.verified_at != null and $p.support_verification.invalidated_at != null then
     (($p.support_verification.invalidated_at | fromdateiso8601) >=
      ($p.support_verification.verified_at | fromdateiso8601))
   else true end) and
  (tostring | contains("TBD") | not) and
  (keys == ["assertions","claimed_outcome","deployments","disposition","duration_ms","evaluator_verdict","evidence","evidence_integrity_verification","execution","failure_classification","identity","independence_class","opaque_limitations","phase_timings_ms","protocol","provenance_verification","reproducibility","reproduction","revisions","started_at_utc"]) and
  (.identity | keys == ["driver_binding","gate_id","gate_revision","profile_id","profile_revision","profile_version","record_id","run_id","source_binding","target_draft"]) and
  .identity.profile_id == $p.profile.id and
  .identity.profile_version == $p.profile.version and
  .identity.profile_revision == $p.profile.revision and
  .identity.target_draft == $p.profile.target_draft and
  .identity.gate_revision == 1 and
  ([ $p.gates[].id ] | index($r.identity.gate_id)) != null and
  (.identity.record_id | identifier) and (.identity.run_id | identifier) and
  (.identity.driver_binding == "moxygen_driver" or .identity.driver_binding == "independent_driver") and
  (if .identity.driver_binding == "moxygen_driver" then
     .identity.source_binding != null and
     (.identity.source_binding | keys == ["case_id","ordinal","source_name"]) and
     ($p.gates[] | select(.id == $r.identity.gate_id) |
       .moxygen_source_binding_id == $r.identity.source_binding.case_id and
       .bindings.moxygen_driver.source_ordinal == $r.identity.source_binding.ordinal and
       .bindings.moxygen_driver.source_name == $r.identity.source_binding.source_name) and
     .independence_class == "moxygen-driver-binding"
   else .identity.source_binding == null and .independence_class == "independent-driver-binding" end) and
  .disposition == "intended" and
  (.execution == "not-run" or .execution == "started" or .execution == "completed" or .execution == "aborted") and
  (.claimed_outcome == "pass" or .claimed_outcome == "fail" or .claimed_outcome == "inconclusive" or .claimed_outcome == "unsupported" or .claimed_outcome == "not-run" or .claimed_outcome == "harness-error") and
  (if .execution == "not-run" then .evaluator_verdict == null and .claimed_outcome == "not-run"
   elif .execution == "started" then .evaluator_verdict == null and .claimed_outcome == "not-run"
   elif .execution == "aborted" then (.evaluator_verdict == "inconclusive" or .evaluator_verdict == "harness-error")
   else (.evaluator_verdict == "pass" or .evaluator_verdict == "fail" or .evaluator_verdict == "inconclusive" or .evaluator_verdict == "unsupported" or .evaluator_verdict == "harness-error") and .claimed_outcome != "not-run" end) and
  (.failure_classification == "none" or .failure_classification == "profile-mismatch" or .failure_classification == "protocol-contradiction" or .failure_classification == "mixed" or .failure_classification == "driver-inconclusive") and
  (.evidence_integrity_verification == "submitted" or .evidence_integrity_verification == "verified" or .evidence_integrity_verification == "failed") and
  (.provenance_verification == "submitted" or .provenance_verification == "verified" or .provenance_verification == "failed") and
  (if .evaluator_verdict == "pass" then
     .execution == "completed" and .failure_classification == "none" and
     .evidence_integrity_verification == "verified" and .provenance_verification == "verified" and
     ([.assertions[].id] | sort) == ($gate.required_assertion_ids | sort) and
     all(.assertions[]; .status == "pass") and
     (if .identity.driver_binding == "moxygen_driver" then
        $phase_keys == ["case_ms","publisher_readiness_ms"]
      else
        $phase_keys == ["delivery_terminal_ms","readiness_ms","setup_ms"]
      end) and
     .protocol.negotiated_draft == .identity.target_draft
    elif .evaluator_verdict == "fail" then
      (.failure_classification == "profile-mismatch" or .failure_classification == "protocol-contradiction" or .failure_classification == "mixed") and
      .evidence_integrity_verification == "verified" and .provenance_verification == "verified" and
      ([.assertions[].id] | sort) == ($gate.required_assertion_ids | sort) and
      any(.assertions[]; .status == "fail")
    elif .evaluator_verdict == "inconclusive" then
      (.failure_classification == "none" or
       (.failure_classification == "driver-inconclusive" and .identity.driver_binding == "moxygen_driver")) and
      (any(.assertions[]; .status == "not-observed") or
       .evidence_integrity_verification != "verified" or
       .provenance_verification != "verified")
    elif .evaluator_verdict == "unsupported" then
      .claimed_outcome == "unsupported" and .execution == "completed" and .failure_classification == "none" and
      all(.assertions[]; .status == "not-observed")
    elif .evaluator_verdict == "harness-error" or .evaluator_verdict == null then
      .failure_classification == "none"
    else false end) and
  (if .claimed_outcome == "unsupported" then .evaluator_verdict == "unsupported" and .execution == "completed" else true end) and
  (.protocol | keys == ["negotiated_draft","transport","transport_alpn","webtransport_protocol"]) and
  .protocol.negotiated_draft == .identity.target_draft and
  (if .protocol.transport == "raw-quic" then
     .protocol.transport_alpn == "moqt-18" and .protocol.webtransport_protocol == null
   elif .protocol.transport == "webtransport" then
     (.protocol.transport_alpn | test("^h3(-[0-9]+)?$")) and .protocol.webtransport_protocol == "moqt-18"
   else false end) and
  (.revisions | keys == ["driver_landing_sha","driver_review_baseline_sha","gate_revision","moxygen_declaration_baseline_sha","normative_draft_sha","profile_revision","profile_version","runner_sha","schema_version","target_draft"]) and
  .revisions.schema_version == $p.schema_version and
  .revisions.profile_version == $p.profile.version and
  .revisions.profile_revision == $p.profile.revision and .revisions.gate_revision == 1 and
  .revisions.target_draft == $p.profile.target_draft and
  .revisions.normative_draft_sha == $p.provenance.reference_baselines.normative_draft.sha and
  .revisions.moxygen_declaration_baseline_sha == $p.provenance.reference_baselines.moxygen_declarations.sha and
  .revisions.driver_review_baseline_sha == (if .identity.driver_binding == "moxygen_driver" then
    $p.provenance.reference_baselines.moxygen_declarations.sha
  else
    $p.implementation_bindings.independent_driver.review_sha
  end) and
  (.revisions.runner_sha | full_sha) and (.revisions.driver_landing_sha | full_sha) and
  (.deployments | keys == ["publisher","relay","subscriber"]) and
  (.deployments.publisher | valid_deployment("publisher")) and
  (.deployments.relay | valid_deployment("relay")) and
  (.deployments.subscriber | valid_deployment("subscriber")) and
  .deployments.publisher.source_sha == .revisions.driver_landing_sha and
  .deployments.subscriber.source_sha == .revisions.driver_landing_sha and
  (.opaque_limitations | type == "array") and all(.opaque_limitations[]; trimmed_nonempty) and
  (if .reproducibility == "reproducible" then
     (.opaque_limitations | length == 0) and all(.deployments[]; .visibility == "reproducible")
   elif .reproducibility == "opaque" then
     (.opaque_limitations | length > 0) and any(.deployments[]; .visibility == "opaque")
   else false end) and
  (.assertions | type == "array") and
  ([.assertions[].id] | length) == ([.assertions[].id] | unique | length) and
  all(.assertions[].id; . as $id | $gate.required_assertion_ids | index($id) != null) and
  all(.assertions[];
    (keys == ["basis","description","evidence_ids","expected","id","observed","status"]) and
    (.id | identifier) and (.description | trimmed_nonempty) and
    (.basis == "profile-fixture-requirement" or .basis == "draft-protocol-requirement") and
    (.status == "pass" or .status == "fail" or .status == "not-observed") and
    (.expected | type == "object") and (.observed | type == "object") and
    (.evidence_ids | length > 0) and ([.evidence_ids[]] | length) == ([.evidence_ids[]] | unique | length)) and
  (.evidence | type == "array") and
  ([.evidence[].id] | length) == ([.evidence[].id] | unique | length) and
  ([.evidence[].category] | unique | sort) == (["publisher-readiness","control-observations","object-observations","delivery-observations","tap14","process-logs","reproduction-metadata"] | sort) and
  all(.evidence[];
    (keys == ["byte_length","captured_at_utc","category","id","kind","locator","media_type","producer","sha256"]) and
    (.id | identifier) and (.sha256 | digest) and (.locator | locator) and
    (.category == "publisher-readiness" or .category == "control-observations" or .category == "object-observations" or .category == "delivery-observations" or .category == "tap14" or .category == "process-logs" or .category == "reproduction-metadata") and
    (.kind == "tap14" or .kind == "control-trace" or .kind == "object-trace" or .kind == "stream-trace" or .kind == "serve-model" or .kind == "stdout" or .kind == "stderr" or .kind == "process-log" or .kind == "metadata") and
    (.producer == "publisher" or .producer == "relay" or .producer == "subscriber" or .producer == "runner" or .producer == "driver") and
    compatible_evidence and
    (.media_type | trimmed_nonempty) and
    (.byte_length | integer and . > 0) and
    (.captured_at_utc | utc_timestamp)) and
  ([.evidence[].id] as $evidence_ids | all(.assertions[].evidence_ids[]; . as $id | $evidence_ids | index($id) != null)) and
  (.phase_timings_ms | type == "object") and
  (if .identity.driver_binding == "moxygen_driver" then
     all($phase_keys[]; . == "publisher_readiness_ms" or . == "case_ms") and
     ((.phase_timings_ms | has("publisher_readiness_ms") | not) or (.phase_timings_ms.publisher_readiness_ms | integer and . >= 0 and . <= 10000)) and
     ((.phase_timings_ms | has("case_ms") | not) or (.phase_timings_ms.case_ms | integer and . >= 0 and . <= $r.reproduction.per_case_timeout_ms)) and
     .duration_ms >= ((.phase_timings_ms.publisher_readiness_ms // 0) + (.phase_timings_ms.case_ms // 0))
   else
     all($phase_keys[]; . == "setup_ms" or . == "readiness_ms" or . == "delivery_terminal_ms") and
     ((.phase_timings_ms | has("setup_ms") | not) or (.phase_timings_ms.setup_ms | integer and . >= 0)) and
     ((.phase_timings_ms | has("readiness_ms") | not) or (.phase_timings_ms.readiness_ms | integer and . >= 0 and . <= $p.execution_policy.independent_driver_timeout_components_ms.rendezvous)) and
     ((.phase_timings_ms | has("delivery_terminal_ms") | not) or (.phase_timings_ms.delivery_terminal_ms | integer and . >= 0 and . <= $p.execution_policy.independent_driver_timeout_components_ms.delivery_and_terminal_margin)) and
     .duration_ms >= ((.phase_timings_ms.setup_ms // 0) + (.phase_timings_ms.readiness_ms // 0) + (.phase_timings_ms.delivery_terminal_ms // 0))
   end) and
  (.reproduction | keys == ["command","environment","per_case_timeout_ms","relay_endpoint"]) and
  (.reproduction.command | type == "array" and length > 0) and all(.reproduction.command[]; trimmed_nonempty) and
  (.reproduction.environment | type == "object") and all(.reproduction.environment | to_entries[]; (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) and (.value | type == "string")) and
  (.reproduction.relay_endpoint | test("^(moqt|https)://[^\\s/:]+(:[0-9]+)?(/[^\\s]*)?$")) and
  (.reproduction.per_case_timeout_ms | integer and . > 0) and
  .reproduction.per_case_timeout_ms == $p.execution_policy.diagnostic_gate_timeouts_ms[$r.identity.gate_id][$r.identity.driver_binding] and
  (.started_at_utc | utc_timestamp) and
  (.duration_ms | integer and . >= 0)
' "$RESULT" >/dev/null; then
  echo "ERROR: invalid moxygen relay support result record: $RESULT" >&2
  exit 1
fi

echo "Validated moxygen relay support result record: $RESULT"

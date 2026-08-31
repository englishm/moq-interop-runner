#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=${1:-"$ROOT_DIR/docs/moxygen-relay-support-profile.json"}
SCHEMA=${2:-"$ROOT_DIR/docs/moxygen-relay-support-profile.schema.json"}
TARGET_DRAFT_REFERENCE=${TARGET_DRAFT_REFERENCE:-${3:-"$ROOT_DIR/implementations.json"}}
PROFILE_DOCUMENT=${PROFILE_DOCUMENT:-"$ROOT_DIR/docs/MOXYGEN-RELAY-SUPPORT-PROFILE.md"}
GATE_DOCUMENT=${GATE_DOCUMENT:-"$ROOT_DIR/docs/MOXYGEN-DIAGNOSTIC-GATES.md"}

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "ERROR: sha256sum is required" >&2
  exit 1
fi

for file in "$PROFILE" "$SCHEMA" "$TARGET_DRAFT_REFERENCE"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: missing file: $file" >&2
    exit 1
  fi
  jq empty "$file"
done

for file in "$PROFILE_DOCUMENT" "$GATE_DOCUMENT"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: missing file: $file" >&2
    exit 1
  fi
done

if ! jq -e '
  .["$schema"] == "http://json-schema.org/draft-07/schema#" and
  .type == "object" and
  (.required | type == "array") and
  (.properties.profile | type == "object") and
  (.properties.provenance | type == "object") and
  (.properties.implementation_bindings | type == "object") and
  (.properties.identifier_policy | type == "object") and
  (.properties.identifier_history | type == "object") and
  (.properties.support_verification | type == "object") and
  (.properties.execution_policy.required | sort) == (["readiness_timeout_ms","runner_whole_container_limit_ms","diagnostic_gate_timeouts_ms","independent_driver_timeout_components_ms","intended_case_timeouts_ms","rule"] | sort) and
  (.properties.result_record_contract | type == "object") and
  (.properties.result_record_contract.properties.state_model.required | sort) == (["disposition","execution","evaluator_verdict","claimed_outcome","failure_classification","rule"] | sort) and
  (.properties.result_record_contract.properties.state_model.properties | keys) == ["claimed_outcome","disposition","evaluator_verdict","execution","failure_classification","rule"] and
  (.properties.cases | type == "object") and
  (.properties.gates | type == "object") and
  (.definitions.case | type == "object") and
  (.definitions.gate | type == "object") and
  (.definitions.moxygen_binding | type == "object") and
  (.definitions.independent_driver_binding | type == "object") and
  (.definitions.binding_gate_timeouts | type == "object") and
  (.definitions.retired_identifier | type == "object") and
  (.definitions.verified_implementation_revision | type == "object") and
  (.definitions.support_evidence_link | type == "object") and
  (.definitions.support_result_link | type == "object") and
  (.definitions.result_record | type == "object") and
  (.definitions.phase_timings | type == "object") and
  (.definitions.assertion_id.enum | type == "array") and
  (.definitions.assertion | type == "object") and
  (.definitions.evidence | type == "object") and
  (.definitions.deployment | type == "object") and
  (.definitions.result_record.required | contains(["identity","disposition","execution","evaluator_verdict","claimed_outcome","failure_classification","independence_class","reproducibility","evidence_integrity_verification","provenance_verification","protocol","revisions","deployments","phase_timings_ms","assertions","evidence","reproduction"])) and
  (.definitions.result_identity.required | contains(["profile_id","profile_version","profile_revision","target_draft","gate_id","gate_revision","driver_binding","source_binding"])) and
  (.definitions.exact_revisions.required | contains(["schema_version","profile_version","profile_revision","target_draft","gate_revision","normative_draft_sha","moxygen_declaration_baseline_sha","driver_review_baseline_sha","runner_sha","driver_landing_sha"])) and
  (.definitions.assertion.required | contains(["id","description","basis","status","expected","observed","evidence_ids"])) and
  (.definitions.evidence.required | contains(["id","category","kind","sha256","media_type","byte_length","producer","captured_at_utc","locator"])) and
  (.definitions.deployment.required | contains(["name","role","visibility","version","source_sha","image_digest","opaque"])) and
  .definitions.result_identity.properties.profile_version.const == "1.0.0" and
  .definitions.result_identity.properties.profile_revision.const == 1 and
  .definitions.result_identity.properties.gate_revision.const == 1 and
  .definitions.exact_revisions.properties.normative_draft_sha.const == "cb2e772fd8ca8cbe7550b1765c269be89fb1c886" and
  .definitions.exact_revisions.properties.moxygen_declaration_baseline_sha.const == "0d886e3e907e2236a6d927afefd09bb0c3dc8211" and
  .definitions.exact_revisions.properties.driver_review_baseline_sha.enum == ["0d886e3e907e2236a6d927afefd09bb0c3dc8211","b01d3f6707e3a74f69905722b451a08cbb3364f3"] and
  .definitions.exact_revisions.properties.driver_landing_sha.pattern == "^[0-9a-f]{40}$" and
  .definitions.semantic_id.pattern == "^[a-z]+(?:-[a-z]+)*$" and
  .definitions.binding_gate_timeouts.required == ["moxygen_driver","independent_driver"] and
  .definitions.binding_gate_timeouts.properties.moxygen_driver.const == 10000 and
  .definitions.binding_gate_timeouts.properties.independent_driver.const == 20000 and
  .properties.execution_policy.properties.independent_driver_timeout_components_ms.properties.rendezvous.const == 10000 and
  .properties.execution_policy.properties.independent_driver_timeout_components_ms.properties.delivery_and_terminal_margin.const == 10000 and
  .definitions.retired_identifier.required == ["kind","id","last_valid_target","last_valid_profile_revision","reason"] and
  .properties.identifier_history.properties.reviewed_for_target.const == "draft-18" and
  .properties.support_verification.properties.target_draft.const == "draft-18" and
  (.properties.support_verification.allOf | length) == 4 and
  .properties.support_verification.allOf[1].then.properties.verified_gate_ids.const == .definitions.result_identity.properties.gate_id.enum and
  (.properties.support_verification.allOf[1].then.properties.result_links.allOf | length) == 7 and
  .definitions.verified_implementation_revision.properties.source_sha.pattern == "^[0-9a-f]{40}$" and
  .definitions.verified_implementation_revision.properties.image_digest.pattern == "^sha256:[0-9a-f]{64}$" and
  (.definitions.assertion_id.enum | length) == 21 and
  .definitions.phase_timings.properties.readiness_ms.maximum == 10000 and
  .definitions.phase_timings.properties.publisher_readiness_ms.maximum == 10000 and
  .definitions.phase_timings.properties.delivery_terminal_ms.maximum == 10000 and
  .definitions.phase_timings.properties.case_ms.maximum == 10000 and
  .properties.oracle.properties.binding_reference_rule.const == "gate_normative_references apply to the implementation-neutral semantic contract; binding-specific references and limitations are labeled by driver binding." and
  .definitions.result_identity.properties.gate_id.enum == ["subscribe-one-subgroup-per-group","subscribe-one-subgroup-per-object","subscribe-two-subgroups-per-group","subscribe-nonzero-start-group","subscribe-nonzero-start-object","subscribe-sparse-group-object-ids","subscribe-object-properties"] and
  .definitions.actual_protocol.required == ["transport","negotiated_draft","transport_alpn","webtransport_protocol"] and
  .definitions.assertion.properties.basis.enum == ["profile-fixture-requirement","draft-protocol-requirement"] and
  .definitions.evidence.properties.category.enum == ["publisher-readiness","control-observations","object-observations","delivery-observations","tap14","process-logs","reproduction-metadata"] and
  (.definitions.result_record.properties.evidence.allOf | length) == 7 and
  (.definitions.result_record.oneOf | length) == 4 and
  (.definitions.result_record.allOf | length) == 20 and
  .definitions.result_record.allOf[0].then.properties.assertions.minItems == 3 and
  .definitions.result_record.allOf[0].then.properties.assertions.maxItems == 3 and
  .definitions.result_record.allOf[1].then.properties.evidence_integrity_verification.const == "verified" and
  .definitions.result_record.allOf[1].then.properties.provenance_verification.const == "verified" and
  .definitions.result_record.allOf[1].then.properties.assertions.minItems == 3 and
  .definitions.result_record.allOf[1].then.properties.assertions.maxItems == 3 and
  .definitions.result_record.allOf[5].then.properties.reproduction.properties.per_case_timeout_ms.const == 10000 and
  .definitions.result_record.allOf[6].then.properties.reproduction.properties.per_case_timeout_ms.const == 20000 and
  (.definitions.result_record.allOf[7].then.properties.phase_timings_ms.required | contains(["publisher_readiness_ms","case_ms"])) and
  (.definitions.result_record.allOf[8].then.properties.phase_timings_ms.required | contains(["setup_ms","readiness_ms","delivery_terminal_ms"])) and
  .definitions.result_record.allOf[9].then.properties.failure_classification.enum == ["none","driver-inconclusive"] and
  (.definitions.result_record.allOf[9].then.anyOf | length) == 3 and
  .definitions.result_record.allOf[10].then.properties.failure_classification.const == "none" and
  .definitions.result_record.allOf[11].then.properties.failure_classification.const == "none" and
  .definitions.result_record.allOf[12].then.properties.claimed_outcome.const == "unsupported" and
  [.definitions.result_record.allOf[13:][] | .if.properties.identity.properties.gate_id.const] == .definitions.result_identity.properties.gate_id.enum and
  (.definitions.deployment.allOf | length) == 2 and
  (.definitions.independent_driver_vector.required | contains(["namespace_prefix","namespace_rule","publisher_cid_component","track_name","groups","object_ids","subgroups","publisher_priority_by_subgroup","payloads"])) and
  .definitions.fixed_payload_contract.properties.kind.const == "fixed-source-constants" and
  .definitions.fixed_payload_contract.properties.unique_per_object.const == true and
  .definitions.fixed_payload_contract.properties.verification.const == "exact-byte-match" and
  (.definitions.fixed_payload_contract.required | index("items")) != null and
  .definitions.independent_driver_object_property.properties.type.not.minimum == 16384 and
  .definitions.independent_driver_object_property.properties.type.not.maximum == 32767 and
  .definitions.independent_driver_binding.properties.planned_function.enum == ["test_subscribe_one_subgroup_per_group","test_subscribe_one_subgroup_per_object","test_subscribe_two_subgroups_per_group","test_subscribe_nonzero_start_group","test_subscribe_nonzero_start_object","test_subscribe_sparse_group_object_ids","test_subscribe_object_properties"] and
  .definitions.moxygen_binding.properties.implementation.const == "moxygen" and
  .definitions.moxygen_binding.properties.repository.const == "https://github.com/facebookexperimental/moxygen" and
  .definitions.moxygen_binding.properties.independence_classification.const == "independent-source-generator-and-observer" and
  .definitions.independent_driver_binding.properties.implementation.const == "moq-rs" and
  .definitions.independent_driver_binding.properties.repository.const == "https://github.com/cloudflare/moq-rs" and
  .definitions.independent_driver_binding.properties.independence_classification.const == "independently-authored-generator-and-observer" and
  .definitions.evidence.properties.sha256.pattern == "^[0-9a-f]{64}$" and
  .definitions.reproduction.properties.per_case_timeout_ms.enum == [10000,20000] and
  .definitions.deployment.properties.image_digest.oneOf[0].pattern == "^sha256:[0-9a-f]{64}$"
' "$SCHEMA" >/dev/null; then
  echo "ERROR: schema-critical JSON Schema shape is invalid" >&2
  exit 1
fi

check() {
  local description=$1
  local filter=$2

  if ! jq -e "$filter" "$PROFILE" >/dev/null; then
    echo "ERROR: $description" >&2
    exit 1
  fi
}

check_digest() {
  local description=$1
  local expected=$2
  local filter=$3
  local actual

  read -r actual _ < <(jq -cS "$filter" "$PROFILE" | sha256sum)
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: $description (expected $expected, got $actual)" >&2
    exit 1
  fi
}

check "schema-critical top-level shape is invalid" '
  type == "object" and
  .["$schema"] == "./moxygen-relay-support-profile.schema.json" and
  .schema_version == "1.0.0" and
  (.profile | type == "object") and
  (.provenance | type == "object") and
  (.implementation_bindings | type == "object") and
  (.oracle | type == "object") and
  (.identifier_policy | type == "object") and
  (.identifier_history | type == "object") and
  (.support_verification | type == "object") and
  (.capability_boundaries.not_claimed | type == "array") and
  (.execution_policy | type == "object") and
  (.executable_requirements | type == "object") and
  (.known_driver_risks | type == "object") and
  (.disposition_reasons | type == "object") and
  (.implementation_independence_classes | type == "object") and
  (.result_semantics | type == "array") and
  (.required_evidence | type == "object") and
  (.binding_evidence_contracts | type == "object") and
  (.result_record_contract | type == "object") and
  (.cases | type == "array") and
  (.gates | type == "array")'

check "unknown manifest, profile, provenance, case, gate, binding, or result-contract keys are present" '
  (keys == ["$schema","binding_evidence_contracts","capability_boundaries","cases","disposition_reasons","executable_requirements","execution_policy","gates","identifier_history","identifier_policy","implementation_bindings","implementation_independence_classes","known_driver_risks","oracle","profile","provenance","required_evidence","result_record_contract","result_semantics","schema_version","support_verification"]) and
  (.profile | keys == ["declaration_count","deferred_count","diagnostic_gate_count","id","intended_count","revision","target_draft","version"]) and
  (.provenance | keys == ["executable_landings","reference_baselines"]) and
  (.provenance.reference_baselines | keys == ["moxygen_declarations","normative_draft","runner_baseline"]) and
  (.provenance.executable_landings | keys == ["independent_driver","moxygen_conformance_driver"]) and
  (.implementation_bindings | keys == ["independent_driver"]) and
  (.implementation_bindings.independent_driver | keys == ["implementation_id","non_normative","repository","review_sha","role"]) and
  (.identifier_policy | keys == ["equivalent_migration","gate_ids","profile_id","retired_id_reuse","semantic_change","source_binding_ids","source_ordinals_and_names","unified_semantic_test_ids"]) and
  (.identifier_history | keys == ["compatibility","retired_ids","reviewed_for_target"]) and
  (.support_verification | keys == ["driver_binding","evidence_links","invalidated_at","invalidation_conditions","invalidation_reason","pinned_implementation_revision","result_links","state","target_draft","verified_at","verified_gate_ids","verified_role","verified_subject"]) and
  all(.identifier_history.retired_ids[];
    (keys == ["id","kind","last_valid_profile_revision","last_valid_target","reason"] or
     keys == ["id","kind","last_valid_profile_revision","last_valid_target","reason","replacement_id"])) and
  (.execution_policy | keys == ["diagnostic_gate_timeouts_ms","independent_driver_timeout_components_ms","intended_case_timeouts_ms","readiness_timeout_ms","rule","runner_whole_container_limit_ms"]) and
  (.execution_policy.independent_driver_timeout_components_ms | keys == ["delivery_and_terminal_margin","rendezvous"]) and
  all(.cases[]; keys == ["disposition","gate_ids","id","independence","ordinal","reason","request","source_name","source_section"]) and
  all(.gates[]; keys == ["bindings","evidence","gate_normative_references","id","moxygen_source_binding_id","required_assertion_ids","revision","semantic_contract"]) and
  all(.gates[].bindings; keys == ["independent_driver","moxygen_driver"]) and
  all(.gates[].bindings.moxygen_driver; keys == ["binding_classification","implementation","independence_classification","readiness","repository","source_name","source_ordinal","topology","vector"]) and
  all(.gates[].bindings.independent_driver; keys == ["binding_classification","derivation","implementation","independence_classification","planned_function","repository","topology","vector"]) and
  (.result_record_contract | keys == ["assertion_descriptor","assertion_linkage_rule","driver_provenance_rule","evidence_descriptor","executable_provenance_rule","identity_rule","independence_classes","opaque_deployment_policy","phase_timing_rule","schema_ref","state_model","verification_rule","version"]) and
  (.result_record_contract.state_model | keys == ["claimed_outcome","disposition","evaluator_verdict","execution","failure_classification","rule"]) and
  (.result_record_contract.assertion_descriptor | keys == ["required","unique_by"]) and
  (.result_record_contract.evidence_descriptor | keys == ["digest","required","unique_by"]) and
  (.result_record_contract.opaque_deployment_policy | keys == ["result_handling","rule"])'

check "profile identity or declared counts are invalid" '
  .profile.id == "moxygen-relay-support-profile" and
  .profile.version == "1.0.0" and
  .profile.revision == 1 and
  .profile.target_draft == "draft-18" and
  .profile.declaration_count == 58 and
  .profile.intended_count == 27 and
  .profile.deferred_count == 31 and
  .profile.diagnostic_gate_count == 7'

check "pinned provenance does not match the reviewed sources" '
  .provenance.reference_baselines.normative_draft.tag == "draft-ietf-moq-transport-18" and
  .provenance.reference_baselines.normative_draft.sha == "cb2e772fd8ca8cbe7550b1765c269be89fb1c886" and
  .provenance.reference_baselines.moxygen_declarations.sha == "0d886e3e907e2236a6d927afefd09bb0c3dc8211" and
  .provenance.reference_baselines.runner_baseline.sha == "e63ee5aa0b22b16cbd86d022840a7e74fd806602" and
  .implementation_bindings.independent_driver == {
    "implementation_id":"moq-rs",
    "repository":"https://github.com/cloudflare/moq-rs",
    "review_sha":"b01d3f6707e3a74f69905722b451a08cbb3364f3",
    "non_normative":true,
    "role":"controlled-independent-evidence-driver"
  }'

profile_target_draft=$(jq -er '.profile.target_draft' "$PROFILE")
reference_target_draft=$(jq -er '.current_target' "$TARGET_DRAFT_REFERENCE")

if [[ "$profile_target_draft" != "$reference_target_draft" ]]; then
  echo "ERROR: profile target_draft does not match reference current_target: $TARGET_DRAFT_REFERENCE" >&2
  exit 1
fi

check_formal_target_declarations() {
  local document=$1
  local expected_target="**Target Draft**: \`$profile_target_draft\`"
  local expected_review="**Identifier Semantics Reviewed For**: \`$profile_target_draft\`"
  local target_count=0
  local review_count=0
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "**Target Draft**:"* ]]; then
      if [[ "$line" != "$expected_target" ]]; then
        echo "ERROR: stale target draft declaration in $document: $line" >&2
        exit 1
      fi
      target_count=$((target_count + 1))
    elif [[ "$line" == "**Identifier Semantics Reviewed For**:"* ]]; then
      if [[ "$line" != "$expected_review" ]]; then
        echo "ERROR: stale identifier review declaration in $document: $line" >&2
        exit 1
      fi
      review_count=$((review_count + 1))
    fi
  done < "$document"

  if [[ "$target_count" -ne 1 || "$review_count" -ne 1 ]]; then
    echo "ERROR: expected exactly one formal target and identifier review declaration in $document" >&2
    exit 1
  fi
}

check_formal_target_declarations "$PROFILE_DOCUMENT"
check_formal_target_declarations "$GATE_DOCUMENT"

check "a pinned provenance SHA is not 40 lowercase hexadecimal characters" '
  [
    .provenance.reference_baselines.normative_draft.sha,
    .provenance.reference_baselines.moxygen_declarations.sha,
    .implementation_bindings.independent_driver.review_sha,
    .provenance.reference_baselines.runner_baseline.sha
  ] | all(test("^[0-9a-f]{40}$"))'

check "executable landings must remain explicitly unresolved/TBD" '
  .provenance.executable_landings.moxygen_conformance_driver == {"status":"unresolved","sha":"TBD","image_digest":"TBD"} and
  .provenance.executable_landings.independent_driver == {"status":"unresolved","sha":"TBD"}'

check "identifier lifecycle policy changed or weakened" '
  .identifier_policy == {
    "profile_id":"The profile ID identifies enduring protocol semantics through RFC publication and never encodes a draft version or implementation revision.",
    "gate_ids":"Gate IDs identify enduring protocol semantics through RFC publication and never encode a draft version, source ordinal, or implementation revision.",
    "source_binding_ids":"The seven gate-mapped source bindings share enduring semantic test IDs with their gates. The other 51 IDs are semantic inventory handles for this profile revision, not canonical executable tests until they receive formal contracts.",
    "unified_semantic_test_ids":"One semantic test ID can have multiple driver bindings; a gate and its moxygen source binding intentionally share that ID when they represent the same protocol behavior.",
    "source_ordinals_and_names":"ordinal and source_name reproduce declarations in the pinned moxygen script as separate source provenance and do not define identifier semantics.",
    "equivalent_migration":"An equivalent editorial or section-only migration that preserves semantics, pass criteria, and applicability retains the ID and updates every reference atomically.",
    "semantic_change":"An incompatible change to semantics, pass criteria, or applicability permanently retires the old ID and introduces a new semantic ID.",
    "retired_id_reuse":"The retired-ID history is append-only, and a retired ID is never reused."
  }'

check "identifier review target or retired-ID history is invalid" '
  . as $profile |
  [.profile.id] as $active_profile_ids |
  ([.cases[].id] + [.gates[].id] | unique) as $active_test_ids |
  .identifier_history.retired_ids as $retired |
  .identifier_history.reviewed_for_target == .profile.target_draft and
  .identifier_history.compatibility == "The prior draft-specific profile commit was unpublished and produced no accepted ecosystem identifiers or results; therefore this semantic migration requires no aliases or retirement entries." and
  ([$retired[].id] | length) == ([$retired[].id] | unique | length) and
  all($retired[];
    . as $retired_id |
    (.kind == "profile" or .kind == "semantic-test") and
    (.id | test("^[a-z]+(-[a-z]+)*$")) and
    (if .kind == "profile" then
       ($active_profile_ids | index($retired_id.id) | not)
     else
       ($active_test_ids | index($retired_id.id) | not)
     end) and
    (.last_valid_target | test("^(draft|rfc)-[0-9]+$")) and
    (.last_valid_profile_revision | type == "number" and floor == . and . >= 1 and . <= $profile.profile.revision) and
    (.reason | type == "string" and test("^\\S(?:.*\\S)?$")) and
    ((has("replacement_id") | not) or
      ((.replacement_id | test("^[a-z]+(-[a-z]+)*$")) and .replacement_id != .id)))'

check "support verification result coverage is incomplete or ambiguous" '
  . as $profile |
  .support_verification as $support |
  if $support.state == "unverified" then
    $support.verified_gate_ids == [] and $support.result_links == [] and $support.evidence_links == []
  else
    ($support.verified_gate_ids | sort) == ([ $profile.gates[].id ] | sort) and
    ([$support.result_links[].gate_id] | sort) == ([ $profile.gates[].id ] | sort) and
    ([$support.result_links[].gate_id] | length) == ([$support.result_links[].gate_id] | unique | length) and
    ([$support.result_links[].locator] | length) == ([$support.result_links[].locator] | unique | length) and
    ([$support.result_links[].sha256] | length) == ([$support.result_links[].sha256] | unique | length) and
    ($support.evidence_links | length) > 0 and
    ([$support.evidence_links[].locator] | length) == ([$support.evidence_links[].locator] | unique | length) and
    ([$support.evidence_links[].sha256] | length) == ([$support.evidence_links[].sha256] | unique | length)
  end'

check "support invalidation predates verification" '
  if .support_verification.verified_at != null and .support_verification.invalidated_at != null then
    ((.support_verification.invalidated_at | fromdateiso8601) >=
     (.support_verification.verified_at | fromdateiso8601))
  else true end'

check "support verification state is overstated or internally inconsistent" '
  .support_verification.state == "unverified" and
  .support_verification.verified_at == null and
  .support_verification.invalidated_at == null and
  .support_verification.invalidation_reason == null and
  .support_verification.verified_gate_ids == [] and
  .support_verification.driver_binding == null and
  .support_verification.pinned_implementation_revision == "TBD" and
  .support_verification.verified_subject == null and
  .support_verification.verified_role == null and
  .support_verification.target_draft == .profile.target_draft and
  .support_verification.result_links == [] and
  .support_verification.evidence_links == [] and
  .support_verification.invalidation_conditions == [
    "target-draft-semantic-change",
    "profile-or-gate-criteria-revision",
    "implementation-revision-or-image-change",
    "evidence-loss-or-invalidation"
  ]'

check "semantic gates and implementation bindings are not cleanly separated" '
  (.oracle.semantic_layer | contains("without prescribing an implementation")) and
  (.oracle.binding_rule | contains("not normative protocol behavior")) and
  .oracle.binding_reference_rule == "gate_normative_references apply to the implementation-neutral semantic contract; binding-specific references and limitations are labeled by driver binding." and
  all(.gates[];
    ((.semantic_contract | tostring | test("moxygen|moq-test-00|moqtest"; "i")) | not) and
    .bindings.moxygen_driver.binding_classification == "moxygen-driver-binding" and
    .bindings.independent_driver.binding_classification == "independent-driver-binding")'

check "per-case timeout policy is incomplete or exceeds the runner container limit" '
  . as $profile |
  .execution_policy.runner_whole_container_limit_ms == 120000 and
  .execution_policy.readiness_timeout_ms == 10000 and
  (.execution_policy.diagnostic_gate_timeouts_ms | keys | sort) == ([.gates[].id] | sort) and
  all(.execution_policy.diagnostic_gate_timeouts_ms[];
    keys == ["independent_driver","moxygen_driver"] and
    .moxygen_driver == 10000 and
    .independent_driver == 20000) and
  .execution_policy.independent_driver_timeout_components_ms == {
    "rendezvous":10000,
    "delivery_and_terminal_margin":10000
  } and
  (.execution_policy.independent_driver_timeout_components_ms.rendezvous +
   .execution_policy.independent_driver_timeout_components_ms.delivery_and_terminal_margin) == 20000 and
  all(.execution_policy.diagnostic_gate_timeouts_ms[];
    .independent_driver ==
      ($profile.execution_policy.independent_driver_timeout_components_ms.rendezvous +
       $profile.execution_policy.independent_driver_timeout_components_ms.delivery_and_terminal_margin)) and
  ([.execution_policy.diagnostic_gate_timeouts_ms[].moxygen_driver] | add) == 70000 and
  (.execution_policy.intended_case_timeouts_ms | keys | sort) == ([.cases[] | select(.disposition == "intended") | .id] | sort) and
  .execution_policy.intended_case_timeouts_ms["subscribe-low-frequency-updates"] >= 30000 and
  .execution_policy.intended_case_timeouts_ms["subscribe-many-groups-and-objects"] >= 30000 and
  all(.execution_policy.intended_case_timeouts_ms[]; . < 120000) and
  all(.execution_policy.diagnostic_gate_timeouts_ms[];
    .moxygen_driver < 120000 and .independent_driver < 120000) and
  (.execution_policy.rule | contains("by gate ID and driver binding")) and
  (.execution_policy.rule | contains("70000 ms")) and
  (.execution_policy.rule | contains("120000 ms"))'

check "executable TLS/provenance requirements or moxygen ordering-risk handling are incomplete" '
  (.executable_requirements.tls_disable_verify | contains("honor TLS_DISABLE_VERIFY")) and
  (.executable_requirements.tls_disable_verify | contains("always installs an insecure verifier")) and
  (.executable_requirements.resolved_provenance | contains("never accept TBD")) and
  .known_driver_risks.moxygen_global_cross_stream_ordering.status == "open-until-fixed-executable-sha" and
  .known_driver_risks.moxygen_global_cross_stream_ordering.resolved_by_sha == "TBD" and
  (.known_driver_risks.moxygen_global_cross_stream_ordering.result_rule | contains("driver-inconclusive")) and
  (.known_driver_risks.moxygen_global_cross_stream_ordering.result_rule | contains("never classify the relay as failed"))'

check "case totals must be exactly 58/27/31 with contiguous ordinals" '
  (.cases | length) == 58 and
  ([.cases[] | select(.disposition == "intended")] | length) == 27 and
  ([.cases[] | select(.disposition == "deferred")] | length) == 31 and
  [.cases[].ordinal] == [range(1; 59)]'

check "case IDs and source names must each be unique" '
  ([.cases[].id] | length) == ([.cases[].id] | unique | length) and
  ([.cases[].source_name] | length) == ([.cases[].source_name] | unique | length)'

check "case shape, dispositions, reasons, or independence classes are invalid" '
  .disposition_reasons as $reasons |
  all(.cases[];
    (.id | test("^[a-z]+(-[a-z]+)*$")) and
    (.source_name | type == "string" and length > 0) and
    (.source_section | type == "string" and length > 0) and
    (.request == "subscribe" or .request == "fetch" or .request == "publish") and
    (.disposition == "intended" or .disposition == "deferred") and
    ($reasons[.reason] | type == "string" and length > 0) and
    (.independence == "planned-independent-gate" or
     .independence == "profile-inventory-only" or
     .independence == "deferred-unsupported") and
    (.gate_ids | type == "array"))'

check "deferred reason partition must be exactly 9/8/4/7/2/1" '
  ([.cases[] | select(.reason == "fetch-unsupported")] | length) == 9 and
  ([.cases[] | select(.reason == "subscribe-tracks-unsupported" or .reason == "subscribe-tracks-request-update-unsupported")] | length) == 8 and
  ([.cases[] | select(.reason == "subscribe-tracks-request-update-unsupported")] | length) == 2 and
  ([.cases[] | select(.reason == "datagram-unsupported")] | length) == 4 and
  ([.cases[] | select(.reason == "object-status-unsupported")] | length) == 7 and
  ([.cases[] | select(.reason == "invalid-object-property-scope")] | length) == 2 and
  ([.cases[] | select(.reason == "invalid-object-property-scope") | .id] | sort) == (["subscribe-integer-property-type-two","subscribe-integer-and-bytes-properties"] | sort) and
  ([.cases[] | select(.reason == "publisher-delivery-timeout-unsupported")] | length) == 1 and
  all(.cases[] | select(.disposition == "deferred");
    (.reason == "fetch-unsupported" or
     .reason == "subscribe-tracks-unsupported" or
     .reason == "subscribe-tracks-request-update-unsupported" or
     .reason == "datagram-unsupported" or
     .reason == "object-status-unsupported" or
     .reason == "invalid-object-property-scope" or
     .reason == "publisher-delivery-timeout-unsupported"))'

check "diagnostic gates must have seven unique immutable IDs, source bindings, and functions" '
  (.gates | length) == 7 and
  ([.gates[].id] | length) == ([.gates[].id] | unique | length) and
  ([.gates[].moxygen_source_binding_id] | length) == ([.gates[].moxygen_source_binding_id] | unique | length) and
  ([.gates[].bindings.moxygen_driver.source_name] | length) == ([.gates[].bindings.moxygen_driver.source_name] | unique | length) and
  ([.gates[].bindings.independent_driver.planned_function] | length) == ([.gates[].bindings.independent_driver.planned_function] | unique | length) and
  all(.gates[]; . as $gate |
    .revision == 1 and
    (.id | test("^[a-z]+(-[a-z]+)*$")) and
    (.moxygen_source_binding_id | test("^[a-z]+(-[a-z]+)*$")) and
    (.semantic_contract.topology_roles == ["publisher","relay-under-test","subscriber"]) and
    (.semantic_contract.scenario | type == "string" and length > 0) and
    (.semantic_contract.success_criteria | type == "array" and length > 0) and
    (.required_assertion_ids | type == "array" and length == ($gate.semantic_contract.success_criteria | length)) and
    ([.required_assertion_ids[]] | length) == ([.required_assertion_ids[]] | unique | length) and
    all(.required_assertion_ids[]; startswith($gate.id + ".")) and
    .bindings.moxygen_driver.binding_classification == "moxygen-driver-binding" and
    .bindings.moxygen_driver.implementation == "moxygen" and
    .bindings.moxygen_driver.repository == "https://github.com/facebookexperimental/moxygen" and
    .bindings.moxygen_driver.independence_classification == "independent-source-generator-and-observer" and
    .bindings.moxygen_driver.topology == "moxygen moqtest_server -> relay-under-test -> moxygen moqtest_client" and
    (.bindings.moxygen_driver.readiness | contains("REQUEST_OK")) and
    .bindings.independent_driver.binding_classification == "independent-driver-binding" and
    .bindings.independent_driver.implementation == "moq-rs" and
    .bindings.independent_driver.repository == "https://github.com/cloudflare/moq-rs" and
    .bindings.independent_driver.independence_classification == "independently-authored-generator-and-observer" and
    .bindings.independent_driver.topology == "independent publisher role -> relay-under-test -> independent subscriber role" and
    (.bindings.independent_driver.planned_function | test("^test_[a-z]+(_[a-z]+)*$")) and
    (.bindings.independent_driver.derivation | type == "string" and length > 0) and
    (.gate_normative_references | type == "array" and length > 0) and
    (.gate_normative_references | (index("7") != null and index("9") != null)) and
    (.bindings.moxygen_driver.vector.track_namespace | type == "array" and length == 16) and
    .bindings.moxygen_driver.vector.track_namespace[0] == "moq-test-00" and
    (.bindings.independent_driver.vector.namespace_prefix | test("^moq-test/interop/[a-z]+(-[a-z]+)*$")) and
    .bindings.independent_driver.vector.namespace_prefix == ("moq-test/interop/" + $gate.id) and
    .bindings.independent_driver.vector.namespace_rule == (.bindings.independent_driver.vector.namespace_prefix + "/{publisher_cid}") and
    .bindings.independent_driver.vector.publisher_cid_component == {"source":"publisher_connection_id","purpose":"per-run namespace uniqueness and exact-track routing isolation"} and
    (.bindings.independent_driver.vector.payloads | del(.items)) == {"kind":"fixed-source-constants","unique_per_object":true,"verification":"exact-byte-match"} and
    (.bindings.independent_driver.vector.payloads.items | type == "array" and length > 0) and
    all(.bindings.independent_driver.vector.payloads.items[];
      (keys == ["ascii","group","hex","object","subgroup"]) and
      (.ascii | type == "string" and length > 0) and
      .ascii == ($gate.id + "-g" + (.group|tostring) + "-s" + (.subgroup|tostring) + "-o" + (.object|tostring)) and
      (.hex | test("^([0-9a-f]{2})+$"))) and
    (.bindings.independent_driver.vector as $vector |
      ([ $vector.groups[] as $group | $vector.subgroups | to_entries[] | . as $subgroup | $subgroup.value[] | {group:$group,subgroup:($subgroup.key|tonumber),object:.} ] | sort_by(.group,.subgroup,.object)) ==
      ([ $vector.payloads.items[] | {group,subgroup,object} ] | sort_by(.group,.subgroup,.object)) and
      ([ $vector.groups[] as $group | $vector.subgroups | keys[] | ($group|tostring) + "/" + . ] | unique | sort) == ($vector.publisher_priority_by_subgroup | keys | sort) and
      ([ $vector.payloads.items[].ascii ] | length) == ([ $vector.payloads.items[].ascii ] | unique | length) and
      ([ $vector.payloads.items[].hex ] | length) == ([ $vector.payloads.items[].hex ] | unique | length)) and
    (.evidence | type == "array" and length > 0))'

check "canonical gate identities, functions, vectors, or totals changed" '
  [.gates[].id] == [
    "subscribe-one-subgroup-per-group",
    "subscribe-one-subgroup-per-object",
    "subscribe-two-subgroups-per-group",
    "subscribe-nonzero-start-group",
    "subscribe-nonzero-start-object",
    "subscribe-sparse-group-object-ids",
    "subscribe-object-properties"
  ] and
  [.gates[].moxygen_source_binding_id] == [
    "subscribe-one-subgroup-per-group",
    "subscribe-one-subgroup-per-object",
    "subscribe-two-subgroups-per-group",
    "subscribe-nonzero-start-group",
    "subscribe-nonzero-start-object",
    "subscribe-sparse-group-object-ids",
    "subscribe-object-properties"
  ] and
  [.gates[].bindings.moxygen_driver.source_ordinal] == [1,2,3,12,13,29,40] and
  [.gates[].bindings.independent_driver.planned_function] == [
    "test_subscribe_one_subgroup_per_group",
    "test_subscribe_one_subgroup_per_object",
    "test_subscribe_two_subgroups_per_group",
    "test_subscribe_nonzero_start_group",
    "test_subscribe_nonzero_start_object",
    "test_subscribe_sparse_group_object_ids",
    "test_subscribe_object_properties"
  ] and
  [.gates[].bindings.moxygen_driver.vector.track_namespace] == [
    ["moq-test-00","0","0","0","2","5","5","1024","100","50","1","1","0","-1","-1","0"],
    ["moq-test-00","1","0","0","2","5","5","1024","100","50","1","1","0","-1","-1","0"],
    ["moq-test-00","2","0","0","2","6","6","1024","100","50","1","1","0","-1","-1","0"],
    ["moq-test-00","0","5","0","7","3","3","1024","100","50","1","1","0","-1","-1","0"],
    ["moq-test-00","0","0","3","1","8","8","1024","100","50","1","1","0","-1","-1","0"],
    ["moq-test-00","2","0","0","4","12","6","1024","100","50","2","2","0","-1","-1","0"],
    ["moq-test-00","1","0","0","1","4","4","1024","100","50","1","1","0","5","3","0"]
  ] and
  [.gates[].bindings.moxygen_driver.vector.expected_object_count] == [18,18,21,12,12,21,10] and
  [.gates[].bindings.moxygen_driver.vector.expected_stream_count] == [3,18,6,3,2,3,10] and
  [.gates[].bindings.independent_driver.vector.namespace_prefix] == [
    "moq-test/interop/subscribe-one-subgroup-per-group",
    "moq-test/interop/subscribe-one-subgroup-per-object",
    "moq-test/interop/subscribe-two-subgroups-per-group",
    "moq-test/interop/subscribe-nonzero-start-group",
    "moq-test/interop/subscribe-nonzero-start-object",
    "moq-test/interop/subscribe-sparse-group-object-ids",
    "moq-test/interop/subscribe-object-properties"
  ] and
  [.gates[].bindings.independent_driver.vector.track_name] == ["one-subgroup-per-group","one-subgroup-per-object","two-subgroups-per-group","nonzero-start-group","nonzero-start-object","sparse-group-object-ids","object-properties"] and
  [.gates[].bindings.independent_driver.vector.groups] == [[0,1],[0],[2],[5,6],[0],[0,2],[9]] and
  [.gates[].bindings.independent_driver.vector.object_ids] == [[0,1,2],[4,5,6],[0,1,2,3,4,5],[0,1],[3,4,5],[0,2,4],[4,7]] and
  [.gates[].bindings.independent_driver.vector.subgroups] == [
    {"0":[0,1,2]},
    {"40":[4],"41":[5],"42":[6]},
    {"10":[0,2,4],"11":[1,3,5]},
    {"0":[0,1]},
    {"7":[3,4,5]},
    {"0":[0,2,4]},
    {"7":[4,7]}
  ] and
  [.gates[].bindings.independent_driver.vector.publisher_priority_by_subgroup] == [
    {"0/0":17,"1/0":23},
    {"0/40":29,"0/41":31,"0/42":37},
    {"2/10":41,"2/11":43},
    {"5/0":47,"6/0":53},
    {"0/7":59},
    {"0/0":61,"2/0":67},
    {"9/7":59}
  ] and
  all(.gates[].bindings.independent_driver.vector.payloads; (del(.items)) == {"kind":"fixed-source-constants","unique_per_object":true,"verification":"exact-byte-match"}) and
  all(.gates[0:6][];
    (.bindings.independent_driver.vector | has("object_properties_by_object") | not) and
    (.bindings.independent_driver.vector | has("object_property_ranges") | not)) and
  .gates[6].bindings.independent_driver.vector.object_properties_by_object == {
    "4":[
      {"type":14336,"type_hex":"0x3800","value_kind":"integer","value":4660,"value_hex":"0x1234"},
      {"type":14337,"type_hex":"0x3801","value_kind":"bytes","value_ascii":"high-type-3801","value_hex":"686967682d747970652d33383031"}
    ],
    "7":[
      {"type":14338,"type_hex":"0x3802","value_kind":"integer","value":270544960,"value_hex":"0x10203040"},
      {"type":14339,"type_hex":"0x3803","value_kind":"bytes","value_ascii":"high-type-3803","value_hex":"686967682d747970652d33383033"}
    ]
  } and
  .gates[6].bindings.independent_driver.vector.object_property_ranges == {
    "application_specific":{"minimum":14336,"maximum":16383,"hex":"0x3800..0x3fff"},
    "forbidden_object_scope":{"minimum":16384,"maximum":32767,"hex":"0x4000..0x7fff"}
  }'

check "independent Object Properties enter the forbidden Object-scope range or use the wrong value form" '
  [.gates[] | (.bindings.independent_driver.vector.object_properties_by_object // {}) | .[] | .[]] |
  all(.[];
    (.type < 16384 or .type > 32767) and
    ((.value_kind == "integer" and (.type % 2) == 0 and (.value | type) == "number") or
     (.value_kind == "bytes" and (.type % 2) == 1 and (.value_ascii | type) == "string")))'

check "every gate must select an intended case with the same source name" '
  .cases as $cases |
  all(.gates[]; . as $gate |
    .id == .moxygen_source_binding_id and
    any($cases[];
      .id == $gate.moxygen_source_binding_id and
      .ordinal == $gate.bindings.moxygen_driver.source_ordinal and
      .source_name == $gate.bindings.moxygen_driver.source_name and
      .disposition == "intended" and
      .independence == "planned-independent-gate"))'

check "case gate references and gate declarations must match exactly" '
  ([.cases[].gate_ids[]] | sort) == ([.gates[].id] | sort) and
  all(.cases[] | select(.independence == "planned-independent-gate"); (.gate_ids | length) == 1) and
  all(.cases[] | select(.independence != "planned-independent-gate"); (.gate_ids | length) == 0)'

check "result semantics must be exactly the six canonical states" '
  ([.result_semantics[].id] | sort) == (["pass","fail","inconclusive","unsupported","not-run","harness-error"] | sort) and
  ([.result_semantics[].id] | unique | length) == 6 and
  all(.result_semantics[]; (.meaning | type == "string" and length > 0))'

check "required gate evidence is incomplete or references unknown descriptors" '
  (["publisher-readiness","control-observations","object-observations","delivery-observations","tap14","process-logs","reproduction-metadata"] | sort) as $required |
  (.required_evidence | keys | sort) == $required and
  all(.required_evidence[]; type == "string" and length > 0) and
  all(.gates[]; (.evidence | sort) == $required) and
  (.binding_evidence_contracts | keys) == ["independent_driver","moxygen_driver"] and
  (.binding_evidence_contracts.moxygen_driver.readiness | contains("same active case")) and
  (.binding_evidence_contracts.moxygen_driver.readiness | contains("announce-only run is not proof")) and
  .binding_evidence_contracts.independent_driver.not_directly_observed == ["publish-namespace-request-ok","raw-object-id-deltas","first-object-bit","wire-fin-or-reset"] and
  (.binding_evidence_contracts.independent_driver.completion | contains("TRACK_ENDED"))'

check "result record contract does not separate claims, evaluator verdict, evidence, and provenance" '
  .result_record_contract.version == "1.0.0" and
  .result_record_contract.schema_ref == "./moxygen-relay-support-profile.schema.json#/definitions/result_record" and
  .result_record_contract.state_model.disposition == ["intended","deferred"] and
  .result_record_contract.state_model.execution == ["not-run","started","completed","aborted"] and
  .result_record_contract.state_model.evaluator_verdict == ["pass","fail","inconclusive","unsupported","harness-error"] and
  .result_record_contract.state_model.claimed_outcome == ["pass","fail","inconclusive","unsupported","not-run","harness-error"] and
  .result_record_contract.state_model.failure_classification == ["none","profile-mismatch","protocol-contradiction","mixed","driver-inconclusive"] and
  (.result_record_contract.state_model.rule | contains("Fail requires complete verified evidence")) and
  (.result_record_contract.state_model.rule | contains("Inconclusive requires")) and
  (.result_record_contract.state_model.rule | contains("uses none or driver-inconclusive")) and
  .result_record_contract.independence_classes == ["moxygen-driver-binding","independent-driver-binding"] and
  (.result_record_contract.assertion_descriptor.required | sort) == (["id","description","basis","status","expected","observed","evidence_ids"] | sort) and
  .result_record_contract.assertion_descriptor.unique_by == "id" and
  (.result_record_contract.evidence_descriptor.required | sort) == (["id","category","kind","sha256","media_type","byte_length","producer","captured_at_utc","locator"] | sort) and
  .result_record_contract.evidence_descriptor.unique_by == "id" and
  (.result_record_contract.evidence_descriptor.digest | contains("external publication must recompute")) and
  (.result_record_contract.opaque_deployment_policy.rule | contains("image_digest=null")) and
  (.result_record_contract.opaque_deployment_policy.result_handling | contains("reproducibility=opaque")) and
  (.result_record_contract.phase_timing_rule | contains("duration_ms is aggregate process time")) and
  (.result_record_contract.phase_timing_rule | contains("at least the sum")) and
  (.result_record_contract.assertion_linkage_rule | contains("selected gate required_assertion_ids")) and
  (.result_record_contract.assertion_linkage_rule | contains("exactly that complete set")) and
  (.result_record_contract.driver_provenance_rule | contains("driver_review_baseline_sha resolves through the selected profile binding")) and
  (.result_record_contract.driver_provenance_rule | contains("publisher and subscriber deployment source_sha")) and
  (.result_record_contract.verification_rule | contains("submitted claims")) and
  (.result_record_contract.verification_rule | contains("evidence_integrity_verification=verified")) and
  (.result_record_contract.verification_rule | contains("provenance_verification=verified")) and
  (.result_record_contract.executable_provenance_rule | contains("never contain TBD"))'

check "unsupported capability boundaries are incomplete" '
  ([.capability_boundaries.not_claimed[]] | sort) == ([
    "timeout-expiration",
    "end-of-group-object-status",
    "datagram",
    "fetch",
    "subscribe-tracks",
    "request-update"
  ] | sort)'

check_digest "identifier, oracle, or result semantic policy drifted" \
  "41f9ca9ea5f739240bf6ca3b72a33c12e2951bcdec0571a62dce417212e606ca" \
  '{identifier_policy,identifier_history,implementation_bindings,support_verification,oracle,result_semantics,result_record_contract}'

check_digest "full 58-case inventory drifted" \
  "82708746e0a474bb9358bbf089723872a51267e17fe046364c4198604dee9a08" \
  '.cases | map({id,ordinal,source_name,source_section,request,disposition,reason,independence,gate_ids})'

check_digest "complete moxygen gate bindings drifted" \
  "ccb78b935d2c2624affa47b13a6677cd31d056fc37d124085986bd018df6b15b" \
  '.gates | map({id,revision,moxygen_source_binding_id,binding:.bindings.moxygen_driver})'

check_digest "complete independent gate bindings drifted" \
  "050a52cd87210b0f6f83d881162521aa3bff590c4684bb3bc4d6b035f63c7050" \
  '.gates | map({id,revision,binding:.bindings.independent_driver})'

check_digest "revision-1 gate references or semantic contracts drifted" \
  "d9c51b1e71706c65f3be97ea859a65ba5c8f3669a036cab30bb59c63defaf8e0" \
  '.gates | map({id,revision,required_assertion_ids,gate_normative_references,semantic_contract})'

check_digest "intended moxygen source-case timeouts drifted" \
  "b06aae3baeca3a99aae8b00b293e3564632e2d3f1f9008f6a4e0826584a9813e" \
  '.execution_policy.intended_case_timeouts_ms'

check_digest "provenance, timeout, TLS, or driver-risk policy drifted" \
  "f73f36e2cd62feadb705d4fb548c7a0a7aef06974561a459ebd357cac3beb814" \
  '{execution_policy,executable_requirements,known_driver_risks,provenance,implementation_bindings,binding_evidence_contracts,required_evidence}'

base_target_validator="$ROOT_DIR/scripts/validate-target-draft.sh"
if [[ -x "$base_target_validator" ]]; then
  "$base_target_validator" "$PROFILE_DOCUMENT" "$GATE_DOCUMENT"
fi

echo "Validated moxygen relay support profile for target draft-18: 58 cases (27 intended, 31 deferred), 7 gates"

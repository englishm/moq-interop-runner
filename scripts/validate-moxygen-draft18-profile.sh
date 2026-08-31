#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=${1:-"$ROOT_DIR/docs/moxygen-draft18-support-profile.json"}
SCHEMA=${2:-"$ROOT_DIR/docs/moxygen-draft18-support-profile.schema.json"}

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "ERROR: sha256sum is required" >&2
  exit 1
fi

for file in "$PROFILE" "$SCHEMA"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: missing file: $file" >&2
    exit 1
  fi
  jq empty "$file"
done

if ! jq -e '
  .["$schema"] == "http://json-schema.org/draft-07/schema#" and
  .type == "object" and
  (.required | type == "array") and
  (.properties.profile | type == "object") and
  (.properties.provenance | type == "object") and
  (.properties.result_record_contract | type == "object") and
  (.properties.result_record_contract.properties.state_model.required | sort) == (["disposition","execution","evaluator_verdict","claimed_outcome","failure_classification","rule"] | sort) and
  (.properties.result_record_contract.properties.state_model.properties | keys) == ["claimed_outcome","disposition","evaluator_verdict","execution","failure_classification","rule"] and
  (.properties.cases | type == "object") and
  (.properties.gates | type == "object") and
  (.definitions.case | type == "object") and
  (.definitions.gate | type == "object") and
  (.definitions.result_record | type == "object") and
  (.definitions.assertion | type == "object") and
  (.definitions.evidence | type == "object") and
  (.definitions.deployment | type == "object") and
  (.definitions.result_record.required | contains(["identity","disposition","execution","evaluator_verdict","claimed_outcome","failure_classification","independence_class","reproducibility","evidence_integrity_verification","provenance_verification","protocol","revisions","deployments","assertions","evidence","reproduction"])) and
  (.definitions.result_identity.required | contains(["profile_id","profile_version","profile_revision","gate_id","gate_revision","driver_binding","source_binding"])) and
  (.definitions.exact_revisions.required | contains(["schema_version","profile_version","profile_revision","gate_revision","normative_draft_sha","moxygen_declaration_baseline_sha","moq_rs_review_baseline_sha","runner_sha","driver_landing_sha"])) and
  (.definitions.assertion.required | contains(["id","description","basis","status","expected","observed","evidence_ids"])) and
  (.definitions.evidence.required | contains(["id","category","kind","sha256","media_type","byte_length","producer","captured_at_utc","locator"])) and
  (.definitions.deployment.required | contains(["name","role","visibility","version","source_sha","image_digest","opaque"])) and
  .definitions.result_identity.properties.profile_version.const == "1.0.0" and
  .definitions.result_identity.properties.profile_revision.const == 1 and
  .definitions.result_identity.properties.gate_revision.const == 1 and
  .definitions.exact_revisions.properties.normative_draft_sha.const == "cb2e772fd8ca8cbe7550b1765c269be89fb1c886" and
  .definitions.exact_revisions.properties.moxygen_declaration_baseline_sha.const == "0d886e3e907e2236a6d927afefd09bb0c3dc8211" and
  .definitions.exact_revisions.properties.moq_rs_review_baseline_sha.const == "b01d3f6707e3a74f69905722b451a08cbb3364f3" and
  .definitions.exact_revisions.properties.driver_landing_sha.pattern == "^[0-9a-f]{40}$" and
  .definitions.result_identity.properties.gate_id.enum == ["MOXYGEN-D18-DG-001","MOXYGEN-D18-DG-002","MOXYGEN-D18-DG-003","MOXYGEN-D18-DG-004","MOXYGEN-D18-DG-005","MOXYGEN-D18-DG-006","MOXYGEN-D18-DG-007"] and
  .definitions.actual_protocol.required == ["transport","negotiated_draft","transport_alpn","webtransport_protocol"] and
  .definitions.assertion.properties.basis.enum == ["profile-fixture-requirement","draft-protocol-requirement"] and
  .definitions.evidence.properties.category.enum == ["publisher-readiness","control-observations","object-observations","delivery-observations","tap14","process-logs","reproduction-metadata"] and
  (.definitions.result_record.properties.evidence.allOf | length) == 7 and
  (.definitions.result_record.oneOf | length) == 4 and
  (.definitions.result_record.allOf | length) >= 7 and
  (.definitions.deployment.allOf | length) == 2 and
  (.definitions.independent_vector.required | contains(["namespace_prefix","namespace_rule","publisher_cid_component","track_name","groups","object_ids","subgroups","publisher_priority_by_subgroup","payloads"])) and
  .definitions.fixed_payload_contract.properties.kind.const == "fixed-source-constants" and
  .definitions.fixed_payload_contract.properties.unique_per_object.const == true and
  .definitions.fixed_payload_contract.properties.verification.const == "exact-byte-match" and
  (.definitions.fixed_payload_contract.required | index("items")) != null and
  .definitions.independent_object_property.properties.type.not.minimum == 16384 and
  .definitions.independent_object_property.properties.type.not.maximum == 32767 and
  .definitions.independent_binding.properties.planned_function.pattern == "^test_moqt18_subscribe_[a-z0-9_]+$" and
  .definitions.evidence.properties.sha256.pattern == "^[0-9a-f]{64}$" and
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
  .["$schema"] == "./moxygen-draft18-support-profile.schema.json" and
  .schema_version == "1.0.0" and
  (.profile | type == "object") and
  (.provenance | type == "object") and
  (.oracle | type == "object") and
  (.identifier_policy | type == "object") and
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
  (keys == ["$schema","binding_evidence_contracts","capability_boundaries","cases","disposition_reasons","executable_requirements","execution_policy","gates","identifier_policy","implementation_independence_classes","known_driver_risks","oracle","profile","provenance","required_evidence","result_record_contract","result_semantics","schema_version"]) and
  (.profile | keys == ["declaration_count","deferred_count","diagnostic_gate_count","draft","id","intended_count","revision","version"]) and
  (.provenance | keys == ["executable_landings","reference_baselines"]) and
  (.provenance.reference_baselines | keys == ["moq_rs_review","moxygen_declarations","normative_draft","runner_baseline"]) and
  (.provenance.executable_landings | keys == ["moxygen_conformance_driver","rust_diagnostic_gates"]) and
  all(.cases[]; keys == ["disposition","gate_ids","id","independence","ordinal","reason","request","source_name","source_section"]) and
  all(.gates[]; keys == ["bindings","evidence","id","moxygen_source_binding_id","normative_references","revision","semantic_contract"]) and
  all(.gates[].bindings; keys == ["independent_moq_test_client","moxygen_driver"]) and
  all(.gates[].bindings.moxygen_driver; keys == ["classification","readiness","source_name","source_ordinal","topology","vector"]) and
  all(.gates[].bindings.independent_moq_test_client; keys == ["classification","derivation","planned_function","topology","vector"]) and
  (.result_record_contract | keys == ["assertion_descriptor","evidence_descriptor","executable_provenance_rule","identity_rule","independence_classes","opaque_deployment_policy","schema_ref","state_model","verification_rule","version"]) and
  (.result_record_contract.state_model | keys == ["claimed_outcome","disposition","evaluator_verdict","execution","failure_classification","rule"]) and
  (.result_record_contract.assertion_descriptor | keys == ["required","unique_by"]) and
  (.result_record_contract.evidence_descriptor | keys == ["digest","required","unique_by"]) and
  (.result_record_contract.opaque_deployment_policy | keys == ["result_handling","rule"])'

check "profile identity or declared counts are invalid" '
  .profile.id == "moxygen-draft18-support-profile" and
  .profile.version == "1.0.0" and
  .profile.revision == 1 and
  .profile.draft == "draft-ietf-moq-transport-18" and
  .profile.declaration_count == 58 and
  .profile.intended_count == 29 and
  .profile.deferred_count == 29 and
  .profile.diagnostic_gate_count == 7'

check "pinned provenance does not match the reviewed sources" '
  .provenance.reference_baselines.normative_draft.sha == "cb2e772fd8ca8cbe7550b1765c269be89fb1c886" and
  .provenance.reference_baselines.moxygen_declarations.sha == "0d886e3e907e2236a6d927afefd09bb0c3dc8211" and
  .provenance.reference_baselines.moq_rs_review.sha == "b01d3f6707e3a74f69905722b451a08cbb3364f3" and
  .provenance.reference_baselines.runner_baseline.sha == "e63ee5aa0b22b16cbd86d022840a7e74fd806602"'

check "a pinned provenance SHA is not 40 lowercase hexadecimal characters" '
  [
    .provenance.reference_baselines.normative_draft.sha,
    .provenance.reference_baselines.moxygen_declarations.sha,
    .provenance.reference_baselines.moq_rs_review.sha,
    .provenance.reference_baselines.runner_baseline.sha
  ] | all(test("^[0-9a-f]{40}$"))'

check "executable landings must remain explicitly unresolved/TBD" '
  .provenance.executable_landings.moxygen_conformance_driver == {"status":"unresolved","sha":"TBD","image_digest":"TBD"} and
  .provenance.executable_landings.rust_diagnostic_gates == {"status":"unresolved","sha":"TBD"}'

check "runner identifiers and moxygen source-binding identifiers are conflated" '
  (.identifier_policy.gate_ids | contains("immutable runner")) and
  (.identifier_policy.case_ids | contains("profile-local")) and
  (.identifier_policy.case_ids | contains("source bindings")) and
  (.identifier_policy.source_ordinals_and_names | contains("pinned moxygen script"))'

check "semantic gates and implementation bindings are not cleanly separated" '
  (.oracle.semantic_layer | contains("without prescribing an implementation")) and
  (.oracle.binding_rule | contains("not normative protocol behavior")) and
  all(.gates[];
    ((.semantic_contract | tostring | test("moxygen|moq-test-00|moqtest"; "i")) | not) and
    .bindings.moxygen_driver.classification == "moxygen-driver-binding" and
    .bindings.independent_moq_test_client.classification == "independent-generator-and-oracle")'

check "per-case timeout policy is incomplete or exceeds the runner container limit" '
  .execution_policy.runner_whole_container_limit_ms == 120000 and
  .execution_policy.readiness_timeout_ms == 10000 and
  (.execution_policy.diagnostic_gate_timeouts_ms | keys | sort) == ([.gates[].id] | sort) and
  all(.execution_policy.diagnostic_gate_timeouts_ms[]; . == 10000) and
  (.execution_policy.intended_case_timeouts_ms | keys | sort) == ([.cases[] | select(.disposition == "intended") | .id] | sort) and
  .execution_policy.intended_case_timeouts_ms["MOXYGEN-D18-CASE-044"] >= 30000 and
  .execution_policy.intended_case_timeouts_ms["MOXYGEN-D18-CASE-046"] >= 30000 and
  all(.execution_policy.intended_case_timeouts_ms[]; . < 120000) and
  all(.execution_policy.diagnostic_gate_timeouts_ms[]; . < 120000)'

check "executable TLS/provenance requirements or moxygen ordering-risk handling are incomplete" '
  (.executable_requirements.tls_disable_verify | contains("honor TLS_DISABLE_VERIFY")) and
  (.executable_requirements.tls_disable_verify | contains("always installs an insecure verifier")) and
  (.executable_requirements.resolved_provenance | contains("never accept TBD")) and
  .known_driver_risks.moxygen_global_cross_stream_ordering.status == "open-until-fixed-executable-sha" and
  .known_driver_risks.moxygen_global_cross_stream_ordering.resolved_by_sha == "TBD" and
  (.known_driver_risks.moxygen_global_cross_stream_ordering.result_rule | contains("driver-inconclusive")) and
  (.known_driver_risks.moxygen_global_cross_stream_ordering.result_rule | contains("never classify the relay as failed"))'

check "case totals must be exactly 58/29/29 with contiguous ordinals" '
  (.cases | length) == 58 and
  ([.cases[] | select(.disposition == "intended")] | length) == 29 and
  ([.cases[] | select(.disposition == "deferred")] | length) == 29 and
  [.cases[].ordinal] == [range(1; 59)]'

check "case IDs and source names must each be unique" '
  ([.cases[].id] | length) == ([.cases[].id] | unique | length) and
  ([.cases[].source_name] | length) == ([.cases[].source_name] | unique | length)'

check "case shape, dispositions, reasons, or independence classes are invalid" '
  .disposition_reasons as $reasons |
  all(.cases[];
    (.id | test("^MOXYGEN-D18-CASE-[0-9]{3}$")) and
    (.source_name | type == "string" and length > 0) and
    (.source_section | type == "string" and length > 0) and
    (.request == "subscribe" or .request == "fetch" or .request == "publish") and
    (.disposition == "intended" or .disposition == "deferred") and
    ($reasons[.reason] | type == "string" and length > 0) and
    (.independence == "planned-independent-gate" or
     .independence == "profile-inventory-only" or
     .independence == "deferred-unsupported") and
    (.gate_ids | type == "array"))'

check "deferred reason partition must be exactly 9/8/4/7/1" '
  ([.cases[] | select(.reason == "fetch-unsupported")] | length) == 9 and
  ([.cases[] | select(.reason == "subscribe-tracks-unsupported" or .reason == "subscribe-tracks-request-update-unsupported")] | length) == 8 and
  ([.cases[] | select(.reason == "subscribe-tracks-request-update-unsupported")] | length) == 2 and
  ([.cases[] | select(.reason == "datagram-unsupported")] | length) == 4 and
  ([.cases[] | select(.reason == "object-status-unsupported")] | length) == 7 and
  ([.cases[] | select(.reason == "publisher-delivery-timeout-unsupported")] | length) == 1 and
  all(.cases[] | select(.disposition == "deferred");
    (.reason == "fetch-unsupported" or
     .reason == "subscribe-tracks-unsupported" or
     .reason == "subscribe-tracks-request-update-unsupported" or
     .reason == "datagram-unsupported" or
     .reason == "object-status-unsupported" or
     .reason == "publisher-delivery-timeout-unsupported"))'

check "diagnostic gates must have seven unique immutable IDs, source bindings, and functions" '
  (.gates | length) == 7 and
  ([.gates[].id] | length) == ([.gates[].id] | unique | length) and
  ([.gates[].moxygen_source_binding_id] | length) == ([.gates[].moxygen_source_binding_id] | unique | length) and
  ([.gates[].bindings.moxygen_driver.source_name] | length) == ([.gates[].bindings.moxygen_driver.source_name] | unique | length) and
  ([.gates[].bindings.independent_moq_test_client.planned_function] | length) == ([.gates[].bindings.independent_moq_test_client.planned_function] | unique | length) and
  all(.gates[];
    .revision == 1 and
    (.id | test("^MOXYGEN-D18-DG-[0-9]{3}$")) and
    (.moxygen_source_binding_id | test("^MOXYGEN-D18-CASE-[0-9]{3}$")) and
    (.semantic_contract.topology_roles == ["publisher","relay-under-test","subscriber"]) and
    (.semantic_contract.scenario | type == "string" and length > 0) and
    (.semantic_contract.success_criteria | type == "array" and length > 0) and
    .bindings.moxygen_driver.classification == "moxygen-driver-binding" and
    .bindings.moxygen_driver.topology == "moxygen moqtest_server -> relay-under-test -> moxygen moqtest_client" and
    (.bindings.moxygen_driver.readiness | contains("REQUEST_OK")) and
    .bindings.independent_moq_test_client.classification == "independent-generator-and-oracle" and
    .bindings.independent_moq_test_client.topology == "independent publisher role -> relay-under-test -> independent subscriber role" and
    (.bindings.independent_moq_test_client.planned_function | test("^test_moqt18_subscribe_[a-z0-9_]+$")) and
    (.bindings.independent_moq_test_client.derivation | type == "string" and length > 0) and
    (.normative_references | type == "array" and length > 0) and
    (.bindings.moxygen_driver.vector.track_namespace | type == "array" and length == 16) and
    .bindings.moxygen_driver.vector.track_namespace[0] == "moq-test-00" and
    (.bindings.independent_moq_test_client.vector.namespace_prefix | test("^moq-test/moqt18/[a-z0-9-]+$")) and
    .bindings.independent_moq_test_client.vector.namespace_rule == (.bindings.independent_moq_test_client.vector.namespace_prefix + "/{publisher_cid}") and
    .bindings.independent_moq_test_client.vector.publisher_cid_component == {"source":"publisher_connection_id","purpose":"per-run namespace uniqueness and exact-track routing isolation"} and
    (.bindings.independent_moq_test_client.vector.payloads | del(.items)) == {"kind":"fixed-source-constants","unique_per_object":true,"verification":"exact-byte-match"} and
    (.bindings.independent_moq_test_client.vector.payloads.items | type == "array" and length > 0) and
    all(.bindings.independent_moq_test_client.vector.payloads.items[];
      (keys == ["ascii","group","hex","object","subgroup"]) and
      (.ascii | type == "string" and length > 0) and
      (.hex | test("^([0-9a-f]{2})+$"))) and
    (.bindings.independent_moq_test_client.vector as $vector |
      ([ $vector.groups[] as $group | $vector.subgroups | to_entries[] | . as $subgroup | $subgroup.value[] | {group:$group,subgroup:($subgroup.key|tonumber),object:.} ] | sort_by(.group,.subgroup,.object)) ==
      ([ $vector.payloads.items[] | {group,subgroup,object} ] | sort_by(.group,.subgroup,.object)) and
      ([ $vector.groups[] as $group | $vector.subgroups | keys[] | ($group|tostring) + "/" + . ] | unique | sort) == ($vector.publisher_priority_by_subgroup | keys | sort) and
      ([ $vector.payloads.items[].ascii ] | length) == ([ $vector.payloads.items[].ascii ] | unique | length) and
      ([ $vector.payloads.items[].hex ] | length) == ([ $vector.payloads.items[].hex ] | unique | length)) and
    (.evidence | type == "array" and length > 0))'

check "canonical gate identities, functions, vectors, or totals changed" '
  [.gates[].id] == [
    "MOXYGEN-D18-DG-001",
    "MOXYGEN-D18-DG-002",
    "MOXYGEN-D18-DG-003",
    "MOXYGEN-D18-DG-004",
    "MOXYGEN-D18-DG-005",
    "MOXYGEN-D18-DG-006",
    "MOXYGEN-D18-DG-007"
  ] and
  [.gates[].moxygen_source_binding_id] == [
    "MOXYGEN-D18-CASE-001",
    "MOXYGEN-D18-CASE-002",
    "MOXYGEN-D18-CASE-003",
    "MOXYGEN-D18-CASE-012",
    "MOXYGEN-D18-CASE-013",
    "MOXYGEN-D18-CASE-029",
    "MOXYGEN-D18-CASE-040"
  ] and
  [.gates[].bindings.moxygen_driver.source_ordinal] == [1,2,3,12,13,29,40] and
  [.gates[].bindings.independent_moq_test_client.planned_function] == [
    "test_moqt18_subscribe_group_basic",
    "test_moqt18_subscribe_object_basic",
    "test_moqt18_subscribe_two_group_basic",
    "test_moqt18_subscribe_start_group_five",
    "test_moqt18_subscribe_start_object_three",
    "test_moqt18_subscribe_group_object_increment_two",
    "test_moqt18_subscribe_higher_extension_types"
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
  [.gates[].bindings.independent_moq_test_client.vector.namespace_prefix] == [
    "moq-test/moqt18/subscribe-group-basic",
    "moq-test/moqt18/subscribe-object-basic",
    "moq-test/moqt18/subscribe-two-group-basic",
    "moq-test/moqt18/subscribe-start-group-five",
    "moq-test/moqt18/subscribe-start-object-three",
    "moq-test/moqt18/subscribe-group-object-increment-two",
    "moq-test/moqt18/subscribe-higher-extension-types"
  ] and
  [.gates[].bindings.independent_moq_test_client.vector.track_name] == ["group-basic","object-basic","two-group-basic","start-group-five","start-object-three","group-object-increment-two","higher-extension-types"] and
  [.gates[].bindings.independent_moq_test_client.vector.groups] == [[0,1],[0],[2],[5,6],[0],[0,2],[9]] and
  [.gates[].bindings.independent_moq_test_client.vector.object_ids] == [[0,1,2],[4,5,6],[0,1,2,3,4,5],[0,1],[3,4,5],[0,2,4],[4,7]] and
  [.gates[].bindings.independent_moq_test_client.vector.subgroups] == [
    {"0":[0,1,2]},
    {"40":[4],"41":[5],"42":[6]},
    {"10":[0,2,4],"11":[1,3,5]},
    {"0":[0,1]},
    {"7":[3,4,5]},
    {"0":[0,2,4]},
    {"7":[4,7]}
  ] and
  [.gates[].bindings.independent_moq_test_client.vector.publisher_priority_by_subgroup] == [
    {"0/0":17,"1/0":23},
    {"0/40":29,"0/41":31,"0/42":37},
    {"2/10":41,"2/11":43},
    {"5/0":47,"6/0":53},
    {"0/7":59},
    {"0/0":61,"2/0":67},
    {"9/7":59}
  ] and
  all(.gates[].bindings.independent_moq_test_client.vector.payloads; (del(.items)) == {"kind":"fixed-source-constants","unique_per_object":true,"verification":"exact-byte-match"}) and
  all(.gates[0:6][];
    (.bindings.independent_moq_test_client.vector | has("object_properties_by_object") | not) and
    (.bindings.independent_moq_test_client.vector | has("object_property_ranges") | not)) and
  .gates[6].bindings.independent_moq_test_client.vector.object_properties_by_object == {
    "4":[
      {"type":14336,"type_hex":"0x3800","value_kind":"integer","value":4660,"value_hex":"0x1234"},
      {"type":14337,"type_hex":"0x3801","value_kind":"bytes","value_ascii":"high-type-3801","value_hex":"686967682d747970652d33383031"}
    ],
    "7":[
      {"type":14338,"type_hex":"0x3802","value_kind":"integer","value":270544960,"value_hex":"0x10203040"},
      {"type":14339,"type_hex":"0x3803","value_kind":"bytes","value_ascii":"high-type-3803","value_hex":"686967682d747970652d33383033"}
    ]
  } and
  .gates[6].bindings.independent_moq_test_client.vector.object_property_ranges == {
    "application_specific":{"minimum":14336,"maximum":16383,"hex":"0x3800..0x3fff"},
    "forbidden_object_scope":{"minimum":16384,"maximum":32767,"hex":"0x4000..0x7fff"}
  }'

check "independent Object Properties enter the forbidden Object-scope range or use the wrong value form" '
  [.gates[] | (.bindings.independent_moq_test_client.vector.object_properties_by_object // {}) | .[] | .[]] |
  all(.[];
    (.type < 16384 or .type > 32767) and
    ((.value_kind == "integer" and (.type % 2) == 0 and (.value | type) == "number") or
     (.value_kind == "bytes" and (.type % 2) == 1 and (.value_ascii | type) == "string")))'

check "every gate must select an intended case with the same source name" '
  .cases as $cases |
  all(.gates[]; . as $gate |
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
  (.binding_evidence_contracts | keys) == ["independent_moq_test_client","moxygen_driver"] and
  (.binding_evidence_contracts.moxygen_driver.readiness | contains("same active case")) and
  (.binding_evidence_contracts.moxygen_driver.readiness | contains("announce-only run is not proof")) and
  .binding_evidence_contracts.independent_moq_test_client.not_directly_observed == ["publish-namespace-request-ok","raw-object-id-deltas","first-object-bit","wire-fin-or-reset"] and
  (.binding_evidence_contracts.independent_moq_test_client.completion | contains("TRACK_ENDED"))'

check "result record contract does not separate claims, evaluator verdict, evidence, and provenance" '
  .result_record_contract.version == "1.0.0" and
  .result_record_contract.schema_ref == "./moxygen-draft18-support-profile.schema.json#/definitions/result_record" and
  .result_record_contract.state_model.disposition == ["intended","deferred"] and
  .result_record_contract.state_model.execution == ["not-run","started","completed","aborted"] and
  .result_record_contract.state_model.evaluator_verdict == ["pass","fail","inconclusive","unsupported","harness-error"] and
  .result_record_contract.state_model.claimed_outcome == ["pass","fail","inconclusive","unsupported","not-run","harness-error"] and
  .result_record_contract.state_model.failure_classification == ["none","profile-mismatch","protocol-contradiction","mixed","driver-inconclusive"] and
  .result_record_contract.independence_classes == ["moxygen-driver-binding","independent-generator-and-oracle"] and
  (.result_record_contract.assertion_descriptor.required | sort) == (["id","description","basis","status","expected","observed","evidence_ids"] | sort) and
  .result_record_contract.assertion_descriptor.unique_by == "id" and
  (.result_record_contract.evidence_descriptor.required | sort) == (["id","category","kind","sha256","media_type","byte_length","producer","captured_at_utc","locator"] | sort) and
  .result_record_contract.evidence_descriptor.unique_by == "id" and
  (.result_record_contract.evidence_descriptor.digest | contains("external publication must recompute")) and
  (.result_record_contract.opaque_deployment_policy.rule | contains("image_digest=null")) and
  (.result_record_contract.opaque_deployment_policy.result_handling | contains("reproducibility=opaque")) and
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

check_digest "full 58-case inventory drifted" \
  "1fb5605fad0c8c7ce39f3316245d61b0688015b3d72afcf5dd64885aef36f449" \
  '.cases | map({id,ordinal,source_name,source_section,request,disposition,reason,independence,gate_ids})'

check_digest "complete moxygen gate bindings drifted" \
  "a93d449795e2fc18e9855bf3f6636017e553eb1ae02eddf93d32de7accb19a5d" \
  '.gates | map({id,revision,moxygen_source_binding_id,binding:.bindings.moxygen_driver})'

check_digest "complete independent gate bindings drifted" \
  "d15b1d0bf115ebee615f7fe556a13b1e7c164c178f7f30d9f17b482cd2bdccb6" \
  '.gates | map({id,revision,binding:.bindings.independent_moq_test_client})'

check_digest "revision-1 gate references or semantic contracts drifted" \
  "13f7a1a38fa3bf9bc2c2b3e7e276895e4ecd7e934e3abe607d0494937970e45f" \
  '.gates | map({id,revision,normative_references,semantic_contract})'

check_digest "provenance, timeout, TLS, or driver-risk policy drifted" \
  "4b5734e8178b0827ddc9e883ea047a060be62f0a929bc5def6958901fcb22462" \
  '{execution_policy,executable_requirements,known_driver_risks,provenance,binding_evidence_contracts,required_evidence}'

echo "Validated moxygen draft-18 profile: 58 cases (29 intended, 29 deferred), 7 gates"

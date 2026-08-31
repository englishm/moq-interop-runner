#!/bin/bash
# Validate data-plane vectors and their canonical specification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${DATA_PLANE_CONFIG_FILE:-$ROOT_DIR/implementations.json}"
SPEC_FILE="${DATA_PLANE_SPEC_FILE:-$ROOT_DIR/docs/tests/DATA-PLANE.md}"
VECTOR_FILE="${DATA_PLANE_VECTOR_FILE:-$ROOT_DIR/docs/tests/vectors/data-plane.json}"
SCHEMA_FILE="${DATA_PLANE_SCHEMA_FILE:-$ROOT_DIR/docs/tests/vectors/data-plane.schema.json}"
TARGET_VALIDATOR="${DATA_PLANE_TARGET_VALIDATOR:-$SCRIPT_DIR/validate-target-draft.sh}"
RETIRED_FILE="${DATA_PLANE_RETIRED_FILE:-$ROOT_DIR/docs/tests/retired-test-identifiers.json}"
PREVIOUS_VECTOR_FILE="${DATA_PLANE_PREVIOUS_VECTOR_FILE:-}"
DUPLICATE_CHECKER="$SCRIPT_DIR/check-json-duplicates.sh"
SHA256_HELPER="$SCRIPT_DIR/sha256-stdin.sh"
MARKDOWN_SANITIZER="$SCRIPT_DIR/sanitize-markdown.sh"
status=0

error() {
    echo "ERROR: $*" >&2
    status=1
}

schema_validate() {
    if command -v check-jsonschema >/dev/null 2>&1; then
        check-jsonschema --schemafile "$SCHEMA_FILE" "$VECTOR_FILE"
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
        python3 - "$SCHEMA_FILE" "$VECTOR_FILE" <<'PY'
import json
import sys
import jsonschema

with open(sys.argv[1], encoding="utf-8") as source:
    schema = json.load(source)
with open(sys.argv[2], encoding="utf-8") as source:
    instance = json.load(source)
jsonschema.validate(instance, schema)
PY
    elif command -v bun >/dev/null 2>&1 && bun -e 'require.resolve("ajv")' >/dev/null 2>&1; then
        DATA_PLANE_SCHEMA_PATH="$SCHEMA_FILE" DATA_PLANE_VECTOR_PATH="$VECTOR_FILE" bun -e '
const fs = require("fs");
const Ajv = require("ajv");
const schema = JSON.parse(fs.readFileSync(process.env.DATA_PLANE_SCHEMA_PATH, "utf8"));
const instance = JSON.parse(fs.readFileSync(process.env.DATA_PLANE_VECTOR_PATH, "utf8"));
const ajv = new Ajv({allErrors: true, strict: false});
if (!ajv.validate(schema, instance)) {
  console.error(ajv.errorsText(ajv.errors, {separator: "\n"}));
  process.exit(1);
}
'
    else
        echo "ERROR: need check-jsonschema, Python jsonschema, or Bun with Ajv" >&2
        return 1
    fi
}

check_jq() {
    local message="$1"
    local expression="$2"
    shift 2

    if ! jq -e "$expression" "$VECTOR_FILE" "$@" >/dev/null; then
        error "$message"
    fi
}

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
command -v grep >/dev/null 2>&1 || { echo "ERROR: grep is required" >&2; exit 1; }
command -v cut >/dev/null 2>&1 || { echo "ERROR: cut is required" >&2; exit 1; }
for required_file in "$CONFIG_FILE" "$SPEC_FILE" "$VECTOR_FILE" "$SCHEMA_FILE" "$RETIRED_FILE"; do
    [ -f "$required_file" ] || { echo "ERROR: required file not found: $required_file" >&2; exit 1; }
done
[ -x "$TARGET_VALIDATOR" ] || { echo "ERROR: target-draft validator not executable: $TARGET_VALIDATOR" >&2; exit 1; }
[ -x "$MARKDOWN_SANITIZER" ] || { echo "ERROR: Markdown sanitizer not executable: $MARKDOWN_SANITIZER" >&2; exit 1; }
[ -x "$DUPLICATE_CHECKER" ] || { echo "ERROR: duplicate-key checker not executable: $DUPLICATE_CHECKER" >&2; exit 1; }
[ -x "$SHA256_HELPER" ] || { echo "ERROR: SHA-256 helper not executable: $SHA256_HELPER" >&2; exit 1; }

if ! "$DUPLICATE_CHECKER" "$CONFIG_FILE" "$SCHEMA_FILE" "$VECTOR_FILE" "$RETIRED_FILE"; then
    echo "ERROR: JSON inputs must not contain duplicate object keys" >&2
    exit 1
fi
if [ -n "$PREVIOUS_VECTOR_FILE" ]; then
    [ -f "$PREVIOUS_VECTOR_FILE" ] || { echo "ERROR: previous vector file not found: $PREVIOUS_VECTOR_FILE" >&2; exit 1; }
    if ! "$DUPLICATE_CHECKER" "$PREVIOUS_VECTOR_FILE"; then
        echo "ERROR: previous vector must not contain duplicate object keys" >&2
        exit 1
    fi
    jq empty "$PREVIOUS_VECTOR_FILE" >/dev/null 2>&1 || { echo "ERROR: invalid JSON: $PREVIOUS_VECTOR_FILE" >&2; exit 1; }
fi

if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "ERROR: invalid JSON: $CONFIG_FILE" >&2
    exit 1
fi
if ! jq empty "$SCHEMA_FILE" >/dev/null 2>&1; then
    echo "ERROR: invalid JSON: $SCHEMA_FILE" >&2
    exit 1
fi
if ! jq empty "$VECTOR_FILE" >/dev/null 2>&1; then
    echo "ERROR: invalid JSON: $VECTOR_FILE" >&2
    exit 1
fi
if ! schema_validate; then
    error "$VECTOR_FILE does not validate against $SCHEMA_FILE"
fi

target="$(jq -r '.current_target' "$CONFIG_FILE")"
vector_target="$(jq -r '.target_draft' "$VECTOR_FILE")"
if [ "$vector_target" != "$target" ]; then
    error "target_draft must equal implementations.json.current_target ($target)"
else
    if ! TARGET_DRAFT_CONFIG_FILE="$CONFIG_FILE" "$TARGET_VALIDATOR" "$SPEC_FILE" >/dev/null; then
        error "DATA-PLANE.md does not satisfy target-draft policy"
    fi
fi

SPEC_IDS_FILE="$(mktemp "${TMPDIR:-/tmp}/data-plane-spec-ids.XXXXXX")"
VECTOR_IDS_FILE="$(mktemp "${TMPDIR:-/tmp}/data-plane-vector-ids.XXXXXX")"
CLEAN_SPEC_FILE="$(mktemp "${TMPDIR:-/tmp}/data-plane-clean-spec.XXXXXX")"
trap 'rm -f "$SPEC_IDS_FILE" "$VECTOR_IDS_FILE" "$CLEAN_SPEC_FILE"' EXIT

"$MARKDOWN_SANITIZER" "$SPEC_FILE" > "$CLEAN_SPEC_FILE"

while IFS= read -r line; do
    if [[ "$line" =~ ^\ {0,3}###[[:space:]]+\`([a-z][a-z0-9-]*)\`[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}" >> "$SPEC_IDS_FILE"
    fi
done < "$CLEAN_SPEC_FILE"
jq -r '.tests[].id' "$VECTOR_FILE" > "$VECTOR_IDS_FILE"

check_jq "the vector suite must contain exactly seven tests" '.tests | length == 7'
check_jq "data-plane semantic IDs must be unique" '[.tests[].id] | length == (unique | length)'
check_jq "semantic IDs must not contain version tokens" 'all(.tests[].id; (test("d[0-9]+|draft[-_]?[0-9]+|moqt[-_]?[0-9]+"; "i") | not))'
check_jq "retired semantic IDs must not remain in the data-plane suite" '
  [inputs.retired_identifiers[].id] as $retired |
  all(.tests[].id; . as $id | $retired | index($id) == null)' "$RETIRED_FILE"
if [ -n "$PREVIOUS_VECTOR_FILE" ]; then
    check_jq "changed vectors must increase their test and suite revisions" '
      . as $current |
      inputs as $previous |
      all($previous.tests[]; . as $old |
        ([$current.tests[] | select(.id == $old.id)] | first // null) as $new |
        $new == null or
        ($new.revision >= $old.revision and
         (if $new.vector_digest == $old.vector_digest then true
          else $new.revision > $old.revision end))) and
      ($current.suite_revision >= $previous.suite_revision) and
      (([$current.tests[] | [.id, .vector_digest]] | sort) ==
       ([$previous.tests[] | [.id, .vector_digest]] | sort) or
       $current.suite_revision > $previous.suite_revision)' "$PREVIOUS_VECTOR_FILE"
fi

spec_ids="$(jq -Rsc 'split("\n") | map(select(length > 0)) | sort' "$SPEC_IDS_FILE")"
vector_ids="$(jq -Rsc 'split("\n") | map(select(length > 0)) | sort' "$VECTOR_IDS_FILE")"
if [ "$(printf '%s' "$spec_ids" | jq 'length')" -ne 7 ] || [ "$spec_ids" != "$vector_ids" ]; then
    error "vector IDs must exactly match the seven canonical DATA-PLANE.md headings"
fi

check_jq "namespace and Run ID templates must match the data-plane contract" '
  .common.namespace_fields == ["moq-interop", "{test_id}"] and
  .common.track_name == "{run_id}" and
  .common.run_id_pattern == "^[0-9a-f]{32}$" and
  .common.run_id_generation == "cryptographically-secure-random-128-bit"'
actual_schema_digest="$("$SHA256_HELPER" < "$SCHEMA_FILE")"
if [ "$(jq -r '.schema_digest' "$VECTOR_FILE")" != "sha256:$actual_schema_digest" ]; then
    error "schema_digest does not match $SCHEMA_FILE"
fi
while IFS=$'\t' read -r vector_id expected_digest; do
    actual_digest="$(
        jq -S -c -j --arg id "$vector_id" \
            '{target_draft, normative_source, schema_digest, common, test: (.tests[] | select(.id == $id) | del(.vector_digest))}' \
            "$VECTOR_FILE" | "$SHA256_HELPER"
    )" || { echo "ERROR: could not calculate vector digest" >&2; exit 1; }
    if [ "$expected_digest" != "sha256:$actual_digest" ]; then
        error "vector_digest mismatch for $vector_id"
    fi
done < <(jq -r '.tests[] | [.id, .vector_digest] | @tsv' "$VECTOR_FILE")
check_jq "each test must have unique (group_id, object_id) coordinates" '
  all(.tests[];
    ([.objects[] | [.group_id, .object_id]] | length) ==
    ([.objects[] | [.group_id, .object_id]] | unique | length))'
check_jq "Object subgroup memberships must exactly match declared subgroup streams" '
  all(.tests[];
    ([.objects[] | [.group_id, .subgroup_id]] | unique | sort) ==
    ([.termination.subgroup_streams[] | [.group_id, .subgroup_id]] | sort) and
    ([.termination.subgroup_streams[] | [.group_id, .subgroup_id]] | length) ==
    ([.termination.subgroup_streams[] | [.group_id, .subgroup_id]] | unique | length))'
check_jq "Object IDs must increase within each subgroup and end at final_object_id" '
  all(.tests[];
    . as $test |
    all($test.termination.subgroup_streams[];
      . as $stream |
      [$test.objects[] |
        select(.group_id == $stream.group_id and .subgroup_id == $stream.subgroup_id) |
        .object_id] as $ids |
      ($ids | length) > 0 and
      ($ids == ($ids | sort | unique)) and
      $stream.final_object_id == $ids[-1]))'
check_jq "Object priorities, status, and forwarding preference must match common rules" '
  .common.object_rules as $rules |
  all(.tests[].objects[];
    .status == $rules.status and
    .forwarding_preference == $rules.forwarding_preference and
    .publisher_priority ==
      (if (.group_id % 2) == 0 then $rules.even_group_publisher_priority
       else $rules.odd_group_publisher_priority end))'
check_jq "Object payload length and bytes must match first-in-group rules" '
  .common.object_rules as $rules |
  all(.tests[];
    . as $test |
    all(range(0; $test.objects | length);
      . as $index |
      $test.objects[$index] as $object |
      ([ $test.objects[0:$index][] | select(.group_id == $object.group_id) ] | length) as $earlier |
      $object.payload_ascii == ($rules.payload_byte_ascii * $object.payload_length) and
      $object.payload_length ==
        (if $earlier == 0 then $rules.first_emitted_in_group_length
         else $rules.other_object_length end)))'
check_jq "fixture emission offsets must follow the declared cadence" '
  .common.object_rules.fixture_cadence_ms as $cadence |
  all(.tests[];
    . as $test |
    all(range(0; $test.objects | length);
      . as $index | $test.objects[$index].fixture_emit_at_ms == ($index * $cadence)))'
check_jq "semantic IDs must retain their stated subgroup and start-coordinate meaning" '
  def selected($id): first(.tests[] | select(.id == $id));
  def groups: [.objects[].group_id] | unique | sort;
  def subgroup_coordinates: [.objects[] | [.group_id, .subgroup_id]] | unique;
  def object_coordinates: [.objects[] | [.group_id, .object_id]] | unique;
  def gapped:
    . as $values |
    ($values | length) > 1 and
    all(range(1; $values | length); $values[.] > ($values[. - 1] + 1));
  (selected("subscribe-one-subgroup-per-group") |
    (groups | length) > 1 and
    all(.objects | group_by(.group_id)[]; ([.[].subgroup_id] | unique | length) == 1)) and
  (selected("subscribe-one-subgroup-per-object") |
    (object_coordinates | length) > 1 and
    (subgroup_coordinates | length) == (object_coordinates | length)) and
  (selected("subscribe-two-subgroups-per-group") |
    (.objects | length) > 2 and
    all(.objects | group_by(.group_id)[]; ([.[].subgroup_id] | unique | length) == 2)) and
  (selected("subscribe-nonzero-start-group") | ([.objects[].group_id] | min) > 0) and
  (selected("subscribe-nonzero-start-object") | ([.objects[].object_id] | min) > 0) and
  (selected("subscribe-sparse-group-object-ids") |
    (groups | gapped) and
    all(.objects | group_by(.group_id)[]; ([.[].object_id] | unique | sort | gapped))) and
  (selected("subscribe-object-properties") | all(.objects[]; (.properties | length) > 0)) and
  all(.tests[] | select(.id != "subscribe-object-properties"); all(.objects[]; .properties == []))'
check_jq "Object Property types must be unique, ascending, and application-defined" '
  all(.tests[].objects[];
    [.properties[].type] as $types |
    $types == ($types | sort | unique) and
    all(.properties[];
      (.type >= 56 and .type <= 63) or
      (.type >= 14336 and .type <= 16383)))'
check_jq "Object Property type parity must match its value form" '
  all(.tests[].objects[].properties[];
    if (.type % 2) == 0 then .value_kind == "integer" and has("integer_value")
    else .value_kind == "bytes" and has("bytes_ascii") end)'
check_jq "PUBLISH_DONE Stream Count must equal the exact subgroup-stream count" '
  all(.tests[];
    .termination.publish_done.stream_count == (.termination.subgroup_streams | length))'
check_jq "subgroup and request-stream termination must be exact" '
  all(.tests[];
    .termination.publish_done.status == "TRACK_ENDED" and
    .termination.publish_done.publisher_reason == "" and
    .termination.request_stream_terminal == "FIN" and
    all(.termination.subgroup_streams[];
      .first_object == true and .end_of_group == false and .terminal == "FIN"))'

if [ "$status" -eq 0 ]; then
    echo "Data-plane vector/spec integrity valid: $target (7 semantic IDs)"
fi

exit "$status"

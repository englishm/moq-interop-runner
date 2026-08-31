#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-data-plane-vectors.sh"
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-data-plane-vectors.XXXXXX")"
CONFIG_FILE="$FIXTURE_DIR/implementations.json"
SPEC_FILE="$FIXTURE_DIR/DATA-PLANE.md"
VECTOR_FILE="$FIXTURE_DIR/data-plane.json"
SCHEMA_FILE="$FIXTURE_DIR/data-plane.schema.json"
RETIRED_FILE="$FIXTURE_DIR/retired-test-identifiers.json"
PREVIOUS_VECTOR_FILE="$FIXTURE_DIR/previous-data-plane.json"
TESTS=0

trap 'rm -rf "$FIXTURE_DIR"' EXIT

reset_fixtures() {
    cp "$ROOT_DIR/implementations.json" "$CONFIG_FILE"
    cp "$ROOT_DIR/docs/tests/DATA-PLANE.md" "$SPEC_FILE"
    cp "$ROOT_DIR/docs/tests/vectors/data-plane.json" "$VECTOR_FILE"
    cp "$ROOT_DIR/docs/tests/vectors/data-plane.json" "$PREVIOUS_VECTOR_FILE"
    cp "$ROOT_DIR/docs/tests/vectors/data-plane.schema.json" "$SCHEMA_FILE"
    cp "$ROOT_DIR/docs/tests/retired-test-identifiers.json" "$RETIRED_FILE"
}

recompute_vector_digest() {
    local test_id="$1"
    local digest

    digest="$(
        jq -S -c -j --arg id "$test_id" \
            '{target_draft, normative_source, schema_digest, common, test: (.tests[] | select(.id == $id) | del(.vector_digest))}' \
            "$VECTOR_FILE" | "$ROOT_DIR/scripts/sha256-stdin.sh"
    )"
    jq --arg id "$test_id" --arg digest "sha256:$digest" \
        '(.tests[] | select(.id == $id)).vector_digest = $digest' \
        "$VECTOR_FILE" > "$FIXTURE_DIR/rewritten.json"
    mv "$FIXTURE_DIR/rewritten.json" "$VECTOR_FILE"
}

replace_text_once() {
    local file="$1"
    local old="$2"
    local new="$3"
    local line
    local replaced=false

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$replaced" = false ] && [[ "$line" == *"$old"* ]]; then
            line="${line/"$old"/"$new"}"
            replaced=true
        fi
        printf '%s\n' "$line"
    done < "$file" > "$FIXTURE_DIR/rewritten-text"
    mv "$FIXTURE_DIR/rewritten-text" "$file"
    [ "$replaced" = true ] || { echo "test fixture text not found: $old" >&2; exit 1; }
}

rewrite_json() {
    local file="$1"
    local expression="$2"

    jq "$expression" "$file" > "$FIXTURE_DIR/rewritten.json"
    mv "$FIXTURE_DIR/rewritten.json" "$file"
}

replace_spec_heading() {
    local old="$1"
    local new="$2"
    local line

    while IFS= read -r line || [ -n "$line" ]; do
        [ "$line" != "### \`$old\`" ] || line="### \`$new\`"
        printf '%s\n' "$line"
    done < "$SPEC_FILE" > "$FIXTURE_DIR/rewritten-spec.md"
    mv "$FIXTURE_DIR/rewritten-spec.md" "$SPEC_FILE"
}

run_validator() {
    DATA_PLANE_CONFIG_FILE="$CONFIG_FILE" \
    DATA_PLANE_SPEC_FILE="$SPEC_FILE" \
    DATA_PLANE_VECTOR_FILE="$VECTOR_FILE" \
    DATA_PLANE_SCHEMA_FILE="$SCHEMA_FILE" \
    DATA_PLANE_RETIRED_FILE="$RETIRED_FILE" \
    DATA_PLANE_PREVIOUS_VECTOR_FILE="$PREVIOUS_VECTOR_FILE" \
        "$VALIDATOR"
}

expect_pass() {
    local name="$1"
    TESTS=$((TESTS + 1))
    if ! run_validator >/dev/null; then
        echo "not ok $TESTS - $name" >&2
        exit 1
    fi
    echo "ok $TESTS - $name"
}

expect_fail() {
    local name="$1"
    local expected="$2"
    local output
    TESTS=$((TESTS + 1))
    if output="$(run_validator 2>&1)"; then
        echo "not ok $TESTS - $name (unexpected pass)" >&2
        exit 1
    fi
    if ! printf '%s\n' "$output" | grep -Fq "$expected"; then
        echo "not ok $TESTS - $name (missing error: $expected)" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
    echo "ok $TESTS - $name"
}

reset_fixtures
expect_pass "canonical vectors"

reset_fixtures
rewrite_json "$CONFIG_FILE" '.current_target = "draft-17"'
expect_fail "target mismatch" "target_draft must equal implementations.json.current_target"

reset_fixtures
replace_spec_heading "subscribe-nonzero-start-group" "subscribe-other-start-group"
expect_fail "ID mismatch" "vector IDs must exactly match"

reset_fixtures
replace_text_once "$SPEC_FILE" "## Test Cases" $'## Test Cases\n\n```text'
expect_fail "fenced test headings" "vector IDs must exactly match"

reset_fixtures
printf '%s\n' '> ### `subscribe-visible-unvectorized`' >> "$SPEC_FILE"
expect_fail "nested visible test heading" "vector IDs must exactly match"

reset_fixtures
replace_text_once "$SPEC_FILE" '### `subscribe-one-subgroup-per-group`' '  ### `subscribe-one-subgroup-per-group`'
expect_pass "indented visible test heading"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[1].id = .tests[0].id'
expect_fail "duplicate ID" "semantic IDs must be unique"

reset_fixtures
replace_text_once "$VECTOR_FILE" '"group_id": 0,' '"group_id": 999, "group_id": 0,'
expect_fail "duplicate JSON key" "duplicate object key"

reset_fixtures
rewrite_json "$RETIRED_FILE" '.retired_identifiers += [{
  "id": "subscribe-one-subgroup-per-group",
  "last_known_target": "draft-18",
  "last_known_spec_revision": "data-plane-vector-1",
  "reason": "synthetic mutation",
  "replacement": null
}]'
expect_fail "retired active data-plane ID" "retired semantic IDs must not remain"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[0].objects[1].object_id = .tests[0].objects[0].object_id'
expect_fail "duplicate Object coordinate" "unique (group_id, object_id)"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[0].objects[0].subgroup_id = 99'
expect_fail "wrong subgroup membership" "subgroup memberships must exactly match"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[0].objects[0].payload_length = 8'
expect_fail "bad payload length" "payload length and bytes"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[6].objects[0].properties[0].integer_value = 4661'
expect_fail "stale vector digest" "vector_digest mismatch for subscribe-object-properties"

reset_fixtures
rewrite_json "$SCHEMA_FILE" '.title = "mutated schema title"'
expect_fail "stale schema digest" "schema_digest does not match"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[6].objects[0].properties[0].integer_value = 4661'
recompute_vector_digest "subscribe-object-properties"
expect_fail "changed vector without revision increase" "changed vectors must increase their test and suite revisions"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.common.track_name = "test"'
expect_fail "fixed Track Name" "namespace and Run ID templates"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.common.run_id_generation = "timestamp"'
expect_fail "predictable Run ID generation" "namespace and Run ID templates"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[6].objects[0].properties[0].type = 54'
expect_fail "Property outside application range" "application-defined"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[6].objects[0].properties[0].type = 14337'
expect_fail "Property type/value parity" "type parity"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[0].termination.publish_done.stream_count = 3'
expect_fail "wrong Stream Count" "exact subgroup-stream count"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[0].termination.subgroup_streams[0].final_object_id = 1'
expect_fail "wrong subgroup termination" "end at final_object_id"

reset_fixtures
rewrite_json "$VECTOR_FILE" '.tests[0].unexpected = true'
expect_fail "unexpected vector field" "does not validate against"

reset_fixtures
rewrite_json "$VECTOR_FILE" '
  .tests[1].objects |= map(.subgroup_id = 0) |
  .tests[1].termination.subgroup_streams = [{
    "group_id": 0,
    "subgroup_id": 0,
    "first_object": true,
    "end_of_group": false,
    "final_object_id": 2,
    "terminal": "FIN"
  }] |
  .tests[1].termination.publish_done.stream_count = 1'
expect_fail "semantic ID topology drift" "stated subgroup and start-coordinate meaning"

reset_fixtures
TESTS=$((TESTS + 1))
output="$(run_validator)"
if [ "$output" != "Data-plane vector/spec integrity valid: draft-18 (7 semantic IDs)" ]; then
    echo "not ok $TESTS - concise success output" >&2
    printf '%s\n' "$output" >&2
    exit 1
fi
echo "ok $TESTS - concise success output"

echo "1..$TESTS"

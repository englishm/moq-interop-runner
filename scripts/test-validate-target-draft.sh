#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-target-draft.sh"
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-target-draft.XXXXXX")"
CONFIG_FILE="$FIXTURE_DIR/implementations.json"
PRIMARY_SPEC="$FIXTURE_DIR/TEST-CASES.md"
OPTIONAL_SPEC="$FIXTURE_DIR/PROFILE-TESTS.md"
RETIRED_FILE="$FIXTURE_DIR/retired-test-identifiers.json"
PREVIOUS_RETIRED_FILE="$FIXTURE_DIR/previous-retired-test-identifiers.json"
TESTS=0

trap 'rm -rf "$FIXTURE_DIR"' EXIT

write_config() {
    printf '%s\n' \
        '{' \
        '  "current_target": "draft-18"' \
        '}' > "$CONFIG_FILE"
}

write_valid_spec() {
    printf '%s\n' \
        '# Canonical Tests' \
        '' \
        '**Target Draft**: `draft-18`' \
        '**Identifier Semantics Reviewed For**: `draft-18`' \
        '' \
        '## MoQT-18 Normative Target Text' \
        '' \
        'See [draft-ietf-moq-transport-18](https://www.ietf.org/archive/id/draft-ietf-moq-transport-18.html).' \
        '' \
        '### `publish-without-subscriber`' \
        '' \
        '### publish-to-pending-subscription' \
        '' \
        '| Identifier | Description |' \
        '|------------|-------------|' \
        '| stable-table-test | Active test |' \
        '| `backticked-table-test` | Active test |' \
        '' \
        'The driver exposes `test_semantic_api ()`.' \
        'fn test_semantic_rust_api   () {}' \
        '' \
        '```rust' \
        '#[test]' \
        'fn test_DRAFT_99_ignored () {}' \
        '```' > "$PRIMARY_SPEC"
}

write_valid_registry() {
    cp "$ROOT_DIR/docs/tests/retired-test-identifiers.json" "$RETIRED_FILE"
}

reset_fixtures() {
    write_config
    write_valid_spec
    write_valid_registry
    rm -f "$OPTIONAL_SPEC" "$PREVIOUS_RETIRED_FILE"
}

rewrite_registry() {
    local filter="$1"

    jq "$filter" "$RETIRED_FILE" > "$FIXTURE_DIR/rewritten-registry.json"
    mv "$FIXTURE_DIR/rewritten-registry.json" "$RETIRED_FILE"
}

append_retirement() {
    local registry="$1"
    local retired_id="$2"
    local replacement="$3"

    jq \
        --arg id "$retired_id" \
        --arg replacement "$replacement" \
        '.retired_identifiers += [{
            id: $id,
            last_known_target: "draft-18",
            last_known_profile_revision: "legacy-unversioned",
            last_known_implementation: {
                repository: "https://github.com/cloudflare/moq-rs",
                commit: "b01d3f6707e3a74f69905722b451a08cbb3364f3",
                image_digest: "unknown"
            },
            reason: "Legacy behavior differs.",
            replacement: $replacement
        }]' \
        "$registry" > "$FIXTURE_DIR/appended-registry.json"
    mv "$FIXTURE_DIR/appended-registry.json" "$registry"
}

append_identifier_table_row() {
    local first_cell="$1"

    printf '%s\n' \
        '' \
        '| Identifier | Description |' \
        '|------------|-------------|' \
        "| $first_cell | Active test |" >> "$PRIMARY_SPEC"
}

run_validator() {
    TARGET_DRAFT_CONFIG_FILE="$CONFIG_FILE" \
    TARGET_DRAFT_PRIMARY_SPEC="$PRIMARY_SPEC" \
    TARGET_DRAFT_RETIRED_FILE="$RETIRED_FILE" \
        "$VALIDATOR" "$@"
}

expect_pass() {
    local name="$1"
    shift
    TESTS=$((TESTS + 1))
    if ! "$@" >/dev/null; then
        echo "not ok $TESTS - $name" >&2
        exit 1
    fi
    echo "ok $TESTS - $name"
}

expect_fail() {
    local name="$1"
    local expected="$2"
    local output
    shift 2
    TESTS=$((TESTS + 1))
    if output="$("$@" 2>&1)"; then
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
expect_pass "valid exact declarations, plain/backticked IDs, and external test functions" run_validator

reset_fixtures
printf '%s\n' 'Ordinary prose about the Target Draft does not declare it again.' >> "$PRIMARY_SPEC"
expect_pass "ordinary Target Draft prose is not a declaration" run_validator

reset_fixtures
printf '%s\n' \
    '<!--' \
    '**Target Draft**: `draft-17`' \
    '**Identifier Semantics Reviewed For**: `draft-17`' \
    '### `hidden-DRAFT_17-test`' \
    '-->' >> "$PRIMARY_SPEC"
expect_pass "HTML-commented declarations and IDs are ignored" run_validator

reset_fixtures
printf '%s\n' \
    '# Canonical Tests' \
    '<!-- **Target Draft**: `draft-18` -->' \
    '<!-- **Identifier Semantics Reviewed For**: `draft-18` -->' \
    '### `publish-without-subscriber`' \
    '### publish-to-pending-subscription' > "$PRIMARY_SPEC"
expect_fail "HTML-commented declarations do not count" "exactly one Target Draft declaration; found 0" run_validator

reset_fixtures
printf '%s\n' \
    '```markdown' \
    '**Target Draft**: `draft-17`' \
    '**Identifier Semantics Reviewed For**: `draft-17`' \
    '### publish-without-subscriber' \
    'fn test_moqt_17_ignored () {}' \
    '```' >> "$PRIMARY_SPEC"
expect_pass "fenced declarations, IDs, and functions are ignored" run_validator

reset_fixtures
printf '%s\n' \
    '```text' \
    '<!-- literal unclosed comment inside example' \
    '```' \
    '### case-d18-after-fence' >> "$PRIMARY_SPEC"
expect_fail "HTML comment syntax inside a fence cannot hide following IDs" "version-specific public heading ID" run_validator

reset_fixtures
printf '%s\n' \
    '# Canonical Tests' \
    '```markdown' \
    '**Target Draft**: `draft-18`' \
    '**Identifier Semantics Reviewed For**: `draft-18`' \
    '```' \
    '### publish-without-subscriber' \
    '### publish-to-pending-subscription' > "$PRIMARY_SPEC"
expect_fail "fenced declarations do not count" "exactly one Target Draft declaration; found 0" run_validator

reset_fixtures
printf '%s\n' 'Target Draft: draft-17' >> "$PRIMARY_SPEC"
expect_fail "plain malformed duplicate target label" "exactly one Target Draft declaration; found 2" run_validator

reset_fixtures
printf '%s\n' '**Identifier Semantics Reviewed For** draft-17' >> "$PRIMARY_SPEC"
expect_fail "malformed duplicate semantics label" "exactly one Identifier Semantics Reviewed For declaration; found 2" run_validator

reset_fixtures
printf '%s\n' \
    '# Optional Profile' \
    '**Target Draft**: `draft-18`' \
    '**Identifier Semantics Reviewed For**: `draft-17`' > "$OPTIONAL_SPEC"
expect_fail "stale optional semantics declaration" "malformed or stale Identifier Semantics Reviewed For declaration" run_validator "$OPTIONAL_SPEC"

reset_fixtures
printf '%s\n' '### `decorated-test` extra' >> "$PRIMARY_SPEC"
expect_fail "decorated backticked heading attempt" "malformed canonical test heading" run_validator

reset_fixtures
printf '%s\n' '### decorated-test (extra)' >> "$PRIMARY_SPEC"
expect_fail "decorated plain heading attempt" "malformed canonical test heading" run_validator

reset_fixtures
append_identifier_table_row '`decorated-table-test` extra'
expect_fail "decorated first-column table attempt" "malformed canonical first-column table ID" run_validator

reset_fixtures
printf '%s\n' '### `case-d18-middle`' >> "$PRIMARY_SPEC"
expect_fail "dNN token anywhere" "version-specific public heading ID" run_validator

reset_fixtures
printf '%s\n' '### case-draft-18-middle' >> "$PRIMARY_SPEC"
expect_fail "draft-NN token anywhere" "version-specific public heading ID" run_validator

reset_fixtures
append_identifier_table_row 'case-DRAFT_18-middle'
expect_fail "case-insensitive draft_NN token anywhere" "version-specific public first-column table ID" run_validator

reset_fixtures
append_identifier_table_row '`case-moqt18-middle`'
expect_fail "moqtNN token anywhere" "version-specific public first-column table ID" run_validator

reset_fixtures
printf '%s\n' 'The API is `test_case_MoQt-18_middle (`.' >> "$PRIMARY_SPEC"
expect_fail "case-insensitive moqt-NN function token" "version-specific public function 'test_case_MoQt-18_middle'" run_validator

reset_fixtures
printf '%s\n' 'fn test_case_moqt_18_middle   () {}' >> "$PRIMARY_SPEC"
expect_fail "moqt_NN Rust function with whitespace" "version-specific public function 'test_case_moqt_18_middle'" run_validator

reset_fixtures
printf '%s\n' 'Protocol References: MoQT-17 and draft-ietf-moq-transport-17' >> "$PRIMARY_SPEC"
expect_fail "mismatched formal reference" "uses 'MoQT-17'; target is draft-18" run_validator

reset_fixtures
printf '%s\n' '### duplicate-active-id' '### `duplicate-active-id`' >> "$PRIMARY_SPEC"
expect_fail "duplicate active heading ID" "duplicate active canonical ID 'duplicate-active-id'" run_validator

reset_fixtures
printf '%s\n' '### duplicate-cross-surface' >> "$PRIMARY_SPEC"
append_identifier_table_row 'duplicate-cross-surface'
expect_fail "duplicate active ID across heading and table" "duplicate active canonical ID 'duplicate-cross-surface'" run_validator

reset_fixtures
printf '%s\n' '### publish-track-only' >> "$PRIMARY_SPEC"
expect_fail "retired ID reused as active" "retired ID 'publish-track-only' is reused as an active canonical ID" run_validator

reset_fixtures
printf '%s\n' \
    '# Canonical Tests' \
    '**Target Draft**: `draft-18`' \
    '**Identifier Semantics Reviewed For**: `draft-18`' \
    '### publish-to-pending-subscription' \
    '```markdown' \
    '### publish-without-subscriber' \
    '```' > "$PRIMARY_SPEC"
expect_fail "fenced replacement heading is not active" "replacement 'publish-without-subscriber'" run_validator

reset_fixtures
rewrite_registry '(.retired_identifiers[] | select(.id == "publish-track-only")).replacement = "publish-track-only"'
expect_fail "replacement differs from retired ID" "retired ID 'publish-track-only' must have a different replacement" run_validator

reset_fixtures
rewrite_registry '(.retired_identifiers[] | select(.id == "publish-track-only")).replacement = "missing-replacement"'
expect_fail "replacement exists as active heading" "replacement 'missing-replacement' for retired ID 'publish-track-only' is not an active canonical heading ID" run_validator

reset_fixtures
rewrite_registry '.retired_identifiers += [.retired_identifiers[0]]'
expect_fail "retired IDs are unique" "contains duplicate retired ID 'publish-track-only'" run_validator

reset_fixtures
rewrite_registry '.retired_identifiers |= map(select(.id != "publish-track-only"))'
printf '%s\n' '### publish-track-only' >> "$PRIMARY_SPEC"
expect_fail "deleted pinned tombstone cannot enable ID reuse" "pinned retired ID 'publish-track-only' is reused as an active canonical ID" run_validator

reset_fixtures
rewrite_registry '(.retired_identifiers[0].reason) = "Changed reason"'
expect_fail "initial tombstone reason is pinned" "does not match the pinned initial tombstones" run_validator

reset_fixtures
rewrite_registry '(.retired_identifiers[0].last_known_implementation.commit) = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
expect_fail "initial tombstone provenance is pinned" "does not match the pinned initial tombstones" run_validator

reset_fixtures
cp "$RETIRED_FILE" "$PREVIOUS_RETIRED_FILE"
append_retirement "$PREVIOUS_RETIRED_FILE" "legacy-extra" "replacement-extra"
expect_fail "previous-history tombstone deletion" "previous tombstone array is not an exact prefix" run_validator --previous-retired "$PREVIOUS_RETIRED_FILE"

reset_fixtures
cp "$RETIRED_FILE" "$PREVIOUS_RETIRED_FILE"
append_retirement "$PREVIOUS_RETIRED_FILE" "legacy-extra-a" "replacement-extra-a"
append_retirement "$PREVIOUS_RETIRED_FILE" "legacy-extra-b" "replacement-extra-b"
append_retirement "$RETIRED_FILE" "legacy-extra-b" "replacement-extra-b"
append_retirement "$RETIRED_FILE" "legacy-extra-a" "replacement-extra-a"
printf '%s\n' '### replacement-extra-a' '### replacement-extra-b' >> "$PRIMARY_SPEC"
expect_fail "previous-history set subset reordered" "previous tombstone array is not an exact prefix" run_validator --previous-retired "$PREVIOUS_RETIRED_FILE"

reset_fixtures
cp "$RETIRED_FILE" "$PREVIOUS_RETIRED_FILE"
append_retirement "$RETIRED_FILE" "legacy-extra" "replacement-extra"
printf '%s\n' '### replacement-extra' >> "$PRIMARY_SPEC"
expect_pass "append-only retirement addition" run_validator --previous-retired "$PREVIOUS_RETIRED_FILE"

reset_fixtures
rewrite_registry '.initial_tombstone_pin = "changed"'
expect_fail "initial tombstone pin is stable" "does not match the pinned initial tombstones" run_validator

echo "1..$TESTS"

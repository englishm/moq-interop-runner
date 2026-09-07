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
PREVIOUS_SPEC_FILE="$FIXTURE_DIR/previous-test-cases.md"
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
        '```markdown' \
        '### fenced-DRAFT_99-ignored' \
        '```' > "$PRIMARY_SPEC"
}

write_valid_registry() {
    cp "$ROOT_DIR/docs/tests/retired-test-identifiers.json" "$RETIRED_FILE"
}

reset_fixtures() {
    write_config
    write_valid_spec
    write_valid_registry
    rm -f "$OPTIONAL_SPEC" "$PREVIOUS_RETIRED_FILE" "$PREVIOUS_SPEC_FILE"
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
            last_known_profile_revision: "synthetic-profile-v1",
            reason: "Synthetic canonical behavior changed.",
            replacement: (if $replacement == "__NULL__" then null else $replacement end)
        }]' \
        "$registry" > "$FIXTURE_DIR/appended-registry.json"
    mv "$FIXTURE_DIR/appended-registry.json" "$registry"
}

append_identifier_table_row() {
    local first_cell="$1"
    local destination="${2:-$PRIMARY_SPEC}"

    printf '%s\n' \
        '' \
        '| Identifier | Description |' \
        '|------------|-------------|' \
        "| $first_cell | Active test |" >> "$destination"
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
expect_pass "valid exact declarations and plain/backticked heading IDs" run_validator

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
    '```' >> "$PRIMARY_SPEC"
expect_pass "fenced declarations and IDs are ignored" run_validator

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
printf '%s\n' ' ### indent-one' '  ### indent-two' '   ### indent-three' >> "$PRIMARY_SPEC"
expect_pass "Markdown headings accept one to three leading spaces" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-indented-id" "four-space-heading"
printf '%s\n' '    ### four-space-heading' >> "$PRIMARY_SPEC"
expect_fail "four-space heading is not an active definition" "does not terminate at an active canonical ID" run_validator

reset_fixtures
append_identifier_table_row '`decorated-table-test` extra'
expect_pass "decorated table proposal is not an active definition" run_validator

reset_fixtures
printf '%s\n' '### `case-d18-middle`' >> "$PRIMARY_SPEC"
expect_fail "dNN token anywhere" "version-specific public heading ID" run_validator

reset_fixtures
printf '%s\n' '### case-draft-18-middle' >> "$PRIMARY_SPEC"
expect_fail "draft-NN token anywhere" "version-specific public heading ID" run_validator

reset_fixtures
append_identifier_table_row 'case-DRAFT_18-middle'
expect_fail "case-insensitive draft_NN table hygiene" "version-specific public test-ID table entry" run_validator

reset_fixtures
append_identifier_table_row '`case-moqt18-middle`'
expect_fail "moqtNN table hygiene" "version-specific public test-ID table entry" run_validator

reset_fixtures
append_identifier_table_row 'case-MOQT-18-middle'
expect_fail "case-insensitive moqt-NN table hygiene" "version-specific public test-ID table entry" run_validator

reset_fixtures
append_identifier_table_row 'case-moqt_18-middle'
expect_fail "moqt_NN table hygiene" "version-specific public test-ID table entry" run_validator

reset_fixtures
printf '%s\n' 'Protocol References: MoQT-17 and draft-ietf-moq-transport-17' >> "$PRIMARY_SPEC"
expect_fail "mismatched formal reference" "uses 'MoQT-17'; target is draft-18" run_validator

reset_fixtures
printf '%s\n' '### duplicate-active-id' '### `duplicate-active-id`' >> "$PRIMARY_SPEC"
expect_fail "duplicate active heading ID" "duplicate active canonical ID 'duplicate-active-id'" run_validator

reset_fixtures
printf '%s\n' '### duplicate-cross-surface' >> "$PRIMARY_SPEC"
append_identifier_table_row 'duplicate-cross-surface'
expect_pass "table proposal does not duplicate active heading" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-synthetic-id" "publish-without-subscriber"
printf '%s\n' '### retired-synthetic-id' >> "$PRIMARY_SPEC"
expect_fail "retired ID reused as active" "retired ID 'retired-synthetic-id' is reused as an active canonical ID" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-synthetic-id" "fenced-replacement-id"
printf '%s\n' \
    '# Canonical Tests' \
    '**Target Draft**: `draft-18`' \
    '**Identifier Semantics Reviewed For**: `draft-18`' \
    '### publish-without-subscriber' \
    '### publish-to-pending-subscription' \
    '```markdown' \
    '### fenced-replacement-id' \
    '```' > "$PRIMARY_SPEC"
expect_fail "fenced replacement heading is not active" "does not terminate at an active canonical ID" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-synthetic-id" "retired-synthetic-id"
expect_fail "self replacement is a cycle" "contains a cycle at 'retired-synthetic-id'" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-synthetic-id" "missing-replacement"
expect_fail "replacement chain must reach active heading" "does not terminate at an active canonical ID" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-null-id" "__NULL__"
expect_pass "explicit null replacement is allowed" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-chain-a" "retired-chain-b"
append_retirement "$RETIRED_FILE" "retired-chain-b" "chain-active-id"
printf '%s\n' '### chain-active-id' >> "$PRIMARY_SPEC"
expect_pass "retirement chain terminates at active heading" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-cycle-a" "retired-cycle-b"
append_retirement "$RETIRED_FILE" "retired-cycle-b" "retired-cycle-a"
expect_fail "retirement chain cycle is rejected" "contains a cycle" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-chain-a" "retired-chain-b"
append_retirement "$RETIRED_FILE" "retired-chain-b" "__NULL__"
expect_fail "non-null chain cannot terminate at null retirement" "terminates at retired ID 'retired-chain-b' with no replacement" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-table-id" "table-only-replacement"
append_identifier_table_row 'table-only-replacement'
expect_fail "table proposal cannot satisfy retirement replacement" "does not terminate at an active canonical ID" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-profile-id" "profile-only-replacement"
printf '%s\n' \
    '# Optional Profile' \
    '**Target Draft**: `draft-18`' \
    '**Identifier Semantics Reviewed For**: `draft-18`' \
    '### profile-only-replacement' > "$OPTIONAL_SPEC"
expect_fail "additional profile cannot satisfy primary retirement" "does not terminate at an active canonical ID" run_validator "$OPTIONAL_SPEC"

reset_fixtures
rewrite_registry '.unexpected = true'
expect_fail "registry rejects extra top-level keys" "invalid registry format or retirement record" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-extra-field" "publish-without-subscriber"
rewrite_registry '.retired_identifiers[0].unexpected = true'
expect_fail "registry rejects extra retirement keys" "invalid registry format or retirement record" run_validator

reset_fixtures
append_retirement "$RETIRED_FILE" "retired-synthetic-id" "publish-without-subscriber"
append_retirement "$RETIRED_FILE" "retired-synthetic-id" "publish-without-subscriber"
expect_fail "retired IDs are unique" "contains duplicate retired ID 'retired-synthetic-id'" run_validator

reset_fixtures
cp "$RETIRED_FILE" "$PREVIOUS_RETIRED_FILE"
append_retirement "$PREVIOUS_RETIRED_FILE" "retired-synthetic-id" "publish-without-subscriber"
printf '%s\n' '### retired-synthetic-id' >> "$PRIMARY_SPEC"
expect_fail "deleted tombstone cannot enable ID reuse" "previous tombstone array is not an exact prefix" run_validator --previous-retired "$PREVIOUS_RETIRED_FILE"

reset_fixtures
cp "$PRIMARY_SPEC" "$PREVIOUS_SPEC_FILE"
expect_pass "unchanged previous canonical IDs remain active" run_validator --previous-spec "$PREVIOUS_SPEC_FILE"

reset_fixtures
cp "$PRIMARY_SPEC" "$PREVIOUS_SPEC_FILE"
printf '%s\n' '### deleted-without-tombstone' >> "$PREVIOUS_SPEC_FILE"
expect_fail "deleted active ID requires tombstone" "previous canonical ID 'deleted-without-tombstone' is missing without a retirement tombstone" run_validator --previous-spec "$PREVIOUS_SPEC_FILE"

reset_fixtures
cp "$PRIMARY_SPEC" "$PREVIOUS_SPEC_FILE"
append_identifier_table_row 'deleted-table-id' "$PREVIOUS_SPEC_FILE"
expect_pass "previous table proposal is not an active ID" run_validator --previous-spec "$PREVIOUS_SPEC_FILE"

reset_fixtures
cp "$PRIMARY_SPEC" "$PREVIOUS_SPEC_FILE"
printf '%s\n' '### renamed-old-id' >> "$PREVIOUS_SPEC_FILE"
printf '%s\n' '### renamed-new-id' >> "$PRIMARY_SPEC"
expect_fail "renamed active ID requires tombstone" "previous canonical ID 'renamed-old-id' is missing without a retirement tombstone" run_validator --previous-spec "$PREVIOUS_SPEC_FILE"

reset_fixtures
cp "$PRIMARY_SPEC" "$PREVIOUS_SPEC_FILE"
printf '%s\n' '### retired-old-id' >> "$PREVIOUS_SPEC_FILE"
printf '%s\n' '### retired-new-id' >> "$PRIMARY_SPEC"
append_retirement "$RETIRED_FILE" "retired-old-id" "retired-new-id"
expect_pass "valid active ID retirement and replacement" run_validator --previous-spec "$PREVIOUS_SPEC_FILE"

reset_fixtures
cp "$PRIMARY_SPEC" "$PREVIOUS_SPEC_FILE"
printf '%s\n' '<!-- ### hidden-previous-id -->' '```markdown' '### fenced-previous-id' '```' >> "$PREVIOUS_SPEC_FILE"
expect_pass "hidden previous IDs do not require tombstones" run_validator --previous-spec "$PREVIOUS_SPEC_FILE"

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

echo "1..$TESTS"

#!/bin/bash
# Validate canonical test specifications against implementations.json.current_target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${TARGET_DRAFT_CONFIG_FILE:-$ROOT_DIR/implementations.json}"
PRIMARY_SPEC="${TARGET_DRAFT_PRIMARY_SPEC:-$ROOT_DIR/docs/tests/TEST-CASES.md}"
RETIRED_FILE="${TARGET_DRAFT_RETIRED_FILE:-$ROOT_DIR/docs/tests/retired-test-identifiers.json}"
REGISTRY_FORMAT="moqt-retired-test-identifiers"
REGISTRY_VERSION=1
INITIAL_TOMBSTONE_PIN="v1:publish-track-only>publish-without-subscriber;publish-track-subscribe>publish-to-pending-subscription"
INITIAL_SOURCE_REPOSITORY="https://github.com/cloudflare/moq-rs"
INITIAL_SOURCE_COMMIT="b01d3f6707e3a74f69905722b451a08cbb3364f3"
INITIAL_REASON_WITHOUT_SUBSCRIBER="The legacy client/result scenario does not enforce the canonical Forward-State-aware object and PUBLISH_DONE lifecycle, including exact Stream Count and request-stream completion."
INITIAL_REASON_PENDING_SUBSCRIPTION="The legacy client/result scenario does not enforce subscriber-first rendezvous, Forward State 1, exact object delivery, and counted-stream completion required by the canonical test."
PREVIOUS_RETIRED_FILE=""
SPEC_FILES=()

usage() {
    printf 'Usage: %s [--previous-retired <file>] [additional-spec-file ...]\n' "${0##*/}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --previous-retired)
            [ $# -ge 2 ] || { echo "ERROR: --previous-retired requires a file" >&2; exit 1; }
            PREVIOUS_RETIRED_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [ $# -gt 0 ]; do
                SPEC_FILES+=("$1")
                shift
            done
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            exit 1
            ;;
        *)
            SPEC_FILES+=("$1")
            shift
            ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
command -v grep >/dev/null 2>&1 || { echo "ERROR: grep is required" >&2; exit 1; }
[ -f "$CONFIG_FILE" ] || { echo "ERROR: $CONFIG_FILE not found" >&2; exit 1; }
[ -f "$PRIMARY_SPEC" ] || { echo "ERROR: $PRIMARY_SPEC not found" >&2; exit 1; }
[ -f "$RETIRED_FILE" ] || { echo "ERROR: $RETIRED_FILE not found" >&2; exit 1; }
if [ -n "$PREVIOUS_RETIRED_FILE" ] && [ ! -f "$PREVIOUS_RETIRED_FILE" ]; then
    echo "ERROR: previous retirement registry not found: $PREVIOUS_RETIRED_FILE" >&2
    exit 1
fi

target="$(jq -er '.current_target | select(type == "string" and test("^draft-[0-9]+$"))' "$CONFIG_FILE" 2>/dev/null)" || {
    echo "ERROR: implementations.json.current_target must match draft-NN" >&2
    exit 1
}
target_number="${target#draft-}"
status=0
ACTIVE_IDS_FILE="$(mktemp "${TMPDIR:-/tmp}/active-test-identifiers.XXXXXX")"
ACTIVE_HEADING_IDS_FILE="$(mktemp "${TMPDIR:-/tmp}/active-heading-identifiers.XXXXXX")"
trap 'rm -f "$ACTIVE_IDS_FILE" "$ACTIVE_HEADING_IDS_FILE"' EXIT

sanitize_markdown() {
    local source="$1"
    local line remaining output before
    local in_comment=false
    local fence=""

    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$fence" ]; then
            if { [ "$fence" = "backtick" ] && printf '%s\n' "$line" | grep -Eq '^[[:space:]]*`{3,}[[:space:]]*$'; } ||
               { [ "$fence" = "tilde" ] && printf '%s\n' "$line" | grep -Eq '^[[:space:]]*~{3,}[[:space:]]*$'; }; then
                fence=""
            fi
            printf '\n'
            continue
        fi

        remaining="$line"
        output=""
        while [ -n "$remaining" ]; do
            if [ "$in_comment" = true ]; then
                if [[ "$remaining" == *"-->"* ]]; then
                    remaining="${remaining#*-->}"
                    in_comment=false
                else
                    remaining=""
                fi
            elif [[ "$remaining" == *"<!--"* ]]; then
                before="${remaining%%<!--*}"
                output="$output$before"
                remaining="${remaining#*<!--}"
                in_comment=true
            else
                output="$output$remaining"
                remaining=""
            fi
        done

        if printf '%s\n' "$output" | grep -Eq '^[[:space:]]*`{3,}'; then
            fence="backtick"
            printf '\n'
        elif printf '%s\n' "$output" | grep -Eq '^[[:space:]]*~{3,}'; then
            fence="tilde"
            printf '\n'
        else
            printf '%s\n' "$output"
        fi
    done < "$source"
}

check_declaration() {
    local display_spec="$1"
    local clean_spec="$2"
    local label="$3"
    local expected candidate_pattern count actual

    expected="**$label**: \`$target\`"
    case "$label" in
        "Target Draft") candidate_pattern='^[[:space:]]*(\*\*[[:space:]]*Target[[:space:]]+Draft[[:space:]]*\*\*|Target[[:space:]]+Draft[[:space:]]*:)' ;;
        "Identifier Semantics Reviewed For") candidate_pattern='^[[:space:]]*(\*\*[[:space:]]*Identifier[[:space:]]+Semantics[[:space:]]+Reviewed[[:space:]]+For[[:space:]]*\*\*|Identifier[[:space:]]+Semantics[[:space:]]+Reviewed[[:space:]]+For[[:space:]]*:)' ;;
        *) echo "ERROR: unsupported declaration label: $label" >&2; exit 1 ;;
    esac
    count="$(grep -Eic "$candidate_pattern" "$clean_spec" || true)"

    if [ "$count" -ne 1 ]; then
        echo "ERROR: $display_spec must contain exactly one $label declaration; found $count" >&2
        status=1
    elif [ "$(grep -Fxc "$expected" "$clean_spec" || true)" -ne 1 ]; then
        actual="$(grep -Ei "$candidate_pattern" "$clean_spec")"
        echo "ERROR: $display_spec has malformed or stale $label declaration '$actual'; expected '$expected'" >&2
        status=1
    fi
}

check_public_name() {
    local spec="$1"
    local line_number="$2"
    local kind="$3"
    local public_name="$4"

    if printf '%s\n' "$public_name" | grep -Eqi 'd[0-9]+|draft[-_][0-9]+|moqt[-_]?[0-9]+'; then
        echo "ERROR: $spec:$line_number has version-specific public $kind '$public_name'" >&2
        status=1
    fi
}

record_active_id() {
    local spec="$1"
    local line_number="$2"
    local kind="$3"
    local public_name="$4"

    check_public_name "$spec" "$line_number" "$kind" "$public_name"
    printf '%s\n' "$public_name" >> "$ACTIVE_IDS_FILE"
    if [ "$kind" = "heading ID" ]; then
        printf '%s\n' "$public_name" >> "$ACTIVE_HEADING_IDS_FILE"
    fi
}

check_spec() {
    local spec="$1"
    local clean_spec line_number line token public_name function_token first_cell heading_content
    local in_identifier_table=false

    clean_spec="$(mktemp "${TMPDIR:-/tmp}/canonical-test-spec.XXXXXX")"
    sanitize_markdown "$spec" > "$clean_spec"

    check_declaration "$spec" "$clean_spec" "Target Draft"
    check_declaration "$spec" "$clean_spec" "Identifier Semantics Reviewed For"

    while IFS=: read -r line_number line; do
        [ -n "$line_number" ] || continue
        while IFS= read -r token; do
            [ -n "$token" ] || continue
            case "$token" in
                "MoQT-$target_number"|"draft-ietf-moq-transport-$target_number") ;;
                *)
                    echo "ERROR: $spec:$line_number uses '$token'; target is $target" >&2
                    status=1
                    ;;
            esac
        done < <(printf '%s\n' "$line" | grep -Eo 'MoQT-[0-9]+|draft-ietf-moq-transport-[0-9]+' || true)
    done < <(grep -En 'MoQT-[0-9]+|draft-ietf-moq-transport-[0-9]+' "$clean_spec" || true)

    line_number=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))

        if [[ "$line" == "###"* ]]; then
            if printf '%s\n' "$line" | grep -Eq '^###[[:space:]]+(`([a-z][a-z0-9-]*)`|[a-z][a-z0-9-]*)[[:space:]]*$'; then
                public_name="$(printf '%s\n' "$line" | grep -Eo '[a-z][a-z0-9-]*')"
                record_active_id "$spec" "$line_number" "heading ID" "$public_name"
            else
                heading_content="${line#\#\#\#}"
                heading_content="${heading_content#"${heading_content%%[![:space:]]*}"}"
                if [[ "$heading_content" == *"\`"* ]] ||
                   [[ "$heading_content" != *" "* ]] ||
                   printf '%s\n' "$heading_content" | grep -Eq '^[a-z]|^[A-Za-z0-9_]*[-_][A-Za-z0-9_-]*'; then
                    check_public_name "$spec" "$line_number" "heading ID" "$heading_content"
                    echo "ERROR: $spec:$line_number has malformed canonical test heading '$heading_content'" >&2
                    status=1
                fi
            fi
        fi

        if [[ "$line" == *"|"* ]] && printf '%s\n' "$line" | grep -Eq '^[[:space:]]*\|'; then
            first_cell="${line#*|}"
            first_cell="${first_cell%%|*}"
            if printf '%s\n' "$first_cell" | grep -Eqi '^[[:space:]]*(identifier|test|test[[:space:]_-]+id)[[:space:]]*$'; then
                in_identifier_table=true
                continue
            fi
            if [ "$in_identifier_table" = true ]; then
                if printf '%s\n' "$first_cell" | grep -Eq '^[[:space:]]*:?-+:?[[:space:]]*$'; then
                    continue
                fi
                if printf '%s\n' "$first_cell" | grep -Eq '^[[:space:]]*(`[a-z][a-z0-9-]*`|[a-z][a-z0-9-]*)[[:space:]]*$'; then
                    public_name="$(printf '%s\n' "$first_cell" | grep -Eo '[a-z][a-z0-9-]*')"
                    record_active_id "$spec" "$line_number" "first-column table ID" "$public_name"
                else
                    check_public_name "$spec" "$line_number" "first-column table ID" "$first_cell"
                    echo "ERROR: $spec:$line_number has malformed canonical first-column table ID '$first_cell'" >&2
                    status=1
                fi
                continue
            fi
        else
            in_identifier_table=false
        fi

        while IFS= read -r function_token; do
            [ -n "$function_token" ] || continue
            public_name="$(printf '%s\n' "$function_token" | grep -Eo 'test_[A-Za-z0-9_-]+')"
            check_public_name "$spec" "$line_number" "function" "$public_name"
        done < <(printf '%s\n' "$line" | grep -Eo '`test_[A-Za-z0-9_-]+[[:space:]]*\(' || true)

        while IFS= read -r function_token; do
            [ -n "$function_token" ] || continue
            public_name="$(printf '%s\n' "$function_token" | grep -Eo 'test_[A-Za-z0-9_-]+')"
            check_public_name "$spec" "$line_number" "function" "$public_name"
        done < <(printf '%s\n' "$line" | grep -Eo 'fn[[:space:]]+test_[A-Za-z0-9_-]+[[:space:]]*\(' || true)
    done < "$clean_spec"

    rm -f "$clean_spec"
}

check_duplicate_active_ids() {
    local duplicate

    while IFS= read -r duplicate; do
        [ -n "$duplicate" ] || continue
        echo "ERROR: duplicate active canonical ID '$duplicate'" >&2
        status=1
    done < <(jq -Rrs 'split("\n") | map(select(length > 0)) | group_by(.)[] | select(length > 1) | .[0]' "$ACTIVE_IDS_FILE")
}

registry_has_valid_shape() {
    local registry="$1"

    jq -e --arg format "$REGISTRY_FORMAT" --argjson version "$REGISTRY_VERSION" '
        type == "object" and
        .format == $format and
        .format_version == $version and
        (.initial_tombstone_pin | type) == "string" and
        (.retired_identifiers | type) == "array" and
        all(.retired_identifiers[];
            ((.id | type) == "string" and (.id | test("^[a-z][a-z0-9-]*$"))) and
            ((.last_known_target | type) == "string" and (.last_known_target | test("^draft-[0-9]+$"))) and
            ((.last_known_profile_revision | type) == "string" and (.last_known_profile_revision | length) > 0) and
            ((.last_known_implementation | type) == "object") and
            ((.last_known_implementation.repository | type) == "string" and (.last_known_implementation.repository | length) > 0) and
            ((.last_known_implementation.commit | type) == "string" and (.last_known_implementation.commit | test("^[0-9a-f]{40}$"))) and
            ((.last_known_implementation.image_digest | type) == "string" and
                ((.last_known_implementation.image_digest == "unknown") or
                 (.last_known_implementation.image_digest | test("^sha256:[0-9a-f]{64}$")))) and
            ((.reason | type) == "string" and (.reason | length) > 0) and
            ((.replacement | type) == "string" and (.replacement | test("^[a-z][a-z0-9-]*$")))
        )
    ' "$registry" >/dev/null 2>&1
}

check_initial_tombstones() {
    if ! jq -e \
        --arg pin "$INITIAL_TOMBSTONE_PIN" \
        --arg repository "$INITIAL_SOURCE_REPOSITORY" \
        --arg commit "$INITIAL_SOURCE_COMMIT" \
        --arg reason_without_subscriber "$INITIAL_REASON_WITHOUT_SUBSCRIBER" \
        --arg reason_pending_subscription "$INITIAL_REASON_PENDING_SUBSCRIPTION" '
        .initial_tombstone_pin == $pin and
        .retired_identifiers[0] == {
            id: "publish-track-only",
            last_known_target: "draft-18",
            last_known_profile_revision: "legacy-unversioned",
            last_known_implementation: {
                repository: $repository,
                commit: $commit,
                image_digest: "unknown"
            },
            reason: $reason_without_subscriber,
            replacement: "publish-without-subscriber"
        } and
        .retired_identifiers[1] == {
            id: "publish-track-subscribe",
            last_known_target: "draft-18",
            last_known_profile_revision: "legacy-unversioned",
            last_known_implementation: {
                repository: $repository,
                commit: $commit,
                image_digest: "unknown"
            },
            reason: $reason_pending_subscription,
            replacement: "publish-to-pending-subscription"
        }
    ' "$RETIRED_FILE" >/dev/null 2>&1; then
        echo "ERROR: $RETIRED_FILE does not match the pinned initial tombstones" >&2
        status=1
    fi
}

check_retired_registry() {
    local duplicate retired_id replacement pinned_id

    if ! jq empty "$RETIRED_FILE" 2>/dev/null; then
        echo "ERROR: $RETIRED_FILE is not valid JSON" >&2
        status=1
        return
    fi
    if ! registry_has_valid_shape "$RETIRED_FILE"; then
        echo "ERROR: $RETIRED_FILE has an invalid registry format or retirement record" >&2
        status=1
        return
    fi

    check_initial_tombstones

    while IFS= read -r duplicate; do
        [ -n "$duplicate" ] || continue
        echo "ERROR: $RETIRED_FILE contains duplicate retired ID '$duplicate'" >&2
        status=1
    done < <(jq -r '.retired_identifiers | group_by(.id)[] | select(length > 1) | .[0].id' "$RETIRED_FILE")

    while IFS=$'\t' read -r retired_id replacement; do
        [ -n "$retired_id" ] || continue
        if [ "$retired_id" = "$replacement" ]; then
            echo "ERROR: retired ID '$retired_id' must have a different replacement" >&2
            status=1
        fi
        if grep -Fqx "$retired_id" "$ACTIVE_IDS_FILE"; then
            echo "ERROR: retired ID '$retired_id' is reused as an active canonical ID" >&2
            status=1
        fi
        if ! grep -Fqx "$replacement" "$ACTIVE_HEADING_IDS_FILE"; then
            echo "ERROR: replacement '$replacement' for retired ID '$retired_id' is not an active canonical heading ID" >&2
            status=1
        fi
    done < <(jq -r '.retired_identifiers[] | [.id, .replacement] | @tsv' "$RETIRED_FILE")

    for pinned_id in publish-track-only publish-track-subscribe; do
        if grep -Fqx "$pinned_id" "$ACTIVE_IDS_FILE"; then
            echo "ERROR: pinned retired ID '$pinned_id' is reused as an active canonical ID" >&2
            status=1
        fi
    done
}

check_previous_registry() {
    if [ -z "$PREVIOUS_RETIRED_FILE" ]; then
        return 0
    fi

    if ! jq empty "$PREVIOUS_RETIRED_FILE" 2>/dev/null || ! registry_has_valid_shape "$PREVIOUS_RETIRED_FILE"; then
        echo "ERROR: previous retirement registry has an invalid format: $PREVIOUS_RETIRED_FILE" >&2
        status=1
        return
    fi
    if ! jq -e --slurpfile current "$RETIRED_FILE" '
        . as $previous |
        ($previous.retired_identifiers | length) as $previous_length |
        ($previous_length <= ($current[0].retired_identifiers | length)) and
        all(range(0; $previous_length); . as $index |
            $current[0].retired_identifiers[$index] == $previous.retired_identifiers[$index])
    ' "$PREVIOUS_RETIRED_FILE" >/dev/null 2>&1; then
        echo "ERROR: retirement registry is not append-only; the previous tombstone array is not an exact prefix" >&2
        status=1
    fi
}

check_spec "$PRIMARY_SPEC"
for spec in "${SPEC_FILES[@]}"; do
    if [ ! -f "$spec" ]; then
        echo "ERROR: additional spec file not found: $spec" >&2
        status=1
        continue
    fi
    check_spec "$spec"
done

check_duplicate_active_ids
check_retired_registry
check_previous_registry

if [ "$status" -eq 0 ]; then
    echo "Target-draft policy valid: $target"
fi

exit "$status"

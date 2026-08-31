#!/bin/bash
# Validate canonical test specifications against implementations.json.current_target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${TARGET_DRAFT_CONFIG_FILE:-$ROOT_DIR/implementations.json}"
PRIMARY_SPEC="${TARGET_DRAFT_PRIMARY_SPEC:-$ROOT_DIR/docs/tests/TEST-CASES.md}"
RETIRED_FILE="${TARGET_DRAFT_RETIRED_FILE:-$ROOT_DIR/docs/tests/retired-test-identifiers.json}"
MARKDOWN_SANITIZER="${TARGET_DRAFT_MARKDOWN_SANITIZER:-$SCRIPT_DIR/sanitize-markdown.sh}"
DUPLICATE_CHECKER="${TARGET_DRAFT_DUPLICATE_CHECKER:-$SCRIPT_DIR/check-json-duplicates.sh}"
REGISTRY_FORMAT="moqt-retired-test-identifiers"
REGISTRY_VERSION=1
PREVIOUS_RETIRED_FILE=""
PREVIOUS_SPEC_FILE=""
SPEC_FILES=()

usage() {
    printf 'Usage: %s [--previous-retired <file>] [--previous-spec <file>] [additional-spec-file ...]\n' "${0##*/}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --previous-retired)
            [ $# -ge 2 ] || { echo "ERROR: --previous-retired requires a file" >&2; exit 1; }
            PREVIOUS_RETIRED_FILE="$2"
            shift 2
            ;;
        --previous-spec)
            [ $# -ge 2 ] || { echo "ERROR: --previous-spec requires a file" >&2; exit 1; }
            PREVIOUS_SPEC_FILE="$2"
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
[ -x "$MARKDOWN_SANITIZER" ] || { echo "ERROR: Markdown sanitizer not executable: $MARKDOWN_SANITIZER" >&2; exit 1; }
[ -x "$DUPLICATE_CHECKER" ] || { echo "ERROR: duplicate-key checker not executable: $DUPLICATE_CHECKER" >&2; exit 1; }
[ -f "$CONFIG_FILE" ] || { echo "ERROR: $CONFIG_FILE not found" >&2; exit 1; }
[ -f "$PRIMARY_SPEC" ] || { echo "ERROR: $PRIMARY_SPEC not found" >&2; exit 1; }
[ -f "$RETIRED_FILE" ] || { echo "ERROR: $RETIRED_FILE not found" >&2; exit 1; }
if [ -n "$PREVIOUS_RETIRED_FILE" ] && [ ! -f "$PREVIOUS_RETIRED_FILE" ]; then
    echo "ERROR: previous retirement registry not found: $PREVIOUS_RETIRED_FILE" >&2
    exit 1
fi
if [ -n "$PREVIOUS_SPEC_FILE" ] && [ ! -f "$PREVIOUS_SPEC_FILE" ]; then
    echo "ERROR: previous canonical specification not found: $PREVIOUS_SPEC_FILE" >&2
    exit 1
fi

json_inputs=("$CONFIG_FILE" "$RETIRED_FILE")
[ -z "$PREVIOUS_RETIRED_FILE" ] || json_inputs+=("$PREVIOUS_RETIRED_FILE")
"$DUPLICATE_CHECKER" "${json_inputs[@]}" || {
    echo "ERROR: target-draft JSON inputs must not contain duplicate object keys" >&2
    exit 1
}

target="$(jq -er '.current_target | select(type == "string" and test("^draft-[0-9]+$"))' "$CONFIG_FILE" 2>/dev/null)" || {
    echo "ERROR: implementations.json.current_target must match draft-NN" >&2
    exit 1
}
target_number="${target#draft-}"
status=0
ACTIVE_IDS_FILE="$(mktemp "${TMPDIR:-/tmp}/active-test-identifiers.XXXXXX")"
PREVIOUS_ACTIVE_IDS_FILE="$(mktemp "${TMPDIR:-/tmp}/previous-active-test-identifiers.XXXXXX")"
trap 'rm -f "$ACTIVE_IDS_FILE" "$PREVIOUS_ACTIVE_IDS_FILE"' EXIT

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

    if printf '%s\n' "$public_name" | grep -Eqi 'd[0-9]+|draft[-_]?[0-9]+|moqt[-_]?[0-9]+'; then
        echo "ERROR: $spec:$line_number has version-specific public $kind '$public_name'" >&2
        status=1
    fi
}

record_active_id() {
    local spec="$1"
    local line_number="$2"
    local public_name="$3"
    local active_ids_file="$4"
    local enforce_policy="$5"

    if [ "$enforce_policy" = true ]; then
        check_public_name "$spec" "$line_number" "heading ID" "$public_name"
    fi
    printf '%s\n' "$public_name" >> "$active_ids_file"
}

scan_active_ids() {
    local spec="$1"
    local clean_spec="$2"
    local active_ids_file="$3"
    local enforce_policy="$4"
    local line_number line public_name first_cell heading_content
    local in_identifier_table=false

    line_number=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))

        if printf '%s\n' "$line" | grep -Eq '^ {0,3}###'; then
            if printf '%s\n' "$line" | grep -Eq '^ {0,3}###[[:space:]]+(`([a-z][a-z0-9-]*)`|[a-z][a-z0-9-]*)[[:space:]]*$'; then
                public_name="$(printf '%s\n' "$line" | grep -Eo '[a-z][a-z0-9-]*')"
                record_active_id "$spec" "$line_number" "$public_name" "$active_ids_file" "$enforce_policy"
            else
                heading_content="${line#*###}"
                heading_content="${heading_content#"${heading_content%%[![:space:]]*}"}"
                if [ "$enforce_policy" = true ] &&
                   { [[ "$heading_content" == *"\`"* ]] ||
                     [[ "$heading_content" != *" "* ]] ||
                     printf '%s\n' "$heading_content" | grep -Eq '^[a-z]|^[A-Za-z0-9_]*[-_][A-Za-z0-9_-]*'; }; then
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
                if [ "$enforce_policy" = true ]; then
                    check_public_name "$spec" "$line_number" "test-ID table entry" "$first_cell"
                fi
                continue
            fi
        else
            in_identifier_table=false
        fi

    done < "$clean_spec"
}

check_spec() {
    local spec="$1"
    local active_ids_file="$2"
    local clean_spec line_number line token

    clean_spec="$(mktemp "${TMPDIR:-/tmp}/canonical-test-spec.XXXXXX")"
    "$MARKDOWN_SANITIZER" "$spec" > "$clean_spec"

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

    scan_active_ids "$spec" "$clean_spec" "$active_ids_file" true

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
        (keys | sort) == ["format", "format_version", "retired_identifiers"] and
        .format == $format and
        .format_version == $version and
        (.retired_identifiers | type) == "array" and
        all(.retired_identifiers[];
            (keys | sort) == ["id", "last_known_spec_revision", "last_known_target", "reason", "replacement"] and
            ((.id | type) == "string" and (.id | test("^[a-z][a-z0-9-]*$"))) and
            ((.last_known_target | type) == "string" and (.last_known_target | test("^draft-[0-9]+$"))) and
            ((.last_known_spec_revision | type) == "string" and (.last_known_spec_revision | length) > 0) and
            ((.reason | type) == "string" and (.reason | length) > 0) and
            ((.replacement == null) or
             ((.replacement | type) == "string" and (.replacement | test("^[a-z][a-z0-9-]*$"))))
        )
    ' "$registry" >/dev/null 2>&1
}

check_retirement_chains() {
    local retired_id current replacement path

    while IFS= read -r retired_id; do
        [ -n "$retired_id" ] || continue
        if grep -Fqx "$retired_id" "$ACTIVE_IDS_FILE"; then
            echo "ERROR: retired ID '$retired_id' is reused as an active canonical ID" >&2
            status=1
        fi

        current="$retired_id"
        path="|$retired_id|"
        while true; do
            replacement="$(jq -r --arg id "$current" '.retired_identifiers[] | select(.id == $id) | if .replacement == null then "__NO_REPLACEMENT__" else .replacement end' "$RETIRED_FILE")"
            if [ "$replacement" = "__NO_REPLACEMENT__" ]; then
                if [ "$current" != "$retired_id" ]; then
                    echo "ERROR: retirement chain from '$retired_id' terminates at retired ID '$current' with no replacement" >&2
                    status=1
                fi
                break
            fi
            if grep -Fqx "$replacement" "$ACTIVE_IDS_FILE"; then
                break
            fi
            if ! jq -e --arg id "$replacement" 'any(.retired_identifiers[]; .id == $id)' "$RETIRED_FILE" >/dev/null; then
                echo "ERROR: retirement chain from '$retired_id' does not terminate at an active canonical ID" >&2
                status=1
                break
            fi
            if [[ "$path" == *"|$replacement|"* ]]; then
                echo "ERROR: retirement chain from '$retired_id' contains a cycle at '$replacement'" >&2
                status=1
                break
            fi
            path="$path$replacement|"
            current="$replacement"
        done
    done < <(jq -r '.retired_identifiers[].id' "$RETIRED_FILE")
}

check_retired_registry() {
    local duplicate

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

    while IFS= read -r duplicate; do
        [ -n "$duplicate" ] || continue
        echo "ERROR: $RETIRED_FILE contains duplicate retired ID '$duplicate'" >&2
        status=1
    done < <(jq -r '.retired_identifiers | group_by(.id)[] | select(length > 1) | .[0].id' "$RETIRED_FILE")

    check_retirement_chains
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

check_previous_spec() {
    local clean_spec previous_id

    if [ -z "$PREVIOUS_SPEC_FILE" ]; then
        return 0
    fi

    clean_spec="$(mktemp "${TMPDIR:-/tmp}/previous-canonical-test-spec.XXXXXX")"
    "$MARKDOWN_SANITIZER" "$PREVIOUS_SPEC_FILE" > "$clean_spec"
    scan_active_ids "$PREVIOUS_SPEC_FILE" "$clean_spec" "$PREVIOUS_ACTIVE_IDS_FILE" false
    rm -f "$clean_spec"

    while IFS= read -r previous_id; do
        [ -n "$previous_id" ] || continue
        if grep -Fqx "$previous_id" "$ACTIVE_IDS_FILE"; then
            continue
        fi
        if ! jq -e --arg id "$previous_id" 'any(.retired_identifiers[]; .id == $id)' "$RETIRED_FILE" >/dev/null; then
            echo "ERROR: previous canonical ID '$previous_id' is missing without a retirement tombstone" >&2
            status=1
        fi
    done < <(jq -Rrs 'split("\n") | map(select(length > 0)) | unique[]' "$PREVIOUS_ACTIVE_IDS_FILE")
}

check_spec "$PRIMARY_SPEC" "$ACTIVE_IDS_FILE"
for spec in "${SPEC_FILES[@]}"; do
    if [ ! -f "$spec" ]; then
        echo "ERROR: additional spec file not found: $spec" >&2
        status=1
        continue
    fi
    check_spec "$spec" /dev/null
done

check_duplicate_active_ids
check_retired_registry
check_previous_registry
check_previous_spec

if [ "$status" -eq 0 ]; then
    echo "Target-draft policy valid: $target"
fi

exit "$status"

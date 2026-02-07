#!/bin/bash
# lib/tap-parser.sh - Parse TAP14 output from test client log files
#
# Extracts pass/fail/skip counts from TAP version 14 output.
# Falls back to legacy checkmark (✓/✗) parsing if no TAP version line is found.
#
# Handles docker-compose log prefixes (e.g., "test-client-1  | ok 1 - name")
# by stripping them before parsing.
#
# Usage:
#   source lib/tap-parser.sh
#   parse_tap_file "path/to/logfile.log"
#   echo "passed=$TAP_PASSED failed=$TAP_FAILED skipped=$TAP_SKIPPED total=$TAP_TOTAL"
#   echo "format=$TAP_FORMAT"  # "tap14" or "legacy"

# Parse a log file and set TAP_PASSED, TAP_FAILED, TAP_SKIPPED, TAP_TOTAL, TAP_FORMAT.
#
# Returns 0 if any test results were found, 1 if the file has no parseable results.
parse_tap_file() {
    local file="$1"

    # Reset counters
    TAP_PASSED=0
    TAP_FAILED=0
    TAP_SKIPPED=0
    TAP_TOTAL=0
    TAP_FORMAT="unknown"

    if [ ! -f "$file" ]; then
        return 1
    fi

    # Check if this is TAP output by looking for the version line.
    # Use a relaxed grep that allows docker-compose prefixes.
    if grep -q "TAP version 1[34]" "$file" 2>/dev/null; then
        TAP_FORMAT="tap14"
        _parse_tap "$file"
    elif grep -q "✓\|✗" "$file" 2>/dev/null; then
        TAP_FORMAT="legacy"
        _parse_legacy "$file"
    else
        return 1
    fi

    TAP_TOTAL=$((TAP_PASSED + TAP_FAILED + TAP_SKIPPED))
    return 0
}

# Strip docker-compose log prefixes.
#
# Docker compose prefixes lines with "container-name  | " (variable whitespace).
# This function strips that prefix if present, yielding the raw test client output.
_strip_docker_prefix() {
    # Match: word chars, dashes, dots (container name), whitespace, pipe, space(s)
    # e.g. "test-client-1  | ok 1 - test" -> "ok 1 - test"
    sed 's/^[a-zA-Z0-9._-]*[[:space:]]*|[[:space:]]*//'
}

# Parse TAP14 (or TAP13) format.
#
# Pipes through _strip_docker_prefix, then classifies each line as PASS/FAIL/SKIP.
# Uses a temp file to work around bash subshell variable scoping with pipes.
_parse_tap() {
    local file="$1"
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/tap-parser.XXXXXX")

    _strip_docker_prefix < "$file" | while IFS= read -r line; do
        # Skip indented lines (subtests are 4-space indented)
        case "$line" in
            "    "*) continue ;;
        esac

        if [[ "$line" =~ ^ok\ [0-9]+ ]] || [[ "$line" =~ ^ok\ -\  ]] || [[ "$line" =~ ^ok$ ]]; then
            # Check for SKIP directive (case-insensitive)
            if echo "$line" | grep -qi ' # SKIP'; then
                echo "SKIP"
            else
                echo "PASS"
            fi
        elif [[ "$line" =~ ^not\ ok ]]; then
            # "not ok" with TODO directive counts as a todo, not a failure.
            # Per TAP spec, TODO tests are expected to fail.
            if echo "$line" | grep -qi ' # TODO'; then
                echo "PASS"
            else
                echo "FAIL"
            fi
        fi
    done > "$tmpfile"

    TAP_PASSED=$(grep -c "^PASS$" "$tmpfile" 2>/dev/null) || TAP_PASSED=0
    TAP_FAILED=$(grep -c "^FAIL$" "$tmpfile" 2>/dev/null) || TAP_FAILED=0
    TAP_SKIPPED=$(grep -c "^SKIP$" "$tmpfile" 2>/dev/null) || TAP_SKIPPED=0
    rm -f "$tmpfile"
}

# Parse legacy checkmark format (fallback).
# Uses relaxed matching (no ^ anchor) to handle docker-compose prefixed output.
_parse_legacy() {
    local file="$1"
    TAP_PASSED=$(grep -c "✓" "$file" 2>/dev/null) || TAP_PASSED=0
    TAP_FAILED=$(grep -c "✗" "$file" 2>/dev/null) || TAP_FAILED=0
}

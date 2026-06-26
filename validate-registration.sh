#!/bin/bash
# validate-registration.sh - Validate implementations.json registration changes.
#
# Runs the default checks for a PR that adds/removes/edits a client or relay
# registration. Usable locally and in CI. Three checks:
#
#   1. Schema     - implementations.json validates against implementations.schema.json
#   2. Test plan  - for each changed implementation, show the pairs + negotiated
#                   draft versions that WOULD be tested (run-interop-tests.sh --dry-run)
#   3. Image      - the Docker image(s) the changed impl registers actually exist
#                   (soft warning: a private/unpullable image cannot be checked on
#                   a fork PR, so it must not hard-fail the gate)
#
# Only the schema check is a hard gate. The plan is informational; image problems
# are warnings. Interop pass/fail is NOT evaluated here — that is the maintainer-
# gated live run.
#
# Usage:
#   ./validate-registration.sh [--base <ref>] [--impl <name>] [--summary <file>]
#
#   --base <ref>     Git ref to diff against to find changed impls (default: origin/main)
#   --impl <name>    Validate this implementation explicitly (skip the git diff)
#   --summary <file> Append the markdown report here (default: $GITHUB_STEP_SUMMARY, else stdout)
#
# Exit codes:
#   0 - Schema valid (warnings may be present)
#   1 - Schema invalid, or a usage/environment error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/implementations.json"
SCHEMA_FILE="$SCRIPT_DIR/implementations.schema.json"

BASE_REF="origin/main"
EXPLICIT_IMPL=""
SUMMARY_OUT="${GITHUB_STEP_SUMMARY:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)    BASE_REF="$2"; shift 2 ;;
        --impl)    EXPLICIT_IMPL="$2"; shift 2 ;;
        --summary) SUMMARY_OUT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Markdown report accumulates in a temp file, then is appended to the target.
REPORT="$(mktemp "${TMPDIR:-/tmp}/validate-registration.XXXXXX")"
trap 'rm -f "$REPORT"' EXIT
md() { printf '%s\n' "$1" >> "$REPORT"; }

# Track the worst outcome for the final exit code and headline.
SCHEMA_OK=true
WARNINGS=0

#############################################################################
# Dependency checks
#############################################################################
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
[ -f "$CONFIG_FILE" ] || { echo "ERROR: $CONFIG_FILE not found" >&2; exit 1; }
[ -f "$SCHEMA_FILE" ] || { echo "ERROR: $SCHEMA_FILE not found" >&2; exit 1; }

if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    md "## Registration validation"
    md ""
    md "❌ **implementations.json is not valid JSON.**"
    SCHEMA_OK=false
    # Cannot do anything further without parseable JSON.
    cat "$REPORT"
    [ -n "$SUMMARY_OUT" ] && cat "$REPORT" >> "$SUMMARY_OUT"
    exit 1
fi

#############################################################################
# 1. Schema validation (hard gate)
#############################################################################
schema_error=""
if command -v check-jsonschema >/dev/null 2>&1; then
    schema_error="$(check-jsonschema --schemafile "$SCHEMA_FILE" "$CONFIG_FILE" 2>&1)" || SCHEMA_OK=false
elif python3 -c 'import jsonschema' >/dev/null 2>&1; then
    schema_error="$(python3 - "$SCHEMA_FILE" "$CONFIG_FILE" <<'PY' 2>&1
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
instance = json.load(open(sys.argv[2]))
try:
    jsonschema.validate(instance, schema)
except jsonschema.ValidationError as e:
    path = "/".join(str(p) for p in e.absolute_path) or "(root)"
    print(f"{path}: {e.message}")
    sys.exit(1)
PY
)" || SCHEMA_OK=false
else
    echo "ERROR: need 'check-jsonschema' or python 'jsonschema' to validate schema" >&2
    exit 1
fi

#############################################################################
# 2. Determine changed implementations
#############################################################################
CHANGED=()
REMOVED=()

if [ -n "$EXPLICIT_IMPL" ]; then
    CHANGED=("$EXPLICIT_IMPL")
else
    # Base version of implementations.json (empty object if absent / unreachable).
    base_json="$(git show "$BASE_REF:implementations.json" 2>/dev/null || echo '{}')"

    # Keys present in HEAD whose subtree differs from base => added or edited.
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        head_sub="$(jq -Sc --arg k "$key" '.implementations[$k]' "$CONFIG_FILE")"
        base_sub="$(printf '%s' "$base_json" | jq -Sc --arg k "$key" '.implementations[$k] // null')"
        [ "$head_sub" != "$base_sub" ] && CHANGED+=("$key")
    done < <(jq -r '.implementations | keys[]' "$CONFIG_FILE")

    # Keys present in base but gone from HEAD => removed.
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        REMOVED+=("$key")
    done < <(printf '%s' "$base_json" \
        | jq -r --slurpfile head "$CONFIG_FILE" \
            '(.implementations // {} | keys) - ($head[0].implementations | keys) | .[]' 2>/dev/null || true)
fi

#############################################################################
# Helpers
#############################################################################
impl_roles() { jq -r --arg k "$1" '.implementations[$k].roles | keys[]?' "$CONFIG_FILE"; }
impl_images() { jq -r --arg k "$1" '.implementations[$k].roles[]?.docker.image // empty' "$CONFIG_FILE"; }

# Check a Docker image exists in its registry without pulling the full image.
image_available() {
    local img="$1"
    docker manifest inspect "$img" >/dev/null 2>&1 && return 0
    docker image inspect "$img" >/dev/null 2>&1 && return 0
    return 1
}

#############################################################################
# Build the markdown report
#############################################################################
md "## Registration validation"
md ""

# --- Schema ---
if [ "$SCHEMA_OK" = true ]; then
    md "**Schema:** ✅ valid against \`implementations.schema.json\`"
else
    md "**Schema:** ❌ invalid"
    md ""
    md '```'
    md "${schema_error:-validation failed}"
    md '```'
fi
md ""

# --- Removed impls (informational) ---
if [ "${#REMOVED[@]}" -gt 0 ]; then
    md "**Removed registrations:** ${REMOVED[*]}"
    md ""
fi

# --- Changed impls: plan + image check ---
if [ "${#CHANGED[@]}" -eq 0 ]; then
    md "_No added or edited implementations detected (base: \`$BASE_REF\`)._"
else
    md "**Changed registrations:** ${CHANGED[*]}"
    md ""
    for impl in "${CHANGED[@]}"; do
        # Skip if the key doesn't actually exist in HEAD (defensive).
        if [ "$(jq -r --arg k "$impl" '.implementations[$k] // "MISSING"' "$CONFIG_FILE")" = "MISSING" ]; then
            continue
        fi

        md "### \`$impl\`"
        md ""

        # Image existence (soft)
        local_images="$(impl_images "$impl" | sort -u)"
        if [ -n "$local_images" ]; then
            md "**Images:**"
            while IFS= read -r img; do
                [ -z "$img" ] && continue
                if image_available "$img"; then
                    md "- ✅ \`$img\`"
                else
                    md "- ⚠️ \`$img\` — could not verify (missing, private, or registry unreachable)"
                    WARNINGS=$((WARNINGS + 1))
                fi
            done <<< "$local_images"
            md ""
        fi

        # Test plan (informational) — show for each role the impl has
        md "**Would be tested:**"
        md '```'
        roles="$(impl_roles "$impl")"
        plan_shown=false
        if grep -q '^client$' <<< "$roles"; then
            ./run-interop-tests.sh --dry-run --client "$impl" 2>/dev/null \
                | sed -n '/── Test Plan ──/,/Runs planned:/p' >> "$REPORT" || true
            plan_shown=true
        fi
        if grep -q '^relay$' <<< "$roles"; then
            ./run-interop-tests.sh --dry-run --relay "$impl" 2>/dev/null \
                | sed -n '/── Test Plan ──/,/Runs planned:/p' >> "$REPORT" || true
            plan_shown=true
        fi
        [ "$plan_shown" = false ] && md "(no client or relay role registered)"
        md '```'
        md ""
    done
fi

# --- Footer / headline ---
md "---"
if [ "$SCHEMA_OK" = true ]; then
    if [ "$WARNINGS" -gt 0 ]; then
        md "✅ Schema valid · ⚠️ $WARNINGS image warning(s) (non-blocking)"
    else
        md "✅ All checks passed."
    fi
else
    md "❌ Schema invalid — fix the errors above."
fi

#############################################################################
# Emit
#############################################################################
cat "$REPORT"
if [ -n "$SUMMARY_OUT" ] && [ "$SUMMARY_OUT" != "/dev/stdout" ]; then
    cat "$REPORT" >> "$SUMMARY_OUT"
fi

[ "$SCHEMA_OK" = true ]

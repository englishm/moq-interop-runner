#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JS_CHECKER="$SCRIPT_DIR/check-json-duplicates.js"

[ "$#" -gt 0 ] || { echo "Usage: ${0##*/} JSON_FILE [...]" >&2; exit 2; }

if command -v python3 >/dev/null 2>&1; then
    python3 - "$@" <<'PY'
import json
import sys

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate object key: {key}")
        result[key] = value
    return result

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as source:
        json.load(source, object_pairs_hook=unique_object)
PY
elif command -v bun >/dev/null 2>&1; then
    bun "$JS_CHECKER" "$@"
elif command -v node >/dev/null 2>&1; then
    node "$JS_CHECKER" "$@"
else
    echo "ERROR: Python, Bun, or Node is required to reject duplicate JSON keys" >&2
    exit 1
fi

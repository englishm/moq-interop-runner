#!/bin/bash
# Replace CommonMark code and HTML blocks with blank lines for spec scanning.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source_file="${1:-}"
[ -n "$source_file" ] && [ -f "$source_file" ] || {
    echo "Usage: ${0##*/} MARKDOWN_FILE" >&2
    exit 2
}

if command -v bun >/dev/null 2>&1 && (cd "$ROOT_DIR" && bun -e 'require.resolve("commonmark")' >/dev/null 2>&1); then
    exec bun "$SCRIPT_DIR/sanitize-markdown.js" "$source_file"
elif command -v node >/dev/null 2>&1 && (cd "$ROOT_DIR" && node -e 'require.resolve("commonmark")' >/dev/null 2>&1); then
    exec node "$SCRIPT_DIR/sanitize-markdown.js" "$source_file"
else
    in_fence=false
    in_comment=false
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$in_fence" = true ]; then
            if printf '%s\n' "$line" | grep -Eq '^ {0,3}(`{3,}|~{3,})[[:space:]]*$'; then
                in_fence=false
            fi
            printf '\n'
        elif [ "$in_comment" = true ]; then
            if [[ "$line" == *"-->"* ]]; then
                in_comment=false
            fi
            printf '\n'
        elif printf '%s\n' "$line" | grep -Eq '^ {0,3}(`{3,}|~{3,})'; then
            in_fence=true
            printf '\n'
        elif printf '%s\n' "$line" | grep -Eq '^ {0,3}<!--'; then
            [[ "$line" == *"-->"* ]] || in_comment=true
            printf '\n'
        elif [[ "$line" == *"<!--"* || "$line" == *"-->"* ]] ||
             printf '%s\n' "$line" | grep -Eq '^[[:space:]]*(>|[-+*][[:space:]]|[0-9]+\.[[:space:]])+.*#{1,6}[[:space:]]'; then
            echo "ERROR: install the pinned CommonMark dependency to validate complex Markdown: $source_file" >&2
            exit 1
        else
            printf '%s\n' "$line"
        fi
    done < "$source_file"
fi

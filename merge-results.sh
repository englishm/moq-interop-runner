#!/bin/bash
# merge-results.sh - Merge per-relay shard results into one results directory.
#
# Usage: merge-results.sh <out_dir> <shard_results_dir>...
#
# Copies each shard's logs into <out_dir> (names are unique per
# client/relay/mode) and writes one summary.json with the runs in the order a
# single run-interop-tests.sh run writes them: classification (at, ahead,
# behind), then client and relay in implementations.json order.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/implementations.json}"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <out_dir> <shard_results_dir>..." >&2
    exit 1
fi

out="$1"
shift
mkdir -p "$out"

summaries=()
for dir in "$@"; do
    if [ ! -f "$dir/summary.json" ]; then
        echo "warning: no summary.json in $dir, skipping" >&2
        continue
    fi
    find "$dir" -maxdepth 1 -type f ! -name summary.json -exec cp {} "$out/" \;
    summaries+=("$dir/summary.json")
done

if [ ${#summaries[@]} -eq 0 ]; then
    echo "error: no shard summaries to merge" >&2
    exit 1
fi

jq -s --slurpfile cfg "$CONFIG_FILE" '
    ($cfg[0].implementations | keys_unsorted | to_entries
        | map({key: .value, value: .key}) | from_entries) as $pos |
    {at: 0, ahead: 1, behind: 2} as $rank |
    {
        runs: ([.[].runs[]] | sort_by([
            ($rank[.classification] // 3),
            ($pos[.client] // 9999),
            ($pos[.relay] // 9999)
        ])),
        target_version: .[0].target_version,
        timestamp: (map(.timestamp) | min)
    }' "${summaries[@]}" > "$out/summary.json"

echo "Merged ${#summaries[@]} shard(s): $(jq '.runs | length' "$out/summary.json") runs -> $out"

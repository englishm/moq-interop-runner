#!/bin/bash
# merge-results.sh - Merge per-draft result summaries (POC).
#
# Combines two or more summary.json files. Later files override earlier ones per
# (family, family, draft, transport) cell — so real pinned results can be layered
# on top of a dummy baseline:
#
#   ./merge-results.sh dummy.json real.json > merged.json
#
# Cells are keyed by family (a real run for moq-rs-draft-16 overrides the dummy
# run for the moq-rs family), so real cells win and everything else stays dummy.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/implementations.json"
if [ "${1:-}" = "--config" ]; then CONFIG="$2"; shift 2; fi
[ "$#" -ge 1 ] || { echo "Usage: $0 [--config impl.json] base.json [override.json ...]" >&2; exit 1; }

jq -s --slurpfile cfg "$CONFIG" '
  ($cfg[0].implementations | to_entries
     | map({key: .key, value: (.value.family // .key)}) | from_entries) as $fam
  | ( reduce .[] as $s ({};
        reduce ($s.runs // [])[] as $run (.;
          ( ($run.view // "draft") + "|" +
            (($fam[$run.client]) // $run.client) + "|" +
            (($fam[$run.relay])  // $run.relay)  + "|" +
            $run.draft + "|" + $run.transport ) as $k
          | .[$k] = $run)) ) as $cells
  | { timestamp: ((.[-1].timestamp // .[0].timestamp) // "merged"),
      model: "merged",
      runs: ($cells | to_entries | map(.value)) }
' "$@"

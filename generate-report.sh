#!/bin/bash
# generate-report.sh - Generate HTML report from test results
#
# Usage: ./generate-report.sh [results-dir]
#        If no dir specified, generates index of all runs + most recent detail
#        ./generate-report.sh --index    Generate only the index page
#
# Exit codes:
#   0 - Success
#   1 - Error (missing results, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_BASE="$SCRIPT_DIR/results"
INDEX_ONLY=false

# Source shared TAP parser
source "$SCRIPT_DIR/lib/tap-parser.sh"

# Parse args
if [ "${1:-}" = "--index" ]; then
    INDEX_ONLY=true
    shift
fi

# Find most recent directory by modification time (OS-portable)
find_newest_dir() {
    local base_dir="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: use stat with -f for format
        find "$base_dir" -maxdepth 1 -type d ! -path "$base_dir" -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
    else
        # Linux: use find -printf
        find "$base_dir" -maxdepth 1 -type d ! -path "$base_dir" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
    fi
}

# Find results directory
if [ -n "${1:-}" ]; then
    RESULTS_DIR="$1"
else
    RESULTS_DIR=$(find_newest_dir "$RESULTS_BASE")
fi

#############################################################################
# Generate Index Page (all runs)
#############################################################################
generate_index() {
    local INDEX_FILE="$RESULTS_BASE/index.html"
    echo "Generating index: $INDEX_FILE"

    cat > "$INDEX_FILE" << 'INDEXHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MoQT Interop Test Results</title>
    <style>
        :root {
            --pass: #22c55e;
            --fail: #ef4444;
            --bg: #0f172a;
            --card: #1e293b;
            --text: #f1f5f9;
            --muted: #94a3b8;
            --link: #60a5fa;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg);
            color: var(--text);
            padding: 2rem;
            line-height: 1.6;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { margin-bottom: 0.5rem; }
        h2 { margin: 2rem 0 1rem; color: var(--muted); font-size: 1rem; text-transform: uppercase; letter-spacing: 0.05em; }
        .meta { color: var(--muted); margin-bottom: 2rem; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        .runs { display: grid; gap: 1rem; }
        .run {
            background: var(--card);
            padding: 1rem 1.5rem;
            border-radius: 0.5rem;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .run-info { }
        .run-date { font-weight: 600; }
        .run-meta { color: var(--muted); font-size: 0.875rem; }
        .run-stats { display: flex; gap: 1rem; }
        .stat { text-align: center; }
        .stat-value { font-size: 1.25rem; font-weight: bold; }
        .stat-label { font-size: 0.75rem; color: var(--muted); }
        .pass { color: var(--pass); }
        .fail { color: var(--fail); }
        .skip { color: var(--muted); }
    </style>
</head>
<body>
    <div class="container">
        <h1>MoQT Interop Test Results</h1>
        <p class="meta">Test runs from moq-test-client</p>

        <h2>All Test Runs</h2>
        <div class="runs">
INDEXHEAD

    # List all results dirs, newest first (OS-portable)
    # Use while read to handle paths with spaces safely
    if [[ "$(uname)" == "Darwin" ]]; then
        find "$RESULTS_BASE" -maxdepth 1 -type d ! -path "$RESULTS_BASE" -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn | cut -d' ' -f2-
    else
        find "$RESULTS_BASE" -maxdepth 1 -type d ! -path "$RESULTS_BASE" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
    fi | while IFS= read -r dir; do
        local summary="$dir/summary.json"
        if [ -f "$summary" ]; then
            local dirname=$(basename "$dir")
            local timestamp=$(jq -r '.timestamp // "unknown"' "$summary")
            local version=$(jq -r '.target_version // "?"' "$summary")
            local total=$(jq '.runs | length' "$summary")
            local passed=$(jq '[.runs[] | select(.status == "pass")] | length' "$summary")
            local failed=$(jq '[.runs[] | select(.status == "fail")] | length' "$summary")
            local skipped=$(jq '[.runs[] | select(.status == "skip")] | length' "$summary")

            local skip_stat=""
            if [ "$skipped" -gt 0 ]; then
                skip_stat="<div class=\"stat\"><div class=\"stat-value skip\">$skipped</div><div class=\"stat-label\">Skip</div></div>"
            fi

            cat >> "$INDEX_FILE" << EOF
            <div class="run">
                <div class="run-info">
                    <div class="run-date"><a href="$dirname/report.html">$timestamp</a></div>
                    <div class="run-meta">Target: $version</div>
                </div>
                <div class="run-stats">
                    <div class="stat"><div class="stat-value pass">$passed</div><div class="stat-label">Pass</div></div>
                    <div class="stat"><div class="stat-value fail">$failed</div><div class="stat-label">Fail</div></div>
                    $skip_stat
                    <div class="stat"><div class="stat-value">$total</div><div class="stat-label">Total</div></div>
                </div>
            </div>
EOF
        fi
    done

    cat >> "$INDEX_FILE" << 'INDEXFOOT'
        </div>
    </div>
</body>
</html>
INDEXFOOT
    echo "Index generated: $INDEX_FILE"
}

#############################################################################
# Generate Detail Report (single run with matrix)
#############################################################################
generate_detail() {
    local RESULTS_DIR="$1"
    local SUMMARY_FILE="$RESULTS_DIR/summary.json"
    local OUTPUT_FILE="$RESULTS_DIR/report.html"

    if [ ! -f "$SUMMARY_FILE" ]; then
        echo "Error: No summary.json in $RESULTS_DIR"
        return 1
    fi

    echo "Generating detail report: $OUTPUT_FILE"

    # Extract data from summary
    local TIMESTAMP=$(jq -r '.timestamp' "$SUMMARY_FILE")
    local TARGET_VERSION=$(jq -r '.target_version // "unknown"' "$SUMMARY_FILE")
    local TOTAL=$(jq '.runs | length' "$SUMMARY_FILE")
    local PASSED=$(jq '[.runs[] | select(.status == "pass")] | length' "$SUMMARY_FILE")
    local FAILED=$(jq '[.runs[] | select(.status == "fail")] | length' "$SUMMARY_FILE")
    local SKIPPED_COUNT=$(jq '[.runs[] | select(.status == "skip")] | length' "$SUMMARY_FILE")

    # Classification counts (backward compat: compute from version vs target_version if absent)
    local classify_expr='
        .target_version as $tv |
        ($tv | ltrimstr("draft-") | tonumber) as $tn |
        [.runs[] |
            (.classification // (
                (.version | ltrimstr("draft-") | tonumber) as $vn |
                if $vn == $tn then "at"
                elif $vn > $tn then "ahead"
                else "behind" end
            ))
        ]'
    local AT_TARGET=$(jq "$classify_expr | map(select(. == \"at\")) | length" "$SUMMARY_FILE")
    local AHEAD=$(jq "$classify_expr | map(select(. == \"ahead\")) | length" "$SUMMARY_FILE")
    local BEHIND=$(jq "$classify_expr | map(select(. == \"behind\")) | length" "$SUMMARY_FILE")

    # Get unique clients and relays for matrix
    local CLIENTS=$(jq -r '[.runs[].client] | unique | .[]' "$SUMMARY_FILE")
    local RELAYS=$(jq -r '[.runs[].relay] | unique | .[]' "$SUMMARY_FILE")

    cat > "$OUTPUT_FILE" << 'HEADER'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MoQT Interop Test Results</title>
    <style>
        :root {
            --pass: #22c55e;
            --fail: #ef4444;
            --bg: #0f172a;
            --card: #1e293b;
            --text: #f1f5f9;
            --muted: #94a3b8;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg);
            color: var(--text);
            padding: 2rem;
            line-height: 1.6;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { margin-bottom: 0.5rem; }
        .meta { color: var(--muted); margin-bottom: 2rem; }
        .summary {
            display: flex;
            flex-wrap: wrap;
            gap: 1rem;
            margin-bottom: 2rem;
        }
        .stat {
            background: var(--card);
            padding: 1rem 2rem;
            border-radius: 0.5rem;
            text-align: center;
        }
        .stat-value { font-size: 2rem; font-weight: bold; }
        .stat-label { color: var(--muted); font-size: 0.875rem; }
        .pass { color: var(--pass); }
        .fail { color: var(--fail); }
        table {
            width: 100%;
            border-collapse: collapse;
            background: var(--card);
            border-radius: 0.5rem;
            overflow: hidden;
        }
        th, td {
            padding: 0.75rem 1rem;
            text-align: left;
            border-bottom: 1px solid var(--bg);
        }
        th { background: #334155; font-weight: 600; }
        tr:last-child td { border-bottom: none; }
        .status {
            display: inline-block;
            padding: 0.25rem 0.75rem;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 600;
        }
        .status.pass { background: rgba(34, 197, 94, 0.2); color: var(--pass); }
        .status.fail { background: rgba(239, 68, 68, 0.2); color: var(--fail); }
        .status.partial { background: rgba(251, 191, 36, 0.2); color: #fbbf24; }
        .status.skip { background: rgba(148, 163, 184, 0.2); color: var(--muted); }
        .section-header td {
            padding-top: 1.5rem;
            font-weight: 600;
            color: var(--muted);
            text-transform: uppercase;
            letter-spacing: 0.05em;
            font-size: 0.875rem;
            border-bottom: none;
        }
        code {
            background: var(--bg);
            padding: 0.125rem 0.375rem;
            border-radius: 0.25rem;
            font-size: 0.875rem;
        }
        code.at { border-left: 3px solid var(--pass); }
        code.ahead { border-left: 3px solid #60a5fa; }
        code.behind { border-left: 3px solid #fbbf24; }
        .classification-summary {
            color: var(--muted);
            font-size: 0.875rem;
            margin-bottom: 2rem;
        }
        .classification-summary .count { font-weight: 600; }
        .classification-summary .count.at { color: var(--pass); }
        .classification-summary .count.ahead { color: #60a5fa; }
        .classification-summary .count.behind { color: #fbbf24; }
        h2 { margin: 2rem 0 1rem; color: var(--muted); font-size: 1rem; text-transform: uppercase; letter-spacing: 0.05em; }
        a { color: #60a5fa; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .matrix { margin-bottom: 2rem; }
        .matrix th, .matrix td { text-align: center; min-width: 80px; }
        .matrix td:first-child { text-align: left; }
        .matrix .status { font-size: 0.875rem; }
        .cell.none { color: var(--muted); }
        .matrix .version-tag {
            font-size: 0.6rem;
            vertical-align: super;
            margin-left: 0.125rem;
            opacity: 0.85;
        }
        .matrix .version-tag.at { color: var(--pass); }
        .matrix .version-tag.ahead { color: #60a5fa; }
        .matrix .version-tag.behind { color: #fbbf24; }
        .matrix-link { color: inherit; text-decoration: none; }
        .matrix-link:hover { text-decoration: none; opacity: 0.85; }
        tr:target { background: rgba(96, 165, 250, 0.15); }
    </style>
</head>
<body>
    <div class="container">
        <h1>MoQT Interop Test Results</h1>
HEADER

    cat >> "$OUTPUT_FILE" << EOF
        <p class="meta"><a href="../index.html">&larr; All Runs</a> | Generated: $TIMESTAMP | Interop target: <code>$TARGET_VERSION</code></p>

        <div class="summary">
            <div class="stat">
                <div class="stat-value">$TOTAL</div>
                <div class="stat-label">Total Runs</div>
            </div>
            <div class="stat">
                <div class="stat-value pass">$PASSED</div>
                <div class="stat-label">Passed</div>
            </div>
            <div class="stat">
                <div class="stat-value fail">$FAILED</div>
                <div class="stat-label">Failed</div>
            </div>
$([ "$SKIPPED_COUNT" -gt 0 ] && cat << SKIPSTAT
            <div class="stat">
                <div class="stat-value" style="color: var(--muted);">$SKIPPED_COUNT</div>
                <div class="stat-label">Skipped</div>
            </div>
SKIPSTAT
)
        </div>
        <p class="classification-summary">
            Version breakdown:
            <span class="count at">$AT_TARGET</span> at target &middot;
            <span class="count ahead">$AHEAD</span> ahead &middot;
            <span class="count behind">$BEHIND</span> behind
        </p>

        <h2>Interop Matrix</h2>
        <table class="matrix">
            <thead>
                <tr>
                    <th>Client ↓ / Relay →</th>
EOF

    # Matrix header row (relay names)
    for relay in $RELAYS; do
        echo "                    <th>$relay</th>" >> "$OUTPUT_FILE"
    done

    cat >> "$OUTPUT_FILE" << 'MATRIXHEAD'
                </tr>
            </thead>
            <tbody>
MATRIXHEAD

    # Matrix body (one row per client, aggregating all endpoints per pair)
    for client in $CLIENTS; do
        echo "                <tr><td><strong>$client</strong></td>" >> "$OUTPUT_FILE"
        for relay in $RELAYS; do
            # Get all modes for this (client, relay) pair
            local modes
            modes=$(jq -r --arg c "$client" --arg r "$relay" \
                '.runs[] | select(.client == $c and .relay == $r) | .mode' "$SUMMARY_FILE")

            if [ -z "$modes" ]; then
                echo "                    <td><span class=\"cell none\">-</span></td>" >> "$OUTPUT_FILE"
                continue
            fi

            # Get the negotiated version and classification for this pair
            local pair_version pair_classification version_tag=""
            pair_version=$(jq -r --arg c "$client" --arg r "$relay" \
                '[.runs[] | select(.client == $c and .relay == $r) | .version] | unique | .[0] // ""' "$SUMMARY_FILE")
            if [ -n "$pair_version" ]; then
                pair_classification=$(jq -r --arg c "$client" --arg r "$relay" \
                    '[.runs[] | select(.client == $c and .relay == $r) | .classification] | unique | .[0] // ""' "$SUMMARY_FILE")
                # Strip "draft-" prefix for compact display
                local short_version="${pair_version#draft-}"
                version_tag="<span class=\"version-tag ${pair_classification}\" title=\"Expected negotiated version: ${pair_version}\">${short_version}</span>"
            fi

            local anchor_id="detail-${client}_to_${relay}"

            # Aggregate TAP results across all endpoints for this pair
            local agg_passed=0 agg_failed=0 agg_total=0 any_parsed=false
            local all_skipped=true any_skipped=false
            while IFS= read -r mode; do
                [ -z "$mode" ] || [ "$mode" = "null" ] && continue
                # Check if this mode was skipped
                local mode_status
                mode_status=$(jq -r --arg c "$client" --arg r "$relay" --arg m "$mode" \
                    '[.runs[] | select(.client == $c and .relay == $r and .mode == $m) | .status] | .[0] // ""' "$SUMMARY_FILE")
                if [ "$mode_status" = "skip" ]; then
                    any_skipped=true
                    continue
                fi
                all_skipped=false
                local log_file="$RESULTS_DIR/${client}_to_${relay}_${mode}.log"
                if parse_tap_file "$log_file" && [ "$TAP_TOTAL" -gt 0 ]; then
                    agg_passed=$((agg_passed + TAP_PASSED))
                    agg_failed=$((agg_failed + TAP_FAILED))
                    agg_total=$((agg_total + TAP_TOTAL))
                    any_parsed=true
                fi
            done <<< "$modes"

            if [ "$all_skipped" = true ] && [ "$any_skipped" = true ]; then
                echo "                    <td><a href=\"#${anchor_id}\" class=\"matrix-link\"><span class=\"status skip\" title=\"Docker image unavailable\">SKIP</span>${version_tag}</a></td>" >> "$OUTPUT_FILE"
            elif [ "$any_parsed" = true ] && [ "$agg_total" -gt 0 ]; then
                if [ "$agg_failed" -eq 0 ]; then
                    echo "                    <td><a href=\"#${anchor_id}\" class=\"matrix-link\"><span class=\"status pass\">$agg_passed/$agg_total</span>${version_tag}</a></td>" >> "$OUTPUT_FILE"
                elif [ "$agg_passed" -eq 0 ]; then
                    echo "                    <td><a href=\"#${anchor_id}\" class=\"matrix-link\"><span class=\"status fail\">$agg_passed/$agg_total</span>${version_tag}</a></td>" >> "$OUTPUT_FILE"
                else
                    echo "                    <td><a href=\"#${anchor_id}\" class=\"matrix-link\"><span class=\"status partial\">$agg_passed/$agg_total</span>${version_tag}</a></td>" >> "$OUTPUT_FILE"
                fi
            else
                echo "                    <td><span class=\"cell none\">-</span></td>" >> "$OUTPUT_FILE"
            fi
        done
        echo "                </tr>" >> "$OUTPUT_FILE"
    done

    cat >> "$OUTPUT_FILE" << 'MATRIXFOOT'
            </tbody>
        </table>

        <h2>Detailed Results</h2>
        <table>
            <thead>
                <tr>
                    <th>Client</th>
                    <th>Relay</th>
                    <th>Version</th>
                    <th>Transport</th>
                    <th>Tests</th>
                    <th>Log</th>
                </tr>
            </thead>
            <tbody>
MATRIXFOOT

    # Track which (client, relay) pairs have had their anchor emitted
    _emitted_anchors=""

    # Helper to emit rows for a given classification group
    emit_detail_rows() {
        local class="$1"
        local label="$2"
        local runs_json="$3"

        # Get runs for this classification
        local class_runs
        class_runs=$(jq -c --arg cl "$class" \
            'map(select(. == $cl)) | length' <<< "$runs_json")
        [ "$class_runs" -eq 0 ] && return

        # Emit section header
        echo "                <tr class=\"section-header\"><td colspan=\"6\">$label</td></tr>" >> "$OUTPUT_FILE"

        # Emit each run in this group
        while IFS= read -r run; do
            local client=$(echo "$run" | jq -r '.client')
            local relay=$(echo "$run" | jq -r '.relay')
            local version=$(echo "$run" | jq -r '.version')
            local mode=$(echo "$run" | jq -r '.mode')
            local status=$(echo "$run" | jq -r '.status')
            local classification=$(echo "$run" | jq -r '.classification')

            local log_file="$RESULTS_DIR/${client}_to_${relay}_${mode}.log"
            local test_display

            # Build tooltip for version badge
            local version_tooltip
            case "$classification" in
                at)    version_tooltip="At interop target ($TARGET_VERSION)" ;;
                ahead) version_tooltip="Ahead of interop target ($TARGET_VERSION)" ;;
                behind) version_tooltip="Behind interop target ($TARGET_VERSION)" ;;
                *)     version_tooltip="" ;;
            esac

            if parse_tap_file "$log_file" && [ "$TAP_TOTAL" -gt 0 ]; then
                local passed=$TAP_PASSED
                local failed=$TAP_FAILED
                local total=$TAP_TOTAL

                if [ "$failed" -eq 0 ]; then
                    test_display="<span class=\"status pass\">$passed/$total</span>"
                elif [ "$passed" -eq 0 ]; then
                    test_display="<span class=\"status fail\">$passed/$total</span>"
                else
                    test_display="<span class=\"status partial\">$passed/$total</span>"
                fi
            else
                local status_upper
                status_upper=$(echo "$status" | tr '[:lower:]' '[:upper:]')
                test_display="<span class=\"status $status\">$status_upper</span>"
            fi

            # Add anchor id on the first detail row for each (client, relay) pair
            local anchor_key="${client}_to_${relay}"
            local row_id_attr=""
            case ",$_emitted_anchors," in
                *",$anchor_key,"*) ;;
                *)
                    row_id_attr=" id=\"detail-${anchor_key}\""
                    _emitted_anchors="${_emitted_anchors:+$_emitted_anchors,}$anchor_key"
                    ;;
            esac

            local log_link
            if [ "$status" = "skip" ]; then
                local skip_reason
                skip_reason=$(echo "$run" | jq -r '.skip_reason // "image unavailable"')
                log_link="<span style=\"color: var(--muted);\" title=\"$skip_reason\">n/a</span>"
            else
                log_link="<a href=\"${client}_to_${relay}_${mode}.log\">log</a>"
            fi
            echo "<tr${row_id_attr}><td>$client</td><td>$relay</td><td><code class=\"$classification\" title=\"$version_tooltip\">$version</code></td><td>$mode</td><td>$test_display</td><td>$log_link</td></tr>" >> "$OUTPUT_FILE"
        done < <(jq -c --arg cl "$class" \
            '.target_version as $tv |
            ($tv | ltrimstr("draft-") | tonumber) as $tn |
            .runs[] |
            . + {classification: (.classification // (
                (.version | ltrimstr("draft-") | tonumber) as $vn |
                if $vn == $tn then "at"
                elif $vn > $tn then "ahead"
                else "behind" end
            ))} |
            select(.classification == $cl)' "$SUMMARY_FILE")
    }

    # Precompute all classifications as JSON array for counting
    local all_classes
    all_classes=$(jq "$classify_expr" "$SUMMARY_FILE")

    # Emit groups in order: At Target, Ahead of Target, Behind Target
    emit_detail_rows "at" "At Target" "$all_classes"
    emit_detail_rows "ahead" "Ahead of Target" "$all_classes"
    emit_detail_rows "behind" "Behind Target" "$all_classes"

    cat >> "$OUTPUT_FILE" << 'FOOTER'
            </tbody>
        </table>
    </div>
</body>
</html>
FOOTER

    echo "Detail report generated: $OUTPUT_FILE"
}

#############################################################################
# Main
#############################################################################

# Always generate index
generate_index

if [ "$INDEX_ONLY" = true ]; then
    exit 0
fi

# Generate detail for all runs (or just specified one)
if [ -n "${1:-}" ] && [ -d "${1:-}" ]; then
    # Specific directory requested
    generate_detail "$1"
else
    # Generate for all runs that have summary.json (OS-portable)
    # Use while read to handle paths with spaces safely
    if [[ "$(uname)" == "Darwin" ]]; then
        find "$RESULTS_BASE" -maxdepth 1 -type d ! -path "$RESULTS_BASE" -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn | cut -d' ' -f2-
    else
        find "$RESULTS_BASE" -maxdepth 1 -type d ! -path "$RESULTS_BASE" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
    fi | while IFS= read -r d; do
        if [ -f "$d/summary.json" ]; then
            generate_detail "$d"
        fi
    done
fi

# Open index in browser on macOS
# Note: Linux has /usr/bin/open (openvt) which is not a browser launcher and
# fails in headless CI environments, so restrict this to macOS only.
if [[ "$(uname)" == "Darwin" ]] && command -v open &> /dev/null; then
    echo "Opening in browser..."
    open "$RESULTS_BASE/index.html"
fi

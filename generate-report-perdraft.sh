#!/bin/bash
# generate-report-perdraft.sh - Per-draft interop matrix report (POC, ADR 003).
#
# Parallel to generate-report.sh. Renders ONE page per draft version, selectable
# from a dropdown, instead of a single negotiated matrix. Each cell shows
# per-transport pills (QUIC / WT / LOCAL), a blank for no pairing, or SKIP for an
# explicitly skipped pairing. No version superscript, no at/ahead/behind target.
#
# Data source: a results dir (summary.json + *.log), defaulting to the newest
# under results/. Works with both the negotiated summary (runs[].version/.mode)
# and the pinned summary (runs[].draft/.transport).
#
# Usage: ./generate-report-perdraft.sh [results-dir] [-o output.html]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/tap-parser.sh"

RESULTS_DIR="" OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTPUT="$2"; shift 2 ;;
    *)  RESULTS_DIR="$1"; shift ;;
  esac
done
if [ -z "$RESULTS_DIR" ]; then
  RESULTS_DIR=$(find "$SCRIPT_DIR/results" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
fi
[ -f "$RESULTS_DIR/summary.json" ] || { echo "No summary.json in '$RESULTS_DIR'" >&2; exit 1; }
[ -z "$OUTPUT" ] && OUTPUT="$RESULTS_DIR/report-perdraft.html"
SUMMARY="$RESULTS_DIR/summary.json"

# Family map (id -> family // id) for collapsing same-family registrations.
CONFIG="$SCRIPT_DIR/implementations.json"
FAMILY_MAP=$(jq -c '[.implementations | to_entries[]
                     | {key: .key, value: (.value.family // .key)}] | from_entries' \
             "$CONFIG" 2>/dev/null || echo '{}')

# Normalize: add cfam/rfam (family of client/relay); draft/transport from either model.
norm() { jq -c --argjson fam "$FAMILY_MAP" '.runs | map({
           client, relay,
           cfam: ($fam[.client] // .client),
           rfam: ($fam[.relay]  // .relay),
           draft: (.draft // .version),
           transport: (.transport // .mode),
           status})' "$SUMMARY"; }
RUNS=$(norm)

drafts()  { jq -r 'map(.draft) | unique | sort_by(ltrimstr("draft-")|tonumber) | .[]' <<<"$RUNS"; }
clients() { jq -r 'map(.cfam)  | unique | .[]' <<<"$RUNS"; }
relays()  { jq -r 'map(.rfam)  | unique | .[]' <<<"$RUNS"; }

# transport short label
tlabel() { case "$1" in docker) echo LOCAL;; remote-quic|quic) echo QUIC;; remote-webtransport|webtransport) echo WT;; *) echo "${1:0:4}" | tr a-z A-Z;; esac; }

# Render the stacked pills for one (client-family, relay-family, draft).
# Aggregates all member registrations (transport/draft variants) of the families.
# Echoes HTML, or "" if there is no pairing at this draft.
cell_html() {
  local c="$1" r="$2" d="$3"
  local rows; rows=$(jq -c --arg c "$c" --arg r "$r" --arg d "$d" \
      'map(select(.cfam==$c and .rfam==$r and .draft==$d))' <<<"$RUNS")
  [ "$(jq 'length' <<<"$rows")" -eq 0 ] && return  # no pairing -> blank

  local out="" n; n=$(jq 'length' <<<"$rows")
  for i in $(seq 0 $((n-1))); do
    local rawc rawr mode status label
    rawc=$(jq -r ".[$i].client" <<<"$rows")
    rawr=$(jq -r ".[$i].relay"  <<<"$rows")
    mode=$(jq -r ".[$i].transport" <<<"$rows")
    status=$(jq -r ".[$i].status" <<<"$rows")
    label=$(tlabel "$mode")
    if [ "$status" = "skip" ]; then
      out+="<span class=\"pill skip\" title=\"explicitly skipped\">${label}: SKIP</span>"
      continue
    fi
    local log="$RESULTS_DIR/${rawc}_to_${rawr}_${mode}.log"
    if parse_tap_file "$log" && [ "$TAP_TOTAL" -gt 0 ]; then
      local cls=partial; [ "$TAP_FAILED" -eq 0 ] && cls=pass; [ "$TAP_PASSED" -eq 0 ] && cls=fail
      out+="<span class=\"pill ${cls}\">${label}: ${TAP_PASSED}/${TAP_TOTAL}</span>"
    else
      local cls=pass; [ "$status" != "pass" ] && cls=fail
      out+="<span class=\"pill ${cls}\">${label}: ${status}</span>"
    fi
  done
  echo "$out"
}

mapfile -t DRAFTS < <(drafts)
mapfile -t CLIENTS < <(clients)
mapfile -t RELAYS < <(relays)
TS=$(jq -r '.timestamp // "unknown"' "$SUMMARY")

{
cat <<HEAD
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MoQT Interop — per-draft matrix</title>
<style>
:root{--pass:#22c55e;--fail:#ef4444;--partial:#fbbf24;--bg:#0f172a;--card:#1e293b;--text:#f1f5f9;--muted:#94a3b8;}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--text);padding:2rem;line-height:1.5}
.container{max-width:1400px;margin:0 auto}
h1{margin-bottom:.25rem}.meta{color:var(--muted);margin-bottom:1.5rem}
.controls{margin-bottom:1.5rem}
select{background:var(--card);color:var(--text);border:1px solid #334155;border-radius:.4rem;padding:.5rem .75rem;font-size:1rem}
table{border-collapse:collapse;background:var(--card);border-radius:.5rem;overflow:hidden}
th,td{padding:.55rem .6rem;text-align:center;border-bottom:1px solid var(--bg);border-right:1px solid var(--bg);font-size:.8rem;white-space:nowrap}
th{background:#334155;font-weight:600}td:first-child,th:first-child{text-align:left;position:sticky;left:0;background:#334155}
.pill{display:inline-block;padding:.1rem .45rem;margin:.1rem;border-radius:9999px;font-size:.68rem;font-weight:600}
td .pill{display:block;width:max-content;margin:.18rem auto;text-align:left}
.pill.pass{background:rgba(34,197,94,.2);color:var(--pass)}
.pill.fail{background:rgba(239,68,68,.2);color:var(--fail)}
.pill.partial{background:rgba(251,191,36,.2);color:var(--partial)}
.pill.skip{background:rgba(148,163,184,.2);color:var(--muted)}
.blank{color:#475569}
.page{display:none}.page.active{display:block}
.legend{margin-top:1rem;color:var(--muted);font-size:.8rem}
</style></head><body><div class="container">
<h1>MoQT Interop — per-draft matrix <span style="font-size:.6em;color:var(--muted)">(POC)</span></h1>
<p class="meta">Generated: ${TS} &middot; one matrix per draft (negotiated → pinned)</p>
<div class="controls"><label>Draft: <select id="draftSel" onchange="showDraft(this.value)">
HEAD

# Latest draft first so it is the default landing view; older drafts follow.
for ((i=${#DRAFTS[@]}-1; i>=0; i--)); do
  echo "<option value=\"${DRAFTS[$i]}\">${DRAFTS[$i]}</option>"
done
echo "</select></label></div>"

for d in "${DRAFTS[@]}"; do
  echo "<div class=\"page\" data-draft=\"$d\"><table><thead><tr><th>Client ↓ / Relay →</th>"
  for r in "${RELAYS[@]}"; do echo "<th>$r</th>"; done
  echo "</tr></thead><tbody>"
  for c in "${CLIENTS[@]}"; do
    echo "<tr><td><strong>$c</strong></td>"
    for r in "${RELAYS[@]}"; do
      html=$(cell_html "$c" "$r" "$d")
      if [ -z "$html" ]; then echo "<td><span class=\"blank\">—</span></td>"
      else echo "<td>$html</td>"; fi
    done
    echo "</tr>"
  done
  echo "</tbody></table></div>"
done

cat <<'FOOT'
<p class="legend">Pills are per-transport: <span class="pill pass">QUIC 12/12</span> raw QUIC &middot;
<span class="pill pass">WT 12/12</span> WebTransport &middot; <span class="pill pass">LOCAL 12/12</span> docker.
<span class="blank">—</span> = no pairing at this draft &middot; <span class="pill skip">SKIP</span> = explicitly skipped.</p>
</div>
<script>
function showDraft(d){document.querySelectorAll('.page').forEach(p=>p.classList.toggle('active',p.dataset.draft===d));}
document.addEventListener('DOMContentLoaded',()=>{const s=document.getElementById('draftSel');showDraft(s.value);});
</script>
</body></html>
FOOT
} > "$OUTPUT"

echo "Per-draft report: $OUTPUT"

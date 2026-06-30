#!/bin/bash
# generate-report-perdraft.sh - Per-draft interop matrix report (POC, ADR 003).
#
# Parallel to generate-report.sh. Renders ONE page per draft version, selectable
# from a dropdown, instead of a single negotiated matrix. Each cell shows two
# pills (QUIC and H3/WT) — protocol correctness per transport — with a muted "—"
# where there is no version/transport registration. No version superscript, no
# at/ahead/behind target.
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
norm() { jq -c --argjson fam "$FAMILY_MAP" '.runs | map(
           (.transport // .mode) as $m |
           {client, relay,
            cfam: ($fam[.client] // .client),
            rfam: ($fam[.relay]  // .relay),
            draft: (.draft // .version),
            mode: $m,
            t: (if   ($m=="QUIC" or $m=="quic" or $m=="remote-quic") then "QUIC"
                elif ($m=="WT" or $m=="webtransport" or $m=="remote-webtransport" or $m=="docker") then "WT"
                else ($m|ascii_upcase) end),
            source: (.source // (if $m=="docker" then "local"
                                 elif ($m|startswith("remote")) then "remote" else "local" end)),
            view: (.view // "draft"),
            status, passed, total, url, error})' "$SUMMARY"; }
RUNS=$(norm)

# Drafts to render. Skip non-interop drafts (default 15/17 — nobody targets them);
# override with SKIP_DRAFTS="draft-NN draft-MM".
SKIP_DRAFTS="${SKIP_DRAFTS:-draft-15 draft-17}"
drafts() {
  jq -r 'map(select(.view=="draft").draft) | unique | sort_by(ltrimstr("draft-")|tonumber) | .[]' <<<"$RUNS" \
    | while IFS= read -r d; do [[ " $SKIP_DRAFTS " == *" $d "* ]] || echo "$d"; done
}
clients() { jq -r 'map(.cfam)  | unique | .[]' <<<"$RUNS"; }
relays()  { jq -r 'map(.rfam)  | unique | .[]' <<<"$RUNS"; }
# relays that expose a live endpoint (have any open-view runs)
open_relays() { jq -r 'map(select(.view=="open").rfam) | unique | .[]' <<<"$RUNS"; }
has_open() { [ -n "$(jq -r 'map(select(.view=="open")) | length' <<<"$RUNS" | grep -v '^0$')" ]; }

# Render the two transport pills (QUIC, H3/WT) for a set of rows, preferring the
# given source ($2 = local|remote). Always emits both slots for uniform height.
render_pills() {
  local rows="$1" prefer="$2"
  local out="" T label
  for T in QUIC WT; do
    [ "$T" = "WT" ] && label="H3/WT" || label="QUIC"
    local run
    # Prefer a run that produced a real result in the preferred source, then any
    # preferred-source run, then anything — so a working preferred beats a broken one.
    run=$(jq -c --arg t "$T" --arg pref "$prefer" '
        (map(select(.t==$t))) as $m |
        (($m | map(select(.status=="pass" or .status=="fail" or .status=="partial"))
              | (map(select(.source==$pref))[0] // .[0]))
         // ($m | map(select(.source==$pref))[0])
         // $m[0]) // empty' <<<"$rows")
    if [ -z "$run" ] || [ "$run" = "null" ]; then
      out+="<span class=\"pill none\" title=\"no version/transport registration\"><span class=\"plabel\">${label}</span><span class=\"pval\">&mdash;</span></span>"
      continue
    fi

    local status passed total source cls val title url err loc
    status=$(jq -r '.status' <<<"$run")
    passed=$(jq -r '.passed // empty' <<<"$run")
    total=$(jq -r '.total // empty' <<<"$run")
    source=$(jq -r '.source' <<<"$run")
    url=$(jq -r '.url // empty' <<<"$run")
    err=$(jq -r '.error // empty' <<<"$run")
    [ "$source" = "remote" ] && loc="$url" || loc="local (docker)"
    if [ -z "$total" ] && [ "$status" != "skip" ] && [ "$status" != "conn-fail" ]; then
      local rc rr m
      rc=$(jq -r '.client' <<<"$run"); rr=$(jq -r '.relay' <<<"$run"); m=$(jq -r '.mode' <<<"$run")
      if parse_tap_file "$RESULTS_DIR/${rc}_to_${rr}_${m}.log" && [ "$TAP_TOTAL" -gt 0 ]; then
        passed=$TAP_PASSED; total=$TAP_TOTAL
      fi
    fi
    if [ "$status" = "skip" ]; then
      cls=skip; val="SKIP"; title="skipped via configuration"
    elif [ "$status" = "conn-fail" ]; then
      cls=conn; val="&#8856;"; title="${url}&#10;${err:-failed to connect}"
    elif [ -n "$total" ] && [ "$total" -gt 0 ]; then
      cls=partial; [ "$passed" = "$total" ] && cls=pass; [ "$passed" = "0" ] && cls=fail
      val="${passed}/${total}"; title="$loc"
    else
      cls=fail; val="$status"; title="$loc"
    fi
    out+="<span class=\"pill ${cls}\" title=\"${title}\"><span class=\"plabel\">${label}</span><span class=\"pval ${cls}\">${val}</span></span>"
  done
  echo "$out"
}

# Per-draft cell (version-confined): prefer the LOCAL recipe; remote is fallback.
cell_html() {
  local c="$1" r="$2" d="$3"
  local rows; rows=$(jq -c --arg c "$c" --arg r "$r" --arg d "$d" \
      'map(select(.cfam==$c and .rfam==$r and .draft==$d and .view=="draft"))' <<<"$RUNS")
  render_pills "$rows" local
}

# Open Relay Interop cell: a mutually-negotiated-draft badge plus the live-endpoint
# (remote) transport pills. Blank when this pair has no live result.
cell_open() {
  local c="$1" r="$2"
  local rows; rows=$(jq -c --arg c "$c" --arg r "$r" \
      'map(select(.cfam==$c and .rfam==$r and .view=="open"))' <<<"$RUNS")
  [ "$(jq 'length' <<<"$rows")" -eq 0 ] && { echo "<span class=\"blank\">&mdash;</span>"; return; }
  local neg; neg=$(jq -r 'map(.draft)|unique|.[0] // empty' <<<"$rows")
  local medal="${MEDAL[$neg]:-old}" emoji=""
  case "$medal" in
    cur)  emoji="&#129351;" ;;  # 🥇
    near) emoji="&#129352;" ;;  # 🥈
    back) emoji="&#129353;" ;;  # 🥉
  esac
  echo "<div class=\"opencell\"><span class=\"negdraft age-${medal}\" title=\"mutually negotiated ${neg}\"><span class=\"dnum\">${neg#draft-}</span><span class=\"dmedal\">${emoji}</span></span><span class=\"openpills\">$(render_pills "$rows" remote)</span></div>"
}

mapfile -t DRAFTS < <(drafts)
mapfile -t CLIENTS < <(clients)
mapfile -t RELAYS < <(relays)
TS=$(jq -r '.timestamp // "unknown"' "$SUMMARY")

# Draft recency by rank (latest = green, then light-yellow, amber, older = faded).
# Dynamic: when a newer draft appears it becomes green and the rest shift down.
declare -A MEDAL
__mi=0
while IFS= read -r __d; do
  case $__mi in 0) MEDAL[$__d]=cur ;; 1) MEDAL[$__d]=near ;; 2) MEDAL[$__d]=back ;; *) MEDAL[$__d]=old ;; esac
  __mi=$((__mi + 1))
done < <(jq -r 'map(.draft) | unique | sort_by(ltrimstr("draft-")|tonumber) | reverse | .[]' <<<"$RUNS" \
          | while IFS= read -r __x; do [[ " $SKIP_DRAFTS " == *" $__x "* ]] || echo "$__x"; done)

{
cat <<HEAD
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MoQT Interop — per-draft matrix</title>
<style>
:root{--pass:#22c55e;--fail:#ef4444;--partial:#fbbf24;--bg:#0f172a;--card:#1e293b;--text:#aebfd9;--muted:#8696ad;--accent:#7fa6cf;}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--text);padding:2rem;line-height:1.5}
.container{max-width:1400px;margin:0 auto}
h1{margin-bottom:.25rem}.meta{color:var(--muted);margin-bottom:1.5rem}
.controls{margin-bottom:1.5rem;display:flex;gap:1.75rem;align-items:center}
select{background:var(--card);color:var(--text);border:1px solid #334155;border-radius:.4rem;padding:.5rem .75rem;font-size:1rem}
table{border-collapse:collapse;background:var(--card);border-radius:.5rem;overflow:hidden}
th,td{padding:.55rem .6rem;text-align:center;border-bottom:1px solid var(--bg);border-right:1px solid var(--bg);font-size:.8rem;white-space:nowrap}
th{background:#334155;font-weight:700;font-size:.95rem}
td:first-child,th:first-child{text-align:left;position:sticky;left:0;background:#334155}
td:first-child{font-size:.95rem;font-weight:700}
.pill{display:inline-block;padding:.12rem .55rem;margin:.1rem;border-radius:9999px;font-size:.68rem;font-weight:600;background:rgba(148,163,184,.14)}
td .pill{display:flex;justify-content:space-between;align-items:baseline;width:6.4rem;margin:.16rem auto;gap:.5rem;cursor:default}
.pill.pass{background:rgba(34,197,94,.16);color:var(--pass)}
.pill.fail{background:rgba(239,68,68,.16);color:var(--fail)}
.pill.partial{background:rgba(251,191,36,.18);color:var(--partial)}
.pill.skip{background:rgba(148,163,184,.14);color:var(--muted)}
.pill.none{background:rgba(148,163,184,.06);color:#5a6680}
.pill.conn{background:rgba(148,163,184,.07);color:#79859b}
.plabel{font-weight:600}
.pval{font-weight:700}
.pval.pass{color:var(--pass)}
.pval.fail{color:var(--fail)}
.pval.partial{color:var(--partial)}
.pval.skip{color:var(--muted)}
.pval.conn{color:#79859b}
.blank{color:#475569}
.opencell{display:flex;align-items:stretch;gap:.55rem;justify-content:flex-start}
.openpills{display:flex;flex-direction:column}
.openpills .pill{margin:.12rem 0}
/* Draft recency badge: medal emoji + draft number, tinted by rank. */
.negdraft{display:inline-flex;flex-direction:column;align-items:center;justify-content:center;gap:.08rem;padding:.16rem .28rem;margin:.16rem 0;border-radius:.35rem;border:1px solid #3a516e;background:rgba(127,166,207,.16);color:var(--accent);flex:none;line-height:1}
.negdraft .dnum{font-size:.78rem;font-weight:800}
.negdraft .dmedal{font-size:.56rem;opacity:.9}
.negdraft.age-cur{background:rgba(34,197,94,.18);color:#34d399;border-color:#1f7a48}
.negdraft.age-near{background:rgba(253,224,71,.16);color:#fde047;border-color:#a3892a}
.negdraft.age-back{background:rgba(245,158,11,.16);color:#f59e0b;border-color:#a35c10}
.negdraft.age-old{background:rgba(148,163,184,.16);color:var(--muted);border-color:#3a516e}
.openmeta{color:var(--muted);font-size:.82rem;margin:.25rem 0 1rem}
.page{display:none}.page.active{display:block}
.legend{margin-top:1rem;color:var(--muted);font-size:.8rem}
</style></head><body><div class="container">
<h1>MoQT Interop <span style="font-size:.6em;color:var(--muted)">(POC)</span></h1>
<p class="meta">Generated: ${TS}</p>
<div class="controls"><label>View: <select id="viewSel" onchange="showView(this.value)">
<option value="draft">Per-draft Interop</option>
HEAD

has_open && echo "<option value=\"open\">Open Relay Interop</option>"
echo "</select></label> <label id=\"draftLabel\">Draft: <select id=\"draftSel\" onchange=\"showDraft(this.value)\">"
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
      echo "<td>$(cell_html "$c" "$r" "$d")</td>"
    done
    echo "</tr>"
  done
  echo "</tbody></table></div>"
done

# Open Relay Interop page: clients × relays-with-live-endpoints; mutually negotiated draft.
mapfile -t OPEN_RELAYS < <(open_relays)
if [ "${#OPEN_RELAYS[@]}" -gt 0 ]; then
  echo "<div class=\"page\" data-draft=\"open\"><p class=\"openmeta\">Live/public endpoints &mdash; mutually <strong>negotiated</strong> draft (no version confinement), complementing the confined per-draft matrix. The badge is the negotiated draft.</p><table><thead><tr><th>Client ↓ / Relay →</th>"
  for r in "${OPEN_RELAYS[@]}"; do echo "<th>$r</th>"; done
  echo "</tr></thead><tbody>"
  for c in "${CLIENTS[@]}"; do
    echo "<tr><td><strong>$c</strong></td>"
    for r in "${OPEN_RELAYS[@]}"; do echo "<td>$(cell_open "$c" "$r")</td>"; done
    echo "</tr>"
  done
  echo "</tbody></table></div>"
fi

cat <<'FOOT'
<p class="legend"><strong>draft-NN</strong> tabs: version-confined, local preferred &middot;
<strong>Open Relay Interop</strong>: live endpoints at their <span class="negdraft" style="display:inline-block;margin:0">negotiated</span> draft &nbsp;|&nbsp;
<span class="pill conn"><span class="pval conn">&#8856;</span></span> unreachable &middot;
<span class="pill skip"><span class="pval skip">SKIP</span></span> skipped &middot;
<strong>&mdash;</strong> not registered &middot; <span style="opacity:.7">hover for endpoint</span></p>
</div>
<script>
function showPage(id){document.querySelectorAll('.page').forEach(p=>p.classList.toggle('active',p.dataset.draft===id));}
function showDraft(d){showPage(d);}
function showView(v){
  var dl=document.getElementById('draftLabel');
  if(v==='open'){ if(dl) dl.style.display='none'; showPage('open'); }
  else { if(dl) dl.style.display=''; showPage(document.getElementById('draftSel').value); }
}
document.addEventListener('DOMContentLoaded',function(){showView(document.getElementById('viewSel').value);});
</script>
</body></html>
FOOT
} > "$OUTPUT"

echo "Per-draft report: $OUTPUT"

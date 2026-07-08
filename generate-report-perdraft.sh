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
            status, passed, total, url, error, log})' "$SUMMARY"; }
RUNS=$(norm)

# Render EVEN interop drafts only — odd drafts (15/17/19/…) are not interop
# targets. Suppress additional drafts explicitly via SKIP_DRAFTS.
SKIP_DRAFTS="${SKIP_DRAFTS:-}"
keep_draft() {
  local n="${1#draft-}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  [ $((n % 2)) -eq 0 ] && [[ " $SKIP_DRAFTS " != *" $1 "* ]]
}
drafts() {
  jq -r 'map(select(.view=="draft").draft) | unique | sort_by(ltrimstr("draft-")|tonumber) | .[]' <<<"$RUNS" \
    | while IFS= read -r d; do keep_draft "$d" && echo "$d"; done
}
clients() { jq -r 'map(.cfam)  | unique | .[]' <<<"$RUNS"; }
relays()  { jq -r 'map(.rfam)  | unique | .[]' <<<"$RUNS"; }
# relays that expose a live endpoint (any real remote run, or a seed open-view run)
open_relays() { jq -r 'map(select(.view=="open" or .source=="remote").rfam) | unique | .[]' <<<"$RUNS"; }
has_open() { [ -n "$(jq -r 'map(select(.view=="open" or .source=="remote")) | length' <<<"$RUNS" | grep -v '^0$')" ]; }

# Compact aggregate line for one page. $1 = a draft ("draft-16") or "open".
# Counts result runs by status (dedup per client/relay/transport, local preferred).
agg_line() {
  jq -r --arg d "$1" '
    [ .[] | if $d=="open" then select(.view=="open" or .source=="remote") else select((.view // "draft")=="draft" and .draft==$d) end ]
    | group_by([.cfam, .rfam, .t])
    | map( (map(select(.status=="pass" or .status=="fail" or .status=="partial"))
            | (map(select(.source=="local"))[0] // .[0])) // .[0] )
    | (map(select(.status=="pass"))|length) as $p
    | (map(select(.status=="partial"))|length) as $pa
    | (map(select(.status=="fail"))|length) as $f
    | (map(select(.status=="skip"))|length) as $s
    | (map(select(.status=="conn-fail"))|length) as $c
    | (map(select(.status=="error" or .status=="timeout"))|length) as $e
    | "<div class=\"agg\"><b>\($p+$pa+$f+$s+$c+$e)</b> results &middot; "
      + "<span class=\"apass\">\($p) pass</span>"
      + (if $pa>0 then " &middot; <span class=\"apart\">\($pa) partial</span>" else "" end)
      + (if $f>0  then " &middot; <span class=\"afail\">\($f) fail</span>" else "" end)
      + (if $s>0  then " &middot; <span class=\"askip\">\($s) skip</span>" else "" end)
      + (if $c>0  then " &middot; <span class=\"aconn\">\($c) unreachable</span>" else "" end)
      + (if $e>0  then " &middot; <span class=\"aerr\">\($e) did-not-run</span>" else "" end)
      + "</div>"
  ' <<<"$RUNS"
}

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

    local status passed total source cls val title url err loc logf rmt pill
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
    elif [ "$status" = "error" ] || [ "$status" = "timeout" ]; then
      cls=err; val="&#9888;"; title="did not run: container/startup failure (image or harness &mdash; not an interop result)&#10;${loc}"
    else
      cls=fail; val="$status"; title="$loc"
    fi
    # Clickable: open this test's log (full TAP + any crash output). Remote runs get
    # a provenance dot so live-endpoint results are distinguishable from local docker.
    logf=$(jq -r '.log // empty' <<<"$run")
    rmt=""; [ "$source" = "remote" ] && rmt=" rmt"
    pill="<span class=\"pill ${cls}${rmt}\" title=\"${title}\"><span class=\"plabel\">${label}</span><span class=\"pval ${cls}\">${val}</span></span>"
    if [ -n "$logf" ]; then
      out+="<a class=\"plink\" href=\"${logf}\" target=\"_blank\" rel=\"noopener\">${pill}</a>"
    else
      out+="$pill"
    fi
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

# Open Relay Interop cell: the highest draft that actually interoperated over the
# live (remote) endpoint, plus that draft's transport pills. 100% real remote runs —
# no borrowed/seed data. Blank when this pair has no live result.
cell_open() {
  local c="$1" r="$2"
  local rows; rows=$(jq -c --arg c "$c" --arg r "$r" \
      'map(select(.cfam==$c and .rfam==$r and (.view=="open" or .source=="remote")))' <<<"$RUNS")
  # Prefer the highest draft with a real pass/partial; else the highest draft that
  # produced any real result (a top-draft fail is still informative).
  local neg=""
  if [ "$(jq 'length' <<<"$rows")" -gt 0 ]; then
    neg=$(jq -r '
      (map(select(.status=="pass" or .status=="partial") | .draft)) as $ok
      | (map(select(.status=="pass" or .status=="partial" or .status=="fail") | .draft)) as $any
      | (if ($ok|length)>0 then $ok else $any end)
      | map(select(. != null)) | unique
      | sort_by(ltrimstr("draft-")|tonumber) | last // empty' <<<"$rows")
  fi
  if [ -z "$neg" ] || ! keep_draft "$neg"; then
    # No real live-endpoint interop — faint placeholder, uniform grid.
    echo "<div class=\"opencell\"><span class=\"openpills\">$(render_pills "[]" remote)</span><span class=\"negdraft negblank\" title=\"no live-endpoint interop\">&mdash;</span></div>"
    return
  fi
  # Pills for the chosen (best) draft only.
  local prows; prows=$(jq -c --arg n "$neg" 'map(select(.draft==$n))' <<<"$rows")
  local medal="${MEDAL[$neg]:-old}" emoji=""
  case "$medal" in
    cur)  emoji="&#129351;" ;;  # 🥇
    near) emoji="&#129352;" ;;  # 🥈
    back) emoji="&#129353;" ;;  # 🥉
  esac
  echo "<div class=\"opencell\"><span class=\"openpills\">$(render_pills "$prows" remote)</span><span class=\"negdraft age-${medal}\" title=\"highest interoperable draft ${neg} (live endpoint)\"><span class=\"dnum\">${neg#draft-}</span><span class=\"dmedal\">${emoji}</span></span></div>"
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
          | while IFS= read -r __x; do keep_draft "$__x" && echo "$__x"; done)

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
.controls{margin-bottom:1.25rem;display:flex;gap:1.75rem;align-items:center}
.viewtabs{display:inline-flex;border:1px solid #3a516e;border-radius:.45rem;overflow:hidden}
.vtab{padding:.4rem .9rem;font-size:.9rem;font-weight:600;color:var(--muted);cursor:pointer;user-select:none;background:transparent}
.vtab+.vtab{border-left:1px solid #3a516e}
.vtab:hover{color:var(--text)}
.vtab.active{background:rgba(127,166,207,.18);color:var(--accent)}
.agg{margin:0 0 .8rem;font-size:.85rem;color:var(--muted)}
.agg b{color:var(--text);font-weight:700}
.agg .apass{color:#34d399} .agg .apart{color:#f59e0b} .agg .afail{color:#f87171}
.agg .askip{color:var(--muted)} .agg .aconn{color:#8696ad} .agg .aerr{color:#9aa6ba}
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
/* DNF: container/harness never produced a result (image/startup) — NOT interop fail. */
.pill.err{background:repeating-linear-gradient(45deg,rgba(148,163,184,.10),rgba(148,163,184,.10) 4px,transparent 4px,transparent 8px);color:#9aa6ba;border:1px dashed #3a516e}
.plabel{font-weight:600}
.pval{font-weight:700}
.pval.pass{color:var(--pass)}
.pval.fail{color:var(--fail)}
.pval.partial{color:var(--partial)}
.pval.skip{color:var(--muted)}
.pval.conn{color:#79859b}
.pval.err{color:#9aa6ba}
.blank{color:#475569}
/* Clickable pill -> its test log. display:contents so the <a> doesn't disturb layout. */
.plink{text-decoration:none;color:inherit;display:contents}
.plink .pill{cursor:pointer}
.plink:hover .pill{outline:1px solid var(--accent);outline-offset:-1px}
/* Remote (live-endpoint) provenance dot, top-right of the pill. */
.pill.rmt{position:relative}
.pill.rmt::after{content:"";position:absolute;top:2px;right:2px;width:4px;height:4px;border-radius:50%;background:var(--accent);opacity:.65}
.opencell{display:flex;align-items:center;gap:.55rem;justify-content:flex-end}
.openpills{display:flex;flex-direction:column}
.openpills .pill{margin:.12rem 0}
/* Draft recency badge: medal emoji + draft number, tinted by rank. */
/* Explicit px knobs: padding-top = number→top, .dnum margin-bottom = number→medal,
   padding-bottom = medal→bottom. Tune these freely. */
.negdraft{display:inline-flex;flex-direction:column;align-items:center;padding:4px 4px 9px;margin:.16rem 0;border-radius:.35rem;border:1px solid #3a516e;background:rgba(127,166,207,.16);color:var(--accent);flex:none;line-height:1}
.negdraft .dnum{font-size:13px;font-weight:800;margin-bottom:3px}
.negdraft .dmedal{font-size:13px;line-height:1;display:block}
.negdraft.age-cur{background:rgba(34,197,94,.18);color:#34d399;border-color:#1f7a48}
.negdraft.age-near{background:rgba(253,224,71,.16);color:#fde047;border-color:#a3892a}
.negdraft.age-back{background:rgba(245,158,11,.16);color:#f59e0b;border-color:#a35c10}
.negdraft.age-old{background:rgba(148,163,184,.16);color:var(--muted);border-color:#3a516e}
.negdraft.negblank{background:transparent;color:#475569;border-color:#27344a;font-weight:600}
.openmeta{color:var(--muted);font-size:.82rem;margin:.25rem 0 1rem}
.page{display:none}.page.active{display:block}
.legend{margin-top:1rem;color:var(--muted);font-size:.8rem}
</style></head><body><div class="container">
<h1>MoQT Interop <span style="font-size:.6em;color:var(--muted)">(POC)</span></h1>
<p class="meta">Generated: ${TS}</p>
<div class="controls"><div class="viewtabs"><a id="tab-draft" class="vtab active" onclick="showView('draft')">Per-draft Interop</a>
HEAD

has_open && echo "<a id=\"tab-open\" class=\"vtab\" onclick=\"showView('open')\">Open Relay Interop</a>"
echo "</div> <label id=\"draftLabel\">Draft: <select id=\"draftSel\" onchange=\"showDraft(this.value)\">"
# Latest draft first so it is the default landing view; older drafts follow.
for ((i=${#DRAFTS[@]}-1; i>=0; i--)); do
  echo "<option value=\"${DRAFTS[$i]}\">${DRAFTS[$i]}</option>"
done
echo "</select></label></div>"

for d in "${DRAFTS[@]}"; do
  echo "<div class=\"page\" data-draft=\"$d\">$(agg_line "$d")<table><thead><tr><th>Client ↓ / Relay →</th>"
  for r in "${RELAYS[@]}"; do echo "<th>$r</th>"; done
  echo "</tr></thead><tbody>"
  for c in "${CLIENTS[@]}"; do
    echo "<tr><td>$c</td>"
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
  echo "<div class=\"page\" data-draft=\"open\">$(agg_line open)<p class=\"openmeta\">Live/public endpoints &mdash; real confined-client probes against each live relay. The badge is the <strong>highest draft that interoperated</strong>. Click any pill for its test log.</p><table><thead><tr><th>Client ↓ / Relay →</th>"
  for r in "${OPEN_RELAYS[@]}"; do echo "<th>$r</th>"; done
  echo "</tr></thead><tbody>"
  for c in "${CLIENTS[@]}"; do
    echo "<tr><td>$c</td>"
    for r in "${OPEN_RELAYS[@]}"; do echo "<td>$(cell_open "$c" "$r")</td>"; done
    echo "</tr>"
  done
  echo "</tbody></table></div>"
fi

cat <<'FOOT'
<p class="legend"><strong>draft-NN</strong> tabs: version-confined, local preferred &middot;
<strong>Open Relay Interop</strong>: live endpoints at their <span class="negdraft" style="display:inline-block;margin:0">highest interoperable</span> draft &nbsp;|&nbsp;
<span class="pill rmt"><span class="pval">&deg;</span></span> remote (live endpoint) &middot;
<span class="pill conn"><span class="pval conn">&#8856;</span></span> unreachable &middot;
<strong>&mdash;</strong> not registered &middot; <span style="opacity:.7">click a pill for its log</span></p>
</div>
<script>
function showPage(id){document.querySelectorAll('.page').forEach(p=>p.classList.toggle('active',p.dataset.draft===id));}
function showDraft(d){ try{localStorage.setItem('vpm_draft',d);}catch(e){} var s=document.getElementById('draftSel'); if(s)s.value=d; showPage(d); }
function showView(v){
  try{localStorage.setItem('vpm_view',v);}catch(e){}
  var dl=document.getElementById('draftLabel');
  var td=document.getElementById('tab-draft'), to=document.getElementById('tab-open');
  if(td) td.classList.toggle('active', v==='draft');
  if(to) to.classList.toggle('active', v==='open');
  if(v==='open'){ if(dl) dl.style.display='none'; showPage('open'); }
  else { if(dl) dl.style.display=''; showPage(document.getElementById('draftSel').value); }
}
document.addEventListener('DOMContentLoaded',function(){
  // Sticky across refresh: restore the last view + draft from localStorage.
  var v='draft', d=null;
  try{ v=localStorage.getItem('vpm_view')||'draft'; d=localStorage.getItem('vpm_draft'); }catch(e){}
  var s=document.getElementById('draftSel');
  if(d && s){ for(var i=0;i<s.options.length;i++){ if(s.options[i].value===d){ s.value=d; break; } } }
  if(v==='open' && !document.getElementById('tab-open')) v='draft';   // only if the tab exists
  showView(v);
});
</script>
</body></html>
FOOT
} > "$OUTPUT"

# Self-contained output: copy referenced test logs next to the report (OUTDIR/logs),
# so the clickable pills resolve wherever index.html is published.
OUTDIR=$(dirname "$OUTPUT")
if [ -d "$RESULTS_DIR" ] && ls "$RESULTS_DIR"/*.log >/dev/null 2>&1 && [ "$(cd "$RESULTS_DIR" && pwd)" != "$(cd "$OUTDIR/logs" 2>/dev/null && pwd || echo /nx)" ]; then
  mkdir -p "$OUTDIR/logs"
  cp "$RESULTS_DIR"/*.log "$OUTDIR/logs/" 2>/dev/null || true
fi

echo "Per-draft report: $OUTPUT"

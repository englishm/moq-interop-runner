#!/usr/bin/env python3
"""Render the per-draft interop view from a run-interop-tests.sh results dir.

Usage:
  report/v2/generate.py RESULTS_DIR [--pinned PINNED_DIR] [--out DIR]
                        [--config implementations.json] [--log-base URL]
                        [--pinned-log-base URL] [--fragment]

Reads RESULTS_DIR/summary.json and the per-run TAP logs, and writes
DIR/index.html (self-contained) and DIR/data.json. An unpinned run is placed at
the MoQT draft its client reported negotiating (TAP YAML sessions.*.moqt_version,
or the legacy negotiated_version: draft-NN / negotiated: moq-transport-NN), else
at the runner's prediction, marked as predicted. With --pinned, docker runs come
from run-interop-pinned.sh results: each sits at its pinned draft and is checked
against the version its client reported. Open-relay runs always come from
RESULTS_DIR. --log-base / --pinned-log-base prefix log links (default: each
results dir relative to DIR). --fragment omits the <html>, <head> and <body>.
"""

import argparse
import html
import json
import os
import re
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))

# docker compose prefixes each line with "<container>  | ".
PREFIX_RE = re.compile(r"^([A-Za-z0-9._-]+)\s+\|\s?(.*)$")
TEST_RE = re.compile(
    r"^(not\s+)?ok\b(?:\s+\d+)?(?:\s*-\s*|\s+)?(.*?)"
    r"(?:\s+#\s*(SKIP|TODO)\b\s*(.*))?$", re.IGNORECASE)
MOQT_VERSION_RE = re.compile(r"^\s*moqt_version:\s*\"?moqt-(\d+)\"?\s*$")
LEGACY_VERSION_RE = re.compile(r"^\s*negotiated_version:\s*\"?draft-(\d+)\"?\s*$")
MOQ_DEV_VERSION_RE = re.compile(r"^\s*negotiated:\s*\"?moq-transport-(\d+)\"?\s*$")
OTHER_PROTOCOL_RE = re.compile(r"^\s*negotiated:\s*\"?(moq-lite-[0-9a-z]+)\"?\s*$")
MESSAGE_RE = re.compile(r"^\s*(?:message|error):\s*(.*)$")


def client_lines(path):
    """Yield the test client's output lines from a run log."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.rstrip("\n")
                m = PREFIX_RE.match(line)
                if m:
                    if m.group(1).startswith("relay"):
                        continue
                    line = m.group(2)
                yield line
    except FileNotFoundError:
        return


def parse_log(path, aliases):
    """Return (tests, negotiated_drafts, other_protocols) from one run's TAP output."""
    tests, negotiated, other = [], set(), set()
    current, in_yaml = None, False
    for line in client_lines(path):
        stripped = line.strip()
        if in_yaml and not line[:1].isspace() and re.match(r"(not\s+)?ok\b", stripped):
            in_yaml = False  # some clients never close the block with "..."
        if in_yaml:
            if stripped == "...":
                in_yaml = False
                continue
            m = OTHER_PROTOCOL_RE.match(line)
            if m:
                other.add(m.group(1))
            for rx in (MOQT_VERSION_RE, LEGACY_VERSION_RE, MOQ_DEV_VERSION_RE):
                m = rx.match(line)
                if m:
                    d = int(m.group(1))
                    negotiated.add(d)
                    if current is not None:
                        current["negotiated"] = sorted(set(current["negotiated"]) | {d}, reverse=True)
            m = MESSAGE_RE.match(line)
            if m and current is not None and not current.get("message"):
                current["message"] = m.group(1).strip().strip('"')[:300]
            continue
        if stripped == "---" and current is not None:
            in_yaml = True
            continue
        if line.startswith("    "):
            continue  # subtests
        m = TEST_RE.match(stripped)
        if not m or not (stripped.startswith("ok") or stripped.startswith("not ok")):
            continue
        failed, name, directive = bool(m.group(1)), m.group(2).strip(), (m.group(3) or "").upper()
        if not name:
            continue
        if directive == "SKIP":
            status = "skip"
        elif failed and directive != "TODO":
            status = "fail"
        else:
            status = "pass"
        current = {"id": aliases.get(name, name), "status": status, "negotiated": []}
        if aliases.get(name, name) != name:
            current["raw_id"] = name
        if directive == "SKIP" and m.group(4):
            current["message"] = m.group(4).strip()[:300]
        tests.append(current)
    return tests, sorted(negotiated, reverse=True), sorted(other)


def draft_num(version):
    m = re.match(r"draft-(\d+)$", version or "")
    return int(m.group(1)) if m else None


def run_transport(mode, relay, config, target=""):
    if mode.startswith("remote-") or mode.startswith("docker-"):
        t = mode.split("-", 1)[1]
        return t.replace("-skip", "")
    url = target if "://" in target else (
        config.get(relay, {}).get("roles", {}).get("relay", {})
        .get("docker", {}).get("url") or "https://relay:4443")
    return "quic" if url.startswith("moqt://") else "webtransport"


def make_run(r, results_dir, log_base, registry, aliases):
    mode = r.get("mode", "")
    log = f"{r['client']}_to_{r['relay']}_{mode}.log"
    tests, negotiated, other = [], [], []
    if r.get("status") != "skip":
        tests, negotiated, other = parse_log(os.path.join(results_dir, log), aliases)
    predicted = draft_num(r.get("version"))
    pinned = r.get("pinned_draft")
    run = {
        "client": r["client"],
        "relay": r["relay"],
        "mode": mode,
        "source": "remote" if mode.startswith("remote") else "docker",
        "transport": run_transport(mode, r["relay"], registry, r.get("target", "")),
        "target": r.get("target", ""),
        "status": r.get("status", ""),
        "predicted": predicted,
        "negotiated": negotiated,
        "other_protocols": other,
        "log": (log_base.rstrip("/") + "/" + log) if r.get("status") != "skip" else "",
        "skip_reason": r.get("skip_reason", ""),
        "tests": tests,
    }
    if pinned is not None:
        run.update({
            "draft": pinned,
            "basis": "pinned",
            "confined": r.get("confined", "none"),
            "client_confine": r.get("client_confine", ""),
            "relay_confine": r.get("relay_confine", ""),
            "pin_check": ("mismatch" if other or (negotiated and negotiated != [pinned])
                          else "verified" if negotiated else "unreported"),
        })
    elif negotiated:
        run.update({"draft": negotiated[0], "basis": "negotiated"})
    elif other:
        run.update({"draft": other[0], "basis": "negotiated"})
    else:
        run.update({"draft": predicted, "basis": "predicted"})
    return run


def load_summary(results_dir):
    with open(os.path.join(results_dir, "summary.json")) as f:
        return json.load(f)


def build_model(results_dir, config_path, log_base, pinned_dir=None, pinned_log_base=None):
    summary = load_summary(results_dir)
    with open(config_path) as f:
        registry = json.load(f)["implementations"]
    with open(os.path.join(HERE, "aliases.json")) as f:
        aliases = json.load(f)["aliases"]
    with open(os.path.join(HERE, "test-order.json")) as f:
        order = json.load(f)["order"]

    runs = []
    for r in summary.get("runs", []):
        if pinned_dir and not r.get("mode", "").startswith("remote"):
            continue  # docker runs come from the pinned results
        runs.append(make_run(r, results_dir, log_base, registry, aliases))
    pinned_summary = None
    if pinned_dir:
        pinned_summary = load_summary(pinned_dir)
        for r in pinned_summary.get("runs", []):
            runs.append(make_run(r, pinned_dir, pinned_log_base, registry, aliases))

    seen = []
    for run in runs:
        for t in run["tests"]:
            if t["id"] not in seen:
                seen.append(t["id"])
    test_ids = [t for t in order if t in seen] + sorted(t for t in seen if t not in order)

    impls = {}
    for key, v in registry.items():
        roles = v.get("roles", {})
        relay = roles.get("relay", {}) or {}
        impls[key] = {
            "name": v.get("name", key),
            "organization": v.get("organization", ""),
            "repository": v.get("repository", ""),
            "drafts": sorted({draft_num(d) for d in v.get("draft_versions", []) if draft_num(d)}, reverse=True),
            "roles": sorted(roles.keys()),
            "remotes": [{"url": e.get("url", ""), "transport": e.get("transport", ""),
                         "status": e.get("status", "active")} for e in relay.get("remote", []) or []],
        }

    return {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run": {
            "id": os.path.basename(os.path.normpath(results_dir)),
            "timestamp": summary.get("timestamp", ""),
            "target_version": summary.get("target_version", ""),
        },
        "pinned": ({
            "id": os.path.basename(os.path.normpath(pinned_dir)),
            "timestamp": pinned_summary.get("timestamp", ""),
            "drafts": pinned_summary.get("drafts", []),
        } if pinned_dir else None),
        "test_ids": test_ids,
        "implementations": impls,
        "runs": runs,
    }


def render(model, fragment):
    with open(os.path.join(HERE, "template.html"), encoding="utf-8") as f:
        page = f.read()
    data = json.dumps(model, separators=(",", ":")).replace("</", "<\\/")
    page = page.replace("/*__DATA__*/null", data)
    page = page.replace("__RUN_ID__", html.escape(model["run"]["id"]))
    if fragment:
        head = page[page.index("<!--head-->") + len("<!--head-->"):page.index("<!--/head-->")]
        body = page[page.index("<!--body-->") + len("<!--body-->"):page.index("<!--/body-->")]
        return head.strip() + "\n" + body.strip() + "\n"
    return page


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("results_dir")
    ap.add_argument("--out", default=None, help="output dir (default: RESULTS_DIR/v2)")
    ap.add_argument("--config", default=os.path.join(HERE, "..", "..", "implementations.json"))
    ap.add_argument("--log-base", default=None, help="URL prefix for log links")
    ap.add_argument("--pinned", default=None, help="run-interop-pinned.sh results dir for docker runs")
    ap.add_argument("--pinned-log-base", default=None, help="URL prefix for pinned log links")
    ap.add_argument("--fragment", action="store_true", help="omit <html>/<head>/<body>")
    args = ap.parse_args()

    out = args.out or os.path.join(args.results_dir, "v2")
    os.makedirs(out, exist_ok=True)
    log_base = args.log_base or os.path.relpath(args.results_dir, out)
    pinned_log_base = args.pinned_log_base or (os.path.relpath(args.pinned, out) if args.pinned else None)
    model = build_model(args.results_dir, args.config, log_base, args.pinned, pinned_log_base)
    with open(os.path.join(out, "data.json"), "w") as f:
        json.dump(model, f, indent=1)
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8") as f:
        f.write(render(model, args.fragment))
    n_tests = sum(len(r["tests"]) for r in model["runs"])
    pinned = sum(1 for r in model["runs"] if r["basis"] == "pinned")
    print(f"v2: {len(model['runs'])} runs ({pinned} pinned), {n_tests} test results "
          f"-> {out}/index.html", file=sys.stderr)


if __name__ == "__main__":
    main()

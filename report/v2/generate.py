#!/usr/bin/env python3
"""Render the per-draft interop view from a run-interop-tests.sh results dir.

Usage:
  report/v2/generate.py RESULTS_DIR [--out DIR] [--config implementations.json]
                        [--log-base URL] [--fragment]

Reads RESULTS_DIR/summary.json and the per-run TAP logs, and writes
DIR/index.html (self-contained) and DIR/data.json. Each run is placed at the
MoQT draft its client reported negotiating (TAP YAML sessions.*.moqt_version, or
the legacy negotiated_version: draft-NN), else at the runner's prediction,
marked as predicted. --log-base prefixes log links (default: the results dir,
relative to DIR). --fragment omits the document wrapper (<html>, <head>, <body>).
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
    """Return (tests, negotiated_drafts) from one run's TAP output."""
    tests, negotiated = [], set()
    current, in_yaml = None, False
    for line in client_lines(path):
        stripped = line.strip()
        if in_yaml and not line[:1].isspace() and re.match(r"(not\s+)?ok\b", stripped):
            in_yaml = False  # some clients never close the block with "..."
        if in_yaml:
            if stripped == "...":
                in_yaml = False
                continue
            for rx in (MOQT_VERSION_RE, LEGACY_VERSION_RE):
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
    return tests, sorted(negotiated, reverse=True)


def draft_num(version):
    m = re.match(r"draft-(\d+)$", version or "")
    return int(m.group(1)) if m else None


def run_transport(mode, relay, config):
    if mode.startswith("remote-") or mode.startswith("docker-"):
        t = mode.split("-", 1)[1]
        return t.replace("-skip", "")
    url = (config.get(relay, {}).get("roles", {}).get("relay", {})
           .get("docker", {}).get("url") or "https://relay:4443")
    return "quic" if url.startswith("moqt://") else "webtransport"


def build_model(results_dir, config_path, log_base):
    with open(os.path.join(results_dir, "summary.json")) as f:
        summary = json.load(f)
    with open(config_path) as f:
        registry = json.load(f)["implementations"]
    with open(os.path.join(HERE, "aliases.json")) as f:
        aliases = json.load(f)["aliases"]
    with open(os.path.join(HERE, "test-order.json")) as f:
        order = json.load(f)["order"]

    runs = []
    for r in summary.get("runs", []):
        mode = r.get("mode", "")
        log = f"{r['client']}_to_{r['relay']}_{mode}.log"
        tests, negotiated = ([], [])
        if r.get("status") != "skip":
            tests, negotiated = parse_log(os.path.join(results_dir, log), aliases)
        predicted = draft_num(r.get("version"))
        draft = negotiated[0] if negotiated else predicted
        runs.append({
            "client": r["client"],
            "relay": r["relay"],
            "mode": mode,
            "source": "remote" if mode.startswith("remote") else "docker",
            "transport": run_transport(mode, r["relay"], registry),
            "target": r.get("target", ""),
            "status": r.get("status", ""),
            "predicted": predicted,
            "negotiated": negotiated,
            "draft": draft,
            "basis": "negotiated" if negotiated else "predicted",
            "log": (log_base.rstrip("/") + "/" + log) if r.get("status") != "skip" else "",
            "skip_reason": r.get("skip_reason", ""),
            "tests": tests,
        })

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

    drafts = sorted({run["draft"] for run in runs if run["draft"] is not None}, reverse=True)
    return {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run": {
            "id": os.path.basename(os.path.normpath(results_dir)),
            "timestamp": summary.get("timestamp", ""),
            "target_version": summary.get("target_version", ""),
        },
        "drafts": drafts,
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
    ap.add_argument("--fragment", action="store_true", help="omit <html>/<head>/<body>")
    args = ap.parse_args()

    out = args.out or os.path.join(args.results_dir, "v2")
    os.makedirs(out, exist_ok=True)
    log_base = args.log_base or os.path.relpath(args.results_dir, out)
    model = build_model(args.results_dir, args.config, log_base)
    with open(os.path.join(out, "data.json"), "w") as f:
        json.dump(model, f, indent=1)
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8") as f:
        f.write(render(model, args.fragment))
    n_tests = sum(len(r["tests"]) for r in model["runs"])
    print(f"v2: {len(model['runs'])} runs, {n_tests} test results, drafts "
          f"{model['drafts']} -> {out}/index.html", file=sys.stderr)


if __name__ == "__main__":
    main()

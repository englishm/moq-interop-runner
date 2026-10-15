#!/usr/bin/env python3
"""Publisher-only TAP client backed by the moqxr publisher executable."""

import argparse
import os
import subprocess
import sys


TESTS = ("announce-only", "publish-namespace-done")
NAMESPACE_ACK = "namespace published namespace=moq-test/interop"


def run_publisher(relay_url, draft, insecure):
    command = [
        os.environ.get("MOQXR_BIN", "/app/openmoq-publisher"),
        "--input", os.environ.get("MOQXR_FIXTURE", "/app/fixture.mp4"),
        "--endpoint", relay_url,
        "--draft", draft,
        "--namespace", "moq-test/interop",
        "--timeout", "2",
    ]
    if insecure:
        command.append("--insecure")
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=12)
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, str(error)
    output = result.stdout + result.stderr
    if result.returncode != 0:
        return False, f"publisher exited {result.returncode}: {output.strip()}"
    if "connection_id=" not in output or NAMESPACE_ACK not in output:
        return False, "publisher exited without confirming connection and namespace acceptance"
    return True, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--relay", default=os.environ.get("RELAY_URL", ""))
    parser.add_argument("--test", default=os.environ.get("TESTCASE", ""))
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--tls-disable-verify", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if args.list:
        print(*TESTS, sep="\n")
        return 0

    selected = (args.test,) if args.test else TESTS
    print("TAP version 14")
    print("# moqxr publisher-only test client")
    print(f"# Relay: {args.relay}")
    print(f"1..{len(selected)}")
    if args.test and args.test not in TESTS:
        print(f"ok 1 - {args.test} # SKIP moqxr publisher does not implement this test")
        return 127

    version = os.environ.get("MOQ_CLIENT_VERSION") or "draft-22"
    draft = version.removeprefix("draft-")
    if draft not in {"16", "18", "21", "22"}:
        for number, case in enumerate(selected, 1):
            print(f"not ok {number} - {case}")
        print(f"# Unsupported moqxr draft: {version}")
        return 1
    if not args.relay:
        for number, case in enumerate(selected, 1):
            print(f"not ok {number} - {case}")
        print("# RELAY_URL is required")
        return 1

    insecure = args.tls_disable_verify or os.environ.get("TLS_DISABLE_VERIFY", "").lower() in {
        "1", "true", "yes"
    }
    verbose = args.verbose or os.environ.get("VERBOSE", "") == "1"
    failures = 0
    for number, case in enumerate(selected, 1):
        passed, detail = run_publisher(args.relay, draft, insecure)
        print(f"{'ok' if passed else 'not ok'} {number} - {case}")
        if verbose or not passed:
            for line in detail.splitlines():
                print(f"# {line}")
        failures += not passed
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

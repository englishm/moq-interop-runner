#!/usr/bin/env python3
"""TAP client using moqxr for publishing and moqy for media reception."""

import argparse
import os
import pty
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
import uuid


TESTS = ("announce-only", "publish-subscribe-media")
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


def run_media(relay_url, insecure):
    namespace = os.environ.get("MOQ_MEDIA_NAMESPACE") or f"moq-test/interop/{uuid.uuid4().hex}"
    publisher_command = [
        os.environ.get("MOQXR_BIN", "/app/openmoq-publisher"),
        "--input", os.environ.get("MOQXR_FIXTURE", "/app/fixture.mp4"),
        "--endpoint", relay_url, "--draft", "22", "--namespace", namespace,
        "--publish-catalog", "--catalog-republish-interval", "1",
        "--paced", "--loop", "--forward", "1",
        "--timeout", "15",
    ]
    if relay_url.startswith("https://"):
        publisher_command += ["--transport", "webtransport"]
    if insecure:
        publisher_command.append("--insecure")
    subscriber_command = [
        os.environ.get("MOQY_BIN", "/app/moqy"), relay_url, namespace,
        "--waveform",
    ]
    if insecure:
        subscriber_command.append("--insecure-skip-verify")

    try:
        with tempfile.TemporaryFile(mode="w+t") as publisher_output:
            publisher = subprocess.Popen(publisher_command, stdout=publisher_output,
                                         stderr=subprocess.STDOUT)
            master = None
            subscriber = None
            try:
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    publisher_output.seek(0)
                    output = publisher_output.read()
                    if f"namespace published namespace={namespace}" in output:
                        break
                    if publisher.poll() is not None:
                        return False, f"publisher exited {publisher.returncode}: {output.strip()}"
                    time.sleep(0.1)
                else:
                    return False, f"publisher did not confirm namespace: {output.strip()}"

                master, slave = pty.openpty()
                try:
                    subscriber = subprocess.Popen(subscriber_command, stdin=subprocess.DEVNULL,
                                                  stdout=slave, stderr=subprocess.PIPE, text=True)
                finally:
                    os.close(slave)
                deadline = time.monotonic() + 8
                while subscriber.poll() is None and time.monotonic() < deadline:
                    if publisher.poll() is not None:
                        break
                    ready, _, _ = select.select([master], [], [], 0.2)
                    if ready:
                        try:
                            os.read(master, 65536)
                        except OSError:
                            break
                if subscriber.poll() is None:
                    subscriber.send_signal(signal.SIGINT)
                try:
                    _, detail = subscriber.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    subscriber.kill()
                    _, detail = subscriber.communicate()
                    return False, f"subscriber did not stop: {detail.strip()}"
                counts = re.search(r"displayed (\d+) frames, decoded (\d+) audio blocks", detail)
                if subscriber.returncode != 0 or not counts or int(counts.group(1)) < 2:
                    publisher_output.seek(0)
                    return False, (f"subscriber exited {subscriber.returncode}: {detail.strip()}\n"
                                   f"publisher: {publisher_output.read().strip()}")
                if publisher.poll() is not None and publisher.returncode != 0:
                    return False, f"publisher exited {publisher.returncode} during delivery"
                return True, detail.strip()
            finally:
                if master is not None:
                    os.close(master)
                if subscriber is not None and subscriber.poll() is None:
                    subscriber.terminate()
                    try:
                        subscriber.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        subscriber.kill()
                        subscriber.wait()
                if publisher.poll() is None:
                    publisher.terminate()
                try:
                    publisher.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    publisher.kill()
                    publisher.wait()
    except OSError as error:
        return False, str(error)


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
    print("# moqxr publisher and moqy subscriber test client")
    print(f"# Relay: {args.relay}")
    print(f"1..{len(selected)}")
    if args.test and args.test not in TESTS:
        print(f"ok 1 - {args.test} # SKIP moqxr/moqy do not implement this test")
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
        passed, detail = (run_media(args.relay, insecure) if case == "publish-subscribe-media"
                          else run_publisher(args.relay, draft, insecure))
        print(f"{'ok' if passed else 'not ok'} {number} - {case}")
        if verbose or not passed:
            for line in detail.splitlines():
                print(f"# {line}")
        failures += not passed
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

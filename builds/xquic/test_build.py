#!/usr/bin/env python3
"""Exercise the endpoint build contract without a network or Docker daemon."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


BUILD = Path(__file__).resolve().parent


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="xquic-build-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.build = self.root / "builds/xquic"
        self.build.mkdir(parents=True)
        for name in ("build.sh", "config.json", "Dockerfile.endpoint"):
            shutil.copy2(BUILD / name, self.build / name)
        self.config = json.loads((self.build / "config.json").read_text())
        self.source = self.root / "local source"
        self.source.mkdir()
        (self.source / "keep.txt").write_text("local checkout stays unchanged\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.trace = self.root / "calls.jsonl"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        BUILD_TEST_TRACE=str(self.trace), BUILD_TEST_FAIL="0")
        stub = '''import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["BUILD_TEST_TRACE"], "a") as trace:
    trace.write(json.dumps([tool, *args]) + "\\n")
if tool == "docker":
    sys.exit(int(os.environ["BUILD_TEST_FAIL"]))
if args[0] == "clone":
    (pathlib.Path(args[-1]) / ".git").mkdir(parents=True)
elif "rev-parse" in args:
    print("a" * 40)
elif "get-url" in args:
    print("https://github.com/alibaba/xquic.git")
'''
        for name in ("git", "docker"):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n{stub}")
            path.chmod(0o755)

    def run_build(self, *args):
        return subprocess.run(["bash", str(self.build / "build.sh"), *args],
                              env=self.env, capture_output=True, text=True)

    def calls(self):
        if not self.trace.exists():
            return []
        return [json.loads(line) for line in self.trace.read_text().splitlines()]

    def provenance(self):
        return json.loads((self.build / ".last-build.json").read_text())

    def test_default_ref_and_single_image(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        checkouts = [call[-1] for call in calls if "checkout" in call]
        self.assertEqual(checkouts, ["dev/moqt-interop"])
        builds = [call for call in calls if call[0] == "docker"]
        target = self.config["targets"]["endpoint"]
        self.assertEqual(builds, [["docker", "build", "-f",
            str(self.build / "Dockerfile.endpoint"), "-t",
            target["image_name"] + ":latest", "-t",
            target["registry_image"] + ":latest",
            str(self.build / ".sources/xquic")]])
        self.assertEqual(self.provenance()["source"]["ref"], "dev/moqt-interop")
        self.assertEqual(len(self.provenance()["images"]), 1)

    def test_local_source_is_preserved(self):
        before = {p.name: p.read_bytes() for p in self.source.iterdir()}
        result = self.run_build("--local", str(self.source),
                                "--target", "endpoint")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("clone" in call or "checkout" in call
                             for call in self.calls()))
        self.assertEqual(before,
            {p.name: p.read_bytes() for p in self.source.iterdir()})
        source = self.provenance()["source"]
        self.assertEqual(source["type"], "local")
        self.assertEqual(source["local_path"], str(self.source))
        self.assertFalse(source["dirty"])

    def test_ref_and_repository_override(self):
        result = self.run_build("--ref", "test-pinned-ref", "--repo",
                                "https://example.test/xquic.git")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.provenance()["source"]["ref"], "test-pinned-ref")
        self.assertEqual(self.provenance()["source"]["repository"],
                         "https://example.test/xquic.git")

    def test_removed_targets_fail_before_side_effects(self):
        for target in ("client", "relay", "client-draft-18", "relay-draft-18",
                       "client-draft-22", "unknown"):
            with self.subTest(target=target):
                result = self.run_build("--target", target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("supported: endpoint", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_invalid_arguments_fail_before_side_effects(self):
        for args in (("--ref",), ("--local",), ("--target",), ("--repo",),
                     ("--unknown",), ("--local", str(self.source),
                     "--ref", "other"), ("--local", str(self.source),
                     "--repo", "https://example.test/xquic.git"),
                     ("--local", str(self.root / "missing"))):
            with self.subTest(args=args):
                result = self.run_build(*args)
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_failed_build_does_not_report_success(self):
        self.env["BUILD_TEST_FAIL"] = "1"
        result = self.run_build("--local", str(self.source))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Docker build failed for endpoint", result.stderr)
        self.assertNotIn("Build complete!", result.stderr)
        self.assertFalse((self.build / ".last-build.json").exists())
        self.assertEqual((self.source / "keep.txt").read_text(),
                         "local checkout stays unchanged\n")


if __name__ == "__main__":
    unittest.main()

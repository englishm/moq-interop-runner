import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CLIENT = Path(__file__).with_name("client.py")


class MoqxrClientContractTest(unittest.TestCase):
    def run_client(self, publisher_output, publisher_exit=0, testcase="announce-only"):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "publisher"
            fake.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" > \"$ARGUMENT_LOG\"\n"
                f"printf '%s\\n' {publisher_output!r}\n"
                f"exit {publisher_exit}\n"
            )
            fake.chmod(0o755)
            args = Path(directory) / "args"
            env = dict(os.environ, MOQXR_BIN=str(fake), MOQXR_FIXTURE=str(fake),
                       RELAY_URL="moqt://relay:4443", TESTCASE=testcase,
                       TLS_DISABLE_VERIFY="1", MOQ_CLIENT_VERSION="",
                       ARGUMENT_LOG=str(args))
            result = subprocess.run([sys.executable, str(CLIENT)], env=env,
                                    capture_output=True, text=True, timeout=5)
            return result, args.read_text() if args.exists() else ""

    def test_publisher_ack_is_required_for_announce_pass(self):
        result, args = self.run_client(
            "connection_id=abc\n[moqt-session] namespace published namespace=moq-test/interop tracks=2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TAP version 14\n", result.stdout)
        self.assertIn("1..1\nok 1 - announce-only", result.stdout)
        self.assertIn("--draft 22", args)
        self.assertIn("--insecure", args)
        self.assertIn("--endpoint moqt://relay:4443", args)

    def test_successful_process_without_namespace_ack_fails(self):
        result, _ = self.run_client("connection_id=abc")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not ok 1 - announce-only", result.stdout)

    def test_unsupported_subscriber_case_returns_127(self):
        result, args = self.run_client("", testcase="subscribe-error")
        self.assertEqual(result.returncode, 127)
        self.assertIn("ok 1 - subscribe-error # SKIP", result.stdout)
        self.assertEqual(args, "")

    def test_full_run_only_lists_publisher_cases(self):
        result, args = self.run_client(
            "connection_id=abc\n[moqt-session] namespace published namespace=moq-test/interop tracks=2",
            testcase="")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("1..2", result.stdout)
        self.assertIn("ok 1 - announce-only", result.stdout)
        self.assertIn("ok 2 - publish-namespace-done", result.stdout)
        self.assertNotIn("subscribe-error", result.stdout)
        self.assertIn("--namespace moq-test/interop", args)


if __name__ == "__main__":
    unittest.main()

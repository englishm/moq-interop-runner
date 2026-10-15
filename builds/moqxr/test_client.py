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
                       TLS_DISABLE_VERIFY="1", ARGUMENT_LOG=str(args))
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

    def test_withdrawal_case_is_not_claimed_without_observing_withdrawal(self):
        result, args = self.run_client("", testcase="publish-namespace-done")
        self.assertEqual(result.returncode, 127)
        self.assertIn("# SKIP", result.stdout)
        self.assertEqual(args, "")

    def test_list_exposes_media_case(self):
        result = subprocess.run([sys.executable, str(CLIENT), "--list"],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("announce-only\n", result.stdout)
        self.assertIn("publish-subscribe-media\n", result.stdout)
        self.assertNotIn("subscribe-error", result.stdout)

    def test_media_delivery_requires_decoded_frames_from_tty_subscriber(self):
        with tempfile.TemporaryDirectory() as directory:
            publisher = Path(directory) / "publisher"
            publisher.write_text("#!/bin/sh\necho 'connection_id=abc'\necho 'namespace published namespace=moq-test/interop/test tracks=2'\nsleep 30\n")
            publisher.chmod(0o755)
            subscriber = Path(directory) / "subscriber"
            subscriber.write_text("#!/bin/sh\n[ -t 1 ] || exit 2\necho 'displayed 3 frames, decoded 0 audio blocks' >&2\n")
            subscriber.chmod(0o755)
            env = dict(os.environ, MOQXR_BIN=str(publisher), MOQY_BIN=str(subscriber),
                       MOQXR_FIXTURE=str(publisher), RELAY_URL="moqt://relay:4443",
                       TESTCASE="publish-subscribe-media", TLS_DISABLE_VERIFY="1",
                       MOQ_MEDIA_NAMESPACE="moq-test/interop/test")
            result = subprocess.run([sys.executable, str(CLIENT)], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("ok 1 - publish-subscribe-media", result.stdout)

    def test_media_delivery_rejects_zero_frames(self):
        with tempfile.TemporaryDirectory() as directory:
            publisher = Path(directory) / "publisher"
            publisher.write_text("#!/bin/sh\necho 'connection_id=abc'\necho 'namespace published namespace=moq-test/interop/test tracks=2'\nsleep 30\n")
            publisher.chmod(0o755)
            subscriber = Path(directory) / "subscriber"
            subscriber.write_text("#!/bin/sh\necho 'displayed 0 frames, decoded 0 audio blocks' >&2\n")
            subscriber.chmod(0o755)
            env = dict(os.environ, MOQXR_BIN=str(publisher), MOQY_BIN=str(subscriber),
                       MOQXR_FIXTURE=str(publisher), RELAY_URL="moqt://relay:4443",
                       TESTCASE="publish-subscribe-media",
                       MOQ_MEDIA_NAMESPACE="moq-test/interop/test")
            result = subprocess.run([sys.executable, str(CLIENT)], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("not ok 1 - publish-subscribe-media", result.stdout)


if __name__ == "__main__":
    unittest.main()

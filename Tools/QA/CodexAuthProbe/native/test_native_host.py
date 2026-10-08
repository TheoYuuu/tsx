#!/usr/bin/env python3
"""Test the compiled Swift host against owned protocol-only fake processes.

These cases never load Rust, contact an issuer, or access Keychain. They prove
native framing/lifecycle rejection, not authentication or storage behavior.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

BINARY = Path(sys.argv.pop(1)).resolve(strict=True)


class NativeHostTests(unittest.TestCase):
    def run_case(self, behavior, expected, *, short_watchdog=False, fill_input=False, action="none", inheritance_probe=False):
        with tempfile.TemporaryDirectory(prefix="lumax-native-wire-") as tmp:
            root = Path(tmp)
            helper = root / "fake-helper.py"
            helper.write_text("#!/usr/bin/python3\n" + """
import json, os, sys, time
if os.getpgrp() != os.getpid():
    os.setsid()
""" + ("time.sleep(5)\n" if fill_input else "") + """
r = json.loads(sys.stdin.readline())
base = {'protocol_version': 1, 'request_id': r['request_id']}
ready = dict(base, event='ready', user_code='CONSTRUCTED-CODE', verification_url=r['issuer']+'/codex/device')
terminal = dict(base, event='terminal', status='cancelled', authorization_ui_disabled=True, worker_reaped=True)
def emit(value):
    print(json.dumps(value), flush=True)
""" + behavior + "\n")
            helper.chmod(0o700)
            request = {"operation": "login_session", "protocol_version": 1,
                       "request_id": str(uuid.uuid4()), "identity_home": str(root),
                       "issuer": "http://127.0.0.1:9"}
            if fill_input:
                request["constructed_padding"] = "x" * 30000
            command = [str(BINARY)] + (["--short-watchdog"] if short_watchdog else []) + (["--inheritance-probe"] if inheritance_probe else [])
            result = subprocess.run(command, input=json.dumps({"helper_path": str(helper),
                "request": request, "action": action}).encode(), capture_output=True,
                env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": tmp}, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stderr, b"")
            output = json.loads(result.stdout)
            self.assertEqual(output["host_status"], expected)
            self.assertTrue(output["helper_reaped"])
            self.assertNotIn(b"PRIVATE-FIXTURE-TOKEN", result.stdout)
            return output

    def test_valid_cancelled_terminal(self):
        out = self.run_case("emit(ready)\nemit(terminal)", "completed")
        self.assertEqual([event["event"] for event in out["events"]], ["ready", "terminal"])

    def test_bytes_keep_wire_order(self):
        out = self.run_case("for byte in (json.dumps(ready)+'\\n'+json.dumps(terminal)+'\\n').encode():\n    sys.stdout.buffer.write(bytes([byte])); sys.stdout.buffer.flush()", "completed")
        self.assertEqual(len(out["events"]), 2)

    def test_wrong_request_id(self):
        self.run_case("ready['request_id']='00000000-0000-0000-0000-000000000000'\nemit(ready)", "protocol_failed")

    def test_wrong_version(self):
        self.run_case("ready['protocol_version']=2\nemit(ready)", "protocol_failed")

    def test_duplicate_ready(self):
        self.run_case("emit(ready)\nemit(ready)\nemit(terminal)", "protocol_failed")

    def test_duplicate_terminal(self):
        self.run_case("emit(terminal)\nemit(terminal)", "protocol_failed")

    def test_unknown_secret_field(self):
        self.run_case("terminal['access_token']='PRIVATE-FIXTURE-TOKEN'\nemit(terminal)", "protocol_failed")

    def test_wrong_verification_address(self):
        self.run_case("ready['verification_url']='https://example.invalid/codex/device'\nemit(ready)", "protocol_failed")

    def test_stderr_not_returned(self):
        out = self.run_case("sys.stderr.write('PRIVATE-FIXTURE-TOKEN')\nemit(terminal)", "protocol_failed")
        self.assertFalse(out["stderr_empty"])

    def test_no_terminal(self):
        self.run_case("emit(ready)", "protocol_failed")

    def test_unterminated_frame(self):
        self.run_case("sys.stdout.write(json.dumps(terminal))", "protocol_failed")

    def test_oversized_frame(self):
        self.run_case("sys.stdout.write('x'*9000+'\\n')", "protocol_failed")

    def test_unconfirmed_success(self):
        self.run_case("terminal['status']='signed_in'\nemit(terminal)", "protocol_failed")

    def test_swift_task_cancellation_sends_matching_control(self):
        out = self.run_case("emit(ready)\nc=json.loads(sys.stdin.readline())\nassert c == dict(base, operation='cancel')\nemit(terminal)",
                            "completed", action="task_cancel_ready")
        self.assertEqual(out["events"][-1]["status"], "cancelled")

    def test_quiet_stderr_does_not_delay_ready_eof(self):
        # Keep both pipes open while stdout becomes ready later. AsyncBytes
        # intermittently postponed ready until this helper's timeout/exit; a
        # completed host result alone cannot detect that missed cancellation.
        behavior = """
import select
time.sleep(0.08)
emit(ready)
readable, _, _ = select.select([sys.stdin], [], [], 0.75)
terminal['status'] = 'cancelled' if readable and os.read(0, 1) == b'' else 'login_failed'
emit(terminal)
"""
        for attempt in range(12):
            with self.subTest(attempt=attempt):
                out = self.run_case(behavior, "completed", action="eof_ready")
                self.assertEqual(out["events"][-1]["status"], "cancelled")

    def test_unrelated_child_cannot_retain_login_pipe(self):
        out = self.run_case("emit(ready)\nassert sys.stdin.read() == ''\nemit(terminal)",
                            "completed", action="eof_ready", inheritance_probe=True)
        self.assertIs(out["completed_before_fixture_sibling_exit"], True)

    def test_initial_write_does_not_block_watchdog(self):
        self.run_case("emit(terminal)", "cleanup_required", short_watchdog=True, fill_input=True)

    def test_exited_helper_with_inherited_pipe_is_bounded(self):
        # The child has a strict self-exit; no fixture process can remain after
        # this test's finally grace. The host must not wait for that child's EOF.
        started = time.monotonic()
        try:
            self.run_case("pid=os.fork()\nif pid == 0:\n    time.sleep(3); os._exit(0)\nos._exit(0)",
                          "cleanup_required", short_watchdog=True)
            self.assertLess(time.monotonic() - started, 2)
        finally:
            time.sleep(max(0, 3.5 - (time.monotonic() - started)))


if __name__ == "__main__":
    unittest.main()

"""Pure event-checker tests, without processes, sockets, auth, or Keychain."""
import copy
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe import output_closed_event_checks, session_event_checks


class MemoryIssuer:
    def valid_device_response(self, event):
        return event.get("user_code") == "constructed-code" and event.get("verification_url") == "http://127.0.0.1:1/codex/device"

    def contains_secret(self, value):
        return b"constructed-code" in value or b"constructed-private-token" in value


class SessionProtocolTests(unittest.TestCase):
    def events(self):
        common = {"protocol_version": 1, "request_id": "fixture-request", "authorization_ui_disabled": True}
        return [
            dict(common, event="ready", user_code="constructed-code", verification_url="http://127.0.0.1:1/codex/device"),
            dict(common, event="phase", phase="before_promotion"),
            dict(common, event="phase", phase="after_promotion"),
            dict(common, event="terminal", status="signed_in"),
        ]

    def check(self, events):
        return session_event_checks(MemoryIssuer(), "fixture-request", events)

    def test_single_ready_same_code_and_terminal_sequence_passes(self):
        result, checks = self.check(self.events())
        self.assertEqual(result["status"], "signed_in")
        self.assertTrue(all(checks.values()))

    def test_extra_terminal_missing_terminal_and_late_event_fail(self):
        events = self.events()
        for variant in (events + [events[-1]], events[:-1], events + [events[0]]):
            with self.subTest(variant_length=len(variant)):
                _result, checks = self.check(variant)
                self.assertFalse(checks["terminal_once_and_last"])

    def test_wrong_code_request_id_and_private_error_fail(self):
        mutations = ((0, "user_code", "other-code", "ready_code_matches_issuer"),
                     (1, "request_id", "wrong-request", "event_schema"),
                     (3, "error", "constructed-private-token", "private_event_content_absent"))
        for index, key, value, expected in mutations:
            with self.subTest(field=key):
                events = copy.deepcopy(self.events())
                events[index][key] = value
                _result, checks = self.check(events)
                self.assertFalse(checks[expected])

    def test_phase_order_and_non_object_events_fail(self):
        events = self.events()
        _result, checks = self.check([events[0], events[2], events[1], events[3]])
        self.assertFalse(checks["phase_order"])
        _result, checks = self.check([False])
        self.assertFalse(all(checks.values()))

    def test_closed_output_requires_saved_phase_and_no_terminal(self):
        events = self.events()
        self.assertTrue(all(output_closed_event_checks(MemoryIssuer(), "fixture-request", events[:-1]).values()))
        for variant in (events, events[:2], [events[0], events[2]], [False]):
            with self.subTest(event_count=len(variant)):
                self.assertFalse(all(output_closed_event_checks(MemoryIssuer(), "fixture-request", variant).values()))


if __name__ == "__main__":
    unittest.main()

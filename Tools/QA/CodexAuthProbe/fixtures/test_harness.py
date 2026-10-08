"""Pure Python evidence/cleanup regression tests; no Rust, network, or Keychain.

Cleanup calls below are enumeration stubs. Their signed_out values are not
evidence of system credential deletion; the coordinated native probe tests that.
"""
from contextlib import ExitStack
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe as auth_probe


class NoNetworkIssuer:
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass

    def snapshot(self):
        return {"requests": {}}


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.resources = ExitStack()
        self.addCleanup(self.resources.close)
        self.root = Path(self.resources.enter_context(
            tempfile.TemporaryDirectory(prefix="translatex-auth-harness-test-"))).resolve()
        # Fail immediately if a regression tries to leave this Python-only test.
        self.resources.enter_context(patch.object(auth_probe.subprocess, "Popen",
            side_effect=AssertionError("process execution is forbidden in this test")))
        self.resources.enter_context(patch.object(auth_probe.socket, "socket",
            side_effect=AssertionError("network is forbidden in this test")))
        self.resources.enter_context(patch.object(auth_probe, "bounded_invoke",
            side_effect=AssertionError("native helper invocation is forbidden in this test")))
        placeholder = self.root / "never-executed.txt"
        placeholder.write_text("Python fixture path only.\n", encoding="utf-8")
        self.probe = auth_probe.Probe(placeholder, self.root)

    def test_manifest_and_report_preserve_complete_previous_write_on_fault(self):
        for filename, write in (("identity-manifest.json", self.probe.write_manifest),
                                ("report.json", self.probe.write_summary)):
            with self.subTest(filename=filename):
                self.probe.interrupted = False
                write()
                destination = self.probe.run / filename
                previous = destination.read_bytes()
                self.probe.interrupted = True
                for operation in ("fsync", "replace"):
                    with self.subTest(operation=operation):
                        with patch.object(auth_probe.os, operation,
                                          side_effect=OSError("constructed write interruption")):
                            with self.assertRaises(OSError):
                                write()
                        self.assertEqual(destination.read_bytes(), previous)
                        self.assertIs(json.loads(destination.read_text())["interrupted"], False)
                        self.assertEqual(list(self.probe.run.glob("." + filename + ".*.tmp")), [])
                write()
                self.assertIs(json.loads(destination.read_text())["interrupted"], True)

    def test_bad_journals_do_not_block_known_identity_cleanup_or_hide_failure(self):
        malformed = self.probe.home("malformed")
        wrong_type = self.probe.home("wrong-type")
        missing_stage = self.probe.home("missing-stage")
        dangling_link = self.probe.home("dangling-link")
        good = self.probe.home("valid-journal")
        stage = self.root / ("stage-" + str(uuid.uuid4()))
        marker = "CONSTRUCTED_PRIVATE_ERROR_MARKER"
        (malformed / ".pending-auth-cleanup.json").write_text('{"' + marker, encoding="utf-8")
        (wrong_type / ".pending-auth-cleanup.json").write_text("[]", encoding="utf-8")
        (missing_stage / ".pending-auth-cleanup.json").write_text(json.dumps({
            "target_home": str(missing_stage), "target_initially_signed_out": True}), encoding="utf-8")
        (dangling_link / ".pending-auth-cleanup.json").symlink_to(self.root / "does-not-exist")
        (good / ".pending-auth-cleanup.json").write_text(json.dumps({
            "target_home": str(good), "target_initially_signed_out": True,
            "stage_home": str(stage)}), encoding="utf-8")
        visited = []

        def enumerate_only(_issuer, operation, home, **_kwargs):
            visited.append((home, operation))
            # Real invoke discovers journals after each native call. Exercise
            # repeated discovery without executing that native boundary.
            self.probe.discover_stages()
            return {"status": "signed_out"}, {"enumeration_stub": True}, 0

        with patch.object(auth_probe, "FakeIssuer", NoNetworkIssuer), \
                patch.object(self.probe, "invoke", side_effect=enumerate_only):
            self.probe.cleanup_all()

        known = {malformed, wrong_type, missing_stage, dangling_link, good, stage}
        self.assertEqual(self.probe.identities, known)
        expected = {(home, operation) for home in known for operation in ("logout", "status")}
        self.assertEqual(set(visited), expected)
        self.assertEqual(len(visited), len(expected))
        failures = [row for row in self.probe.cleanup
                    if row.get("failure") == "cleanup_journal_discovery_failed"]
        self.assertEqual({row["identity_home"] for row in failures},
                         {str(home) for home in (malformed, wrong_type, missing_stage, dangling_link)})
        self.assertEqual(len(failures), 4)
        self.assertTrue(all(row["cleanup_required"] for row in failures))
        self.probe.discover_stages()
        self.assertEqual(len([row for row in self.probe.cleanup
                              if row.get("failure") == "cleanup_journal_discovery_failed"]), 4)
        self.probe.write_summary()
        for filename in ("identity-manifest.json", "report.json"):
            contents = (self.probe.run / filename).read_text(encoding="utf-8")
            evidence = json.loads(contents)
            self.assertIs(evidence["cleanup_required"], True)
            self.assertIs(evidence["cleanup_complete"], False)
            self.assertTrue(any(row["cleanup_required"] for row in evidence["cleanup"]))
            self.assertNotIn(marker, contents)
        manifest = json.loads((self.probe.run / "identity-manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(set(manifest["identity_homes"]), {str(home) for home in known})


if __name__ == "__main__":
    unittest.main()

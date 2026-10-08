"""Pure packaging gate tests: no account, signing, compiler or network access."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("runtime_package", Path(__file__).with_name("package.py"))
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class PackageVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="package-test-", dir=PACKAGE.common.directory(PACKAGE.WORK / "tests"))
        self.work = Path(self.temporary.name)
        self.product = self.work / "package/Debug"
        self.product.mkdir(parents=True)
        self.binary = self.product / PACKAGE.BINARY
        self.binary.write_bytes(b"constructed executable bytes")
        self.notices = self.product / "THIRD-PARTY-NOTICES.txt"
        self.notices.write_bytes(b"constructed notices")
        self.runtime = {"Cargo.toml": b"fixed", "src/main.rs": b"fixed"}
        self.tools = {"package.py": "fixed-tool-hash"}
        self.manifest = {"schema": 1, "configuration": "Debug", "runtimeInputs": {
            name: hashlib.sha256(value).hexdigest() for name, value in self.runtime.items()},
            "toolInputs": self.tools, "sha256": PACKAGE.digest(self.binary),
            "noticesSHA256": PACKAGE.digest(self.notices), "architectures": ["arm64"],
            "identifier": PACKAGE.IDENTIFIER, "minimumMacOS": "15.0", "qaFeatures": False,
            "accountAccess": False, "cargoLocked": True, "cargoOffline": True,
            "sourceCommit": PACKAGE.common.COMMIT, "sourceArchiveSHA256": PACKAGE.common.SOURCE_SHA256,
            "licenses": {"missingLicenseTexts": []}}

    def tearDown(self):
        self.temporary.cleanup()

    def verify(self):
        (self.product / "package-manifest.json").write_text(json.dumps(self.manifest))
        with patch.object(PACKAGE, "WORK", self.work), patch.object(PACKAGE.builder, "inputs", return_value=self.runtime), \
                patch.object(PACKAGE, "tool_inputs", return_value=self.tools), \
                patch.object(PACKAGE.platform, "machine", return_value="arm64"), \
                patch.object(PACKAGE, "command_output", side_effect=lambda command, *_: "arm64" if "-archs" in command else ""), \
                contextlib.redirect_stdout(io.StringIO()):
            PACKAGE.verify_existing(["Debug"])

    def test_matching_current_inputs_pass(self):
        self.verify()

    def test_stale_runtime_source_rejected(self):
        self.runtime["src/main.rs"] = b"changed source"
        with self.assertRaises(RuntimeError):
            self.verify()

    def test_stale_packaging_script_rejected(self):
        self.manifest["toolInputs"] = {"package.py": "old-tool-hash"}
        with self.assertRaises(RuntimeError):
            self.verify()

    def test_changed_binary_or_notice_rejected(self):
        for path in (self.binary, self.notices):
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(original + b"changed")
                with self.assertRaises(RuntimeError):
                    self.verify()
                path.write_bytes(original)

    def test_fixture_feature_or_missing_notice_rejected(self):
        self.manifest["qaFeatures"] = True
        with self.assertRaises(RuntimeError):
            self.verify()
        self.manifest["qaFeatures"] = False
        self.manifest["licenses"] = {"missingLicenseTexts": ["constructed-package"]}
        with self.assertRaises(RuntimeError):
            self.verify()

    def test_binary_symlink_rejected(self):
        original = self.work / "original"
        self.binary.rename(original)
        self.binary.symlink_to(original)
        with self.assertRaises(RuntimeError):
            self.verify()


if __name__ == "__main__":
    unittest.main()

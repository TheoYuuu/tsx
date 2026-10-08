#!/usr/bin/env python3
"""Verify embedded production code and rejection before any account access."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
IDENTIFIER = "com.theoyuuu.LumaxTranslate.CodexRuntime"


def run(arguments):
    return subprocess.run(arguments, check=True, capture_output=True, timeout=30)


def signature(path):
    result = run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)])
    return (result.stdout + result.stderr).decode()


def team(detail):
    return re.search(r"^TeamIdentifier=(.*)$", detail, re.MULTILINE).group(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--configuration", required=True, choices=("Debug", "Release"))
    args = parser.parse_args()
    run([sys.executable, str(ROOT / "Tools/CodexRuntime/package.py"),
         "--configuration", args.configuration, "--verify-only"])
    package = ROOT / ".build/CodexRuntime/package" / args.configuration
    manifest = json.loads((package / "package-manifest.json").read_text())
    helper = args.app / "Contents/Helpers/lumax-codex-runtime"
    if helper.is_symlink() or not helper.is_file():
        raise RuntimeError("Embedded helper must be a real executable file.")
    notices = args.app / "Contents/Resources/CodexThirdPartyNotices.txt"
    if notices.is_symlink() or hashlib.sha256(notices.read_bytes()).hexdigest() != manifest["noticesSHA256"]:
        raise RuntimeError("Embedded dependency notices differ from the audited package.")
    run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(helper)])
    details = signature(helper)
    if f"Identifier={IDENTIFIER}\n" not in details or not re.search(r"^CodeDirectory .*flags=.*\bruntime\b", details, re.MULTILINE):
        raise RuntimeError("Embedded helper has the wrong identity or lacks Hardened Runtime.")
    if team(details) != team(signature(args.app)):
        raise RuntimeError("Application and helper signing teams differ.")
    entitlements = run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(helper)]).stdout
    if entitlements and plistlib.loads(entitlements):
        raise RuntimeError("Production helper must have no entitlement exceptions.")
    arches = run(["/usr/bin/lipo", "-archs", str(helper)]).stdout.decode().strip().split()
    if set(arches) != set(manifest["architectures"]):
        raise RuntimeError("Embedded helper architecture mismatch.")
    app_arches = run(["/usr/bin/lipo", "-archs", str(args.app / "Contents/MacOS/TSX")]).stdout.decode().strip().split()
    if not set(app_arches).issubset(arches):
        raise RuntimeError("Embedded helper does not cover every application architecture.")
    # Signing can resize __LINKEDIT. Normalize disposable copies to the same
    # ad-hoc signature before removing it; never alter the verified application.
    with tempfile.TemporaryDirectory(prefix="bundle-verify-", dir=ROOT / ".build/CodexRuntime") as temporary:
        hashes = []
        for index, source in enumerate((package / "lumax-codex-runtime", helper)):
            copied = Path(temporary) / str(index)
            shutil.copyfile(source, copied)
            run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", IDENTIFIER,
                 "--options", "runtime", "--timestamp=none", str(copied)])
            run(["/usr/bin/codesign", "--remove-signature", str(copied)])
            hashes.append(hashlib.sha256(copied.read_bytes()).hexdigest())
        if hashes[0] != hashes[1]:
            raise RuntimeError("Embedded executable differs from the audited production package.")
        request = {"protocol_version": 1, "request_id": "98df57a7-c8c5-4bca-95b0-233f77b31b9d", "operation": "status"}
        expected = {"protocol_version": 1, "request_id": request["request_id"], "event": "terminal",
                    "result": {"status": "environment_rejected"}}
        checked = subprocess.run([str(helper.resolve())], input=json.dumps(request) + "\n", text=True,
            capture_output=True, timeout=5, cwd=temporary,
            env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": temporary,
                 "CODEX_HOME": "must-not-be-read"})
        if checked.returncode != 0 or checked.stderr or json.loads(checked.stdout) != expected:
            raise RuntimeError("Embedded helper failed rejection before account access.")
    print(f"{args.configuration}: embedded code, notices, architecture, signing and account-free rejection passed.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Bundle verification failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None

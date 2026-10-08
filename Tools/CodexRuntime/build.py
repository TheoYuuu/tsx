#!/usr/bin/env python3
"""Build/test the pinned runtime and executable without account or host-policy access."""

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import platform
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Runtime/CodexHelper"
WORK = ROOT / ".build/CodexRuntime"
AUDITOR = ROOT / "Tools/QA/CodexTranslationProbe/verify.py"
spec = importlib.util.spec_from_file_location("codex_source_audit", AUDITOR)
common = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(common)


def inputs():
    paths = [SOURCE / "Cargo.toml", SOURCE / "Cargo.lock", *sorted((SOURCE / "src").rglob("*.rs"))]
    result = {}
    for path in paths:
        if path.resolve(strict=True) != path:
            raise RuntimeError("Runtime input must not use a symlink.")
        common.regular_file(path, common.MAX_FILE)
        result[str(path.relative_to(SOURCE))] = path.read_bytes()
    return result


def local_directory(value):
    """Build caches stay in this repository, never a developer's global Cargo home."""
    path = value.absolute()
    if not path.is_relative_to(ROOT / ".build") or path.resolve() != path:
        raise RuntimeError("Use a real cache directory under this repository's .build.")
    common.directory(path)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cargo", required=True, type=Path)
    parser.add_argument("--cargo-home", type=Path, default=WORK / "cargo-home")
    parser.add_argument("--target-dir", type=Path, default=WORK / "target")
    args = parser.parse_args()
    cargo = args.cargo.resolve(strict=True)
    rustc = cargo.with_name("rustc")
    if not rustc.is_file():
        parser.error("Provide the existing private Cargo with its sibling rustc.")
    common.directory(WORK)
    with os.fdopen(os.open(WORK / "build.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "r+") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise RuntimeError("Build lock is not a regular file.")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        frozen = inputs()
        native_inputs = {path: path.read_bytes() for path in (
            ROOT / "LumaxTranslate/Translation/Services/Codex/CodexRuntimeSession.swift",
            ROOT / "Tools/CodexRuntime/native_smoke.swift")}
        evidence = Path(tempfile.mkdtemp(prefix="build-", dir=common.directory(WORK / "builds")))
        print(f"Runtime evidence: {evidence}", flush=True)
        # The audited downloader/cache can be shared; extracted runtime sources
        # have their own tree and are checked in full both before and after build.
        archive_path = common.archive_path()
        source_parent = common.directory(WORK / "source")
        with tarfile.open(archive_path, "r:gz") as archive:
            members = common.audited_members(archive)
            if not (source_parent / common.SOURCE_NAME).exists():
                common.extract_source(archive, members, source_parent)
            source_manifest = common.check_source(archive, members, source_parent)
        env = common.build_environment(cargo)
        env["CARGO_HOME"] = str(local_directory(args.cargo_home))
        env["CARGO_TARGET_DIR"] = str(local_directory(args.target_dir))
        env["RUSTUP_HOME"] = str(common.directory(WORK / "rustup-home"))
        env["TMPDIR"] = str(common.directory(WORK / "tmp"))
        # No cargo config/credentials in any ancestor of the frozen crate.
        for directory in (ROOT / ".cargo", ROOT / ".build/.cargo", WORK / ".cargo", Path(env["CARGO_HOME"])):
            for name in ("config", "config.toml", "credentials", "credentials.toml"):
                if (directory / name).exists() or (directory / name).is_symlink():
                    raise RuntimeError("Runtime build refuses ambient Cargo configuration or credentials.")
        for executable, name in ((cargo, "cargo"), (rustc, "rustc")):
            log = evidence / f"{name}-version.log"
            common.run([str(executable), "--version"], WORK, env, log, 15)
            if not re.match(rf"{name} 1\.95\.\d+\b", log.read_text()):
                raise RuntimeError("The pinned runtime requires the private 1.95 toolchain.")
        staged = Path(tempfile.mkdtemp(prefix="staged-helper-", dir=WORK))
        for name, data in frozen.items():
            path = staged / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (evidence / "inputs.json").write_text(json.dumps({name: hashlib.sha256(data).hexdigest() for name, data in frozen.items()}, indent=2) + "\n")
        (evidence / "source-integrity.json").write_text(json.dumps({"commit": common.COMMIT, "archiveSHA256": common.SOURCE_SHA256, "members": source_manifest}, indent=2) + "\n")
        (evidence / "tools.json").write_text(json.dumps({"build.py": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "sourceAuditor": hashlib.sha256(AUDITOR.read_bytes()).hexdigest()}, indent=2) + "\n")
        # Real fork/pre-exec fixtures share this test process's FD table. Run
        # them serially so another fixture's pre-exec child cannot temporarily
        # retain its neighbor's CLOEXEC lease. Production has one root/request
        # per process; dedicated child-process tests still assert contention.
        command = [str(cargo), "test", "--locked", "--offline", "--manifest-path", str(staged / "Cargo.toml"), "--", "--test-threads=1"]
        common.run(command, staged, env, evidence / "tests.log", 900)
        common.run([str(cargo), "build", "--locked", "--offline", "--bin", "lumax-codex-runtime",
                    "--manifest-path", str(staged / "Cargo.toml")], staged, env, evidence / "executable-build.log", 900)
        executable = evidence / "lumax-codex-runtime"
        shutil.copyfile(Path(env["CARGO_TARGET_DIR"]) / "debug/lumax-codex-runtime", executable)
        executable.chmod(0o700)
        # These requests must fail before account_root() or runtime creation.
        # They exercise the real executable without touching a host identity.
        request = {"protocol_version": 1, "request_id": "98df57a7-c8c5-4bca-95b0-233f77b31b9d", "operation": "status"}
        launch_env = {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": str(WORK / "tmp")}
        rejected_env = dict(launch_env, CODEX_HOME="must-not-be-read")
        checked = subprocess.run([str(executable)], input=json.dumps(request) + "\n", text=True,
                                 capture_output=True, timeout=5, cwd=evidence, env=rejected_env)
        expected = {"protocol_version": 1, "request_id": request["request_id"], "event": "terminal",
                    "result": {"status": "environment_rejected"}}
        if checked.returncode != 0 or checked.stderr or json.loads(checked.stdout) != expected:
            raise RuntimeError("Executable environment rejection failed.")
        for payload in (json.dumps(dict(request, issuer="https://constructed.invalid")) + "\n",
                        json.dumps(request), "x" * (512 * 1024 + 1)):
            checked = subprocess.run([str(executable)], input=payload, text=True, capture_output=True,
                                     timeout=5, cwd=evidence, env=launch_env)
            if checked.returncode != 64 or checked.stdout or checked.stderr:
                raise RuntimeError("Executable rejected-input boundary failed.")
        native_sources = []
        for path, data in native_inputs.items():
            destination = evidence / path.name
            destination.write_bytes(data)
            native_sources.append(str(destination))
        sdk = subprocess.run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
                             capture_output=True, check=True, text=True, timeout=15, env=launch_env).stdout.strip()
        native = evidence / "native-smoke"
        common.run(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-strict-concurrency=complete", "-warnings-as-errors", "-sdk", sdk,
                    "-target", f"{platform.machine()}-apple-macos15.0", *native_sources, "-o", str(native)],
                   evidence, launch_env, evidence / "native-build.log", 120)
        common.run([str(native), str(executable), str(evidence)], evidence, launch_env, evidence / "native-boundary.log", 30)
        (evidence / "native-inputs.json").write_text(json.dumps({str(path.relative_to(ROOT)): hashlib.sha256(data).hexdigest()
            for path, data in native_inputs.items()}, indent=2) + "\n")
        if any(path.read_bytes() != data for path, data in native_inputs.items()):
            raise RuntimeError("Native bridge inputs changed during the build.")
        if inputs() != frozen or any((staged / name).read_bytes() != data for name, data in frozen.items()):
            raise RuntimeError("Runtime inputs changed; this result covers only frozen inputs.")
        with archive_path.open("rb") as stream:
            if common.digest(stream) != common.SOURCE_SHA256:
                raise RuntimeError("Pinned source archive changed.")
        with tarfile.open(archive_path, "r:gz") as archive:
            common.check_source(archive, common.audited_members(archive), source_parent)
        (evidence / "result.json").write_text(json.dumps({"passed": True, "host": sys.platform,
            "executable": executable.name, "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "executableBoundaryCases": 4, "nativeBoundaryCases": 5,
            "accountAccess": False, "packagedInApp": False}, indent=2) + "\n")
        print("Runtime tests, executable build and nine account-free boundary cases passed. No account, hosted policy, or application packaging was exercised.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, tarfile.TarError, subprocess.TimeoutExpired) as error:
        print(f"Runtime build failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None

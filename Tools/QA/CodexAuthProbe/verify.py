#!/usr/bin/env python3
"""Build a pinned Codex login probe and test only newly constructed local identities."""

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
WORK = REPO / ".build/QA/CodexAuthPrototype"
INPUTS = ("Cargo.toml", "Cargo.lock", "src/main.rs", "src/auth_policy.rs", "fixtures/fake_issuer.py",
          "fixtures/test_fake_issuer.py", "fixtures/probe.py", "fixtures/test_session_protocol.py",
          "native/CodexAuthSession.swift", "native/NativeSessionProbe.swift", "native/test_native_host.py")
SHARED_INPUTS = {
    "src/sse_guard.rs": REPO / "Runtime/CodexHelper/src/sse_guard.rs",
    "src/translation.rs": HERE.parent / "CodexTranslationProbe/src/translation.rs",
    "src/account_request.rs": REPO / "Runtime/CodexHelper/src/account_request.rs",
}
IDENTIFIER = "com.theoyuuu.LumaxTranslate.QA.CodexAuth"

# Share the source archive audit rather than maintaining two subtly different
# extractors. Import has no build, network, login, or filesystem side effects.
spec = importlib.util.spec_from_file_location(
    "codex_probe_build", HERE.parent / "CodexTranslationProbe/verify.py")
common = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(common)


def inputs(include_native=True):
    result = {}
    for name in (*INPUTS, *SHARED_INPUTS):
        if not include_native and name.startswith("native/"):
            continue
        path = SHARED_INPUTS.get(name, HERE / name)
        if path.resolve(strict=True) != path:
            raise RuntimeError("Probe inputs must be ordinary tracked files.")
        common.regular_file(path, common.MAX_FILE)
        result[name] = path.read_bytes()
    return result


def stop_harness(process):
    """Stop the harness and its private helper sessions on forced timeout."""
    if process.poll() is not None:
        return
    # The harness launches each helper in a new session so it can stop that
    # operation independently. Stop new spawns before inspecting only its
    # direct children; these are our helpers, not unrelated desktop processes.
    try:
        process.send_signal(signal.SIGSTOP)
    except ProcessLookupError:
        return
    try:
        children = subprocess.run(["/usr/bin/pgrep", "-P", str(process.pid)],
                                  capture_output=True, timeout=2,
                                  env={"PATH": "/usr/bin:/bin"})
        if children.returncode not in (0, 1):
            raise RuntimeError("Could not enumerate this harness's remaining helper sessions.")
        for child in children.stdout.splitlines():
            if not child.isdigit():
                raise RuntimeError("Unexpected helper process identifier.")
            pid = int(child)
            try:
                os.kill(pid, signal.SIGSTOP)
                # The forked child can be completing setsid independently of
                # its stopped parent. Group/session are separate observations;
                # retry a mixed snapshot of that one startup transition.
                group = session = None
                for _ in range(3):
                    group, session = os.getpgid(pid), os.getsid(pid)
                    if (group, session) in ((pid, pid), (process.pid, process.pid)):
                        break
                if group == pid and session == pid:
                    os.killpg(pid, signal.SIGKILL)
                elif group == process.pid and session == process.pid:
                    # The fork may not have reached setsid yet. Its unreaped
                    # PID cannot be reused while the stopped harness owns it.
                    os.kill(pid, signal.SIGKILL)
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                else:
                    raise RuntimeError("A harness child is not the expected private helper session.")
            except ProcessLookupError:
                pass
    finally:
        process.kill()
        process.wait(timeout=5)


def fixture_run(command, env, log, *, timeout=900, cleanup_timeout=30):
    """Let the harness reap its children and remove its exact Keychain items."""
    with log.open("xb") as output:
        process = subprocess.Popen(command, cwd=WORK, env=env,
                                   stdin=subprocess.DEVNULL, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            # Do not signal the whole group here: its harness owns the cleanup
            # workers. A remaining identity is recorded, never silently erased.
            process.terminate()
            try:
                process.wait(timeout=cleanup_timeout)
            except subprocess.TimeoutExpired:
                stop_harness(process)
                print("Cleanup did not finish; inspect this run's identity inventory.",
                      file=sys.stderr)
            raise
    if code:
        raise RuntimeError(f"Local auth fixtures failed ({code}); inspect {log}.")


def environment_preflight(binary, evidence):
    """Exercise startup rejection before any credential read or network request."""
    baseline = {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": str(WORK / "tmp")}
    # CoreFoundation rewrites supplied CF encoding values before main. Wrong
    # UID / oversized launch values cannot exercise the Rust value guard; do
    # not mislabel those ineffective injections as rejection coverage.
    cases = (
        ("system_encoding", {}, "invalid_input"),
        ("access_token", {"CODEX_ACCESS_TOKEN": "fixture-environment-sentinel"}, "environment_rejected"),
        ("proxy", {"HTTPS_PROXY": "fixture-environment-sentinel"}, "environment_rejected"),
    )
    results = []
    for name, extra, expected in cases:
        result = subprocess.run([str(binary)], input=b"{}", capture_output=True,
                                env={**baseline, **extra}, cwd=WORK, timeout=5)
        try:
            value = json.loads(result.stdout)
        except ValueError:
            value = {}
        passed = (result.returncode == 0 and not result.stderr and value.get("status") == expected
                  and b"fixture-environment-sentinel" not in result.stdout)
        results.append({"case": name, "status": value.get("status"), "passed": passed})
    # A caller cannot bypass the supervisor and let a model worker select the
    # real refresh endpoint by omitting its fixture-owned override. The empty
    # canonical directory is removed after rejection; no credential is created.
    with tempfile.TemporaryDirectory(prefix="environment-", dir=common.directory(WORK / "runtime")) as home:
        request = {"operation": "authenticated_translate", "identity_home": home,
                   "issuer": "http://127.0.0.1:1", "text": "Constructed sample."}
        for name, extra in (("worker_missing_refresh_route", {}),
                            ("worker_wrong_refresh_route", {"CODEX_REFRESH_TOKEN_URL_OVERRIDE": "http://127.0.0.1:2/oauth/token"})):
            result = subprocess.run([str(binary), "--worker"], input=json.dumps(request).encode(),
                                    capture_output=True, env={**baseline, **extra}, cwd=WORK, timeout=5)
            try:
                value = json.loads(result.stdout)
            except ValueError:
                value = {}
            passed = result.returncode == 0 and not result.stderr and value.get("status") == "environment_rejected"
            results.append({"case": name, "status": value.get("status"), "passed": passed})
    (evidence / "environment-preflight.json").write_text(json.dumps(results, indent=2) + "\n")
    if not all(row["passed"] for row in results):
        raise RuntimeError("Environment preflight failed before creating any fixture identities.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cargo", required=True, type=Path,
                        help="Existing Cargo 1.95 executable with sibling rustc 1.95.")
    parser.add_argument("--signing-identity", required=True,
                        help="Existing local signing certificate SHA-1; no certificate is created.")
    parser.add_argument("--without-native", action="store_true",
                        help="Run authentication/model fixtures without Swift host compilation or cases.")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("The real Keychain fixtures require macOS.")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.signing_identity):
        parser.error("Provide the SHA-1 of an existing signing identity.")
    cargo = args.cargo.expanduser().resolve(strict=True)
    rustc = cargo.with_name("rustc")
    for executable in (cargo, rustc):
        if not executable.is_file() or not os.access(executable, os.X_OK):
            parser.error("Cargo and its sibling rustc must already be executable.")
    frozen = inputs(not args.without_native)
    common.directory(WORK)
    with os.fdopen(os.open(WORK / "verify.lock",
                          os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "r+") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise RuntimeError("Verification lock must be a regular file.")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another auth probe verification is running.") from None

        evidence = Path(tempfile.mkdtemp(prefix="verify-", dir=common.directory(WORK / "builds")))
        print(f"Auth verification evidence: {evidence}", flush=True)
        env = common.build_environment(cargo)
        for key, name in (("CARGO_HOME", "cargo-home"), ("RUSTUP_HOME", "rustup-home"),
                          ("CARGO_TARGET_DIR", "target"), ("TMPDIR", "tmp")):
            env[key] = str(common.directory(WORK / name))
        for directory in (WORK / ".cargo", WORK / "cargo-home"):
            for name in ("config", "config.toml", "credentials", "credentials.toml"):
                path = directory / name
                if path.exists() or path.is_symlink():
                    raise RuntimeError("Auth probe build directory contains Cargo configuration or credentials.")
        for executable, name in ((cargo, "cargo"), (rustc, "rustc")):
            log = evidence / f"{name}-version.log"
            common.run([str(executable), "--version"], WORK, env, log, 15)
            if not re.match(rf"{name} 1\.95\.\d+\b", log.read_text()):
                raise RuntimeError("Existing Cargo and rustc 1.95 are required.")

        archive_path = common.archive_path()
        source_parent = common.directory(common.WORK / "source")
        with tarfile.open(archive_path, "r:gz") as archive:
            members = common.audited_members(archive)
            source = source_parent / common.SOURCE_NAME
            if not source.exists() and not source.is_symlink():
                common.extract_source(archive, members, source_parent)
            manifest = common.check_source(archive, members, source_parent)
        (evidence / "source-integrity.json").write_text(json.dumps({
            "commit": common.COMMIT, "archiveSHA256": common.SOURCE_SHA256,
            "members": manifest,
        }, indent=2) + "\n")

        staged = Path(tempfile.mkdtemp(prefix="staged-app-", dir=WORK))
        hashes = {}
        for name, data in frozen.items():
            destination = staged / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            hashes[name] = hashlib.sha256(data).hexdigest()
        (evidence / "inputs.json").write_text(json.dumps(hashes, indent=2) + "\n")
        (evidence / "verification-tools.json").write_text(json.dumps({
            "verify.py": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "nativeHostIncluded": not args.without_native,
            "CodexTranslationProbe/verify.py": hashlib.sha256(Path(spec.origin).read_bytes()).hexdigest(),
        }, indent=2) + "\n")
        common.run([str(cargo), "build", "--locked", "--manifest-path", str(staged / "Cargo.toml")],
                   staged, env, evidence / "build.log", 900)
        common.run([str(cargo), "test", "--locked", "--offline", "--manifest-path", str(staged / "Cargo.toml")],
                   staged, env, evidence / "rust-unit-tests.log", 120)
        if inputs(not args.without_native) != frozen or any((staged / name).read_bytes() != data for name, data in frozen.items()):
            raise RuntimeError("Probe inputs changed during compilation; freeze inputs and retry.")
        with archive_path.open("rb") as stream:
            if common.digest(stream) != common.SOURCE_SHA256:
                raise RuntimeError("Source archive changed during compilation.")
        with tarfile.open(archive_path, "r:gz") as archive:
            common.check_source(archive, common.audited_members(archive), source_parent)

        built = WORK / "target/debug/lumax-codex-auth-prototype"
        common.regular_file(built, 256 * 1024 * 1024)
        binary = evidence / "lumax-codex-auth-prototype"
        binary.write_bytes(built.read_bytes())
        binary.chmod(0o700)
        common.run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none",
                    "--identifier", IDENTIFIER, "--sign", args.signing_identity, str(binary)],
                   WORK, env, evidence / "sign.log", 30)
        common.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)],
                   WORK, env, evidence / "signature-check.log", 15)
        common.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(binary)],
                   WORK, env, evidence / "signature.log", 15)
        signature = (evidence / "signature.log").read_text()
        if (f"Identifier={IDENTIFIER}\n" not in signature
                or not re.search(r"^CodeDirectory .*flags=.*\(.*runtime.*\)", signature, re.M)
                or "TeamIdentifier=not set" in signature):
            raise RuntimeError("QA helper signing identity or Hardened Runtime is missing.")
        (evidence / "binary.json").write_text(json.dumps({
            "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "identifier": IDENTIFIER,
            "sourceCommit": common.COMMIT, "productionHelper": False,
        }, indent=2) + "\n")

        environment_preflight(binary, evidence)

        native_arguments = []
        if not args.without_native:
            native = evidence / "native-session-probe"
            common.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                        str(staged / "native/CodexAuthSession.swift"), str(staged / "native/NativeSessionProbe.swift"),
                        "-o", str(native)], WORK, env, evidence / "native-build.log", 60)
            common.run([sys.executable, "-I", "-B", str(staged / "native/test_native_host.py"), str(native)],
                       WORK, env, evidence / "native-host-tests.log", 60)
            (evidence / "native-binary.json").write_text(json.dumps({
                "sha256": hashlib.sha256(native.read_bytes()).hexdigest(), "productionHelper": False,
                "strictSwiftConcurrency": True, "accessesKeychainDirectly": False,
            }, indent=2) + "\n")

            native_arguments = ["--native-binary", str(native)]

        common.run([sys.executable, "-I", str(staged / "fixtures/test_fake_issuer.py")],
                   WORK, env, evidence / "fixture-self-tests.log", 30)
        common.run([sys.executable, "-I", "-B", str(staged / "fixtures/test_session_protocol.py")],
                   WORK, env, evidence / "session-protocol-tests.log", 30)
        fixture_run([sys.executable, "-I", str(staged / "fixtures/probe.py"),
                     "--binary", str(binary), *native_arguments,
                     "--output-root", str(common.directory(WORK / "runtime"))],
                    env, evidence / "fixtures.log")
        if inputs(not args.without_native) != frozen:
            raise RuntimeError("Probe inputs changed during verification; recorded results cover frozen inputs only.")
        print(f"Constructed-identity checks finished; inspect {evidence / 'fixtures.log'}.")
        print("This does not validate real ChatGPT login, entitlement, quota, or model compatibility.")
    return 0


if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Auth probe interrupted; inspect the fixture cleanup report before retrying.", file=sys.stderr)
        raise SystemExit(130) from None
    except (OSError, RuntimeError, tarfile.TarError, subprocess.TimeoutExpired) as error:
        print(f"Auth verification failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None

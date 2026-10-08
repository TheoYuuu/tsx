#!/usr/bin/env python3
"""Sign and run constructed-only worker/Keychain QA, then verify exact cleanup.

The binary is compiled from worker_smoke.rs inside build.py's staged crate.
This driver never invokes the production helper or reads a default Codex home.
Only its new signed binary copy and its fresh registered fixture identities run.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import uuid


ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / ".build" / "CodexRuntime" / "worker-smoke"
CERTIFICATE = "F500F2108BFF053E42453451D07BB3272A1C1DE4"
IDENTIFIER = "com.theoyuuu.LumaxTranslate.QA.CodexWorkerSmoke"
CHECKS = {
    "status_constructed_signed_in": "signed_in",
    "status_strict_absence": "signed_out",
    "status_rejects_other_registered_home": "invalid_account_storage",
    "independent_descriptor_cannot_bypass_lease": "busy",
    "pending_logout_cleanup_deletes_exact_key": "signed_out",
    "pending_cleanup_is_idempotent": "signed_out",
    "cleanup_cannot_delete_committed_login": "invalid_account_storage",
}
STATUSES = set(CHECKS.values()) | {"unexpected_status"}
FAILURES = {
    "fixture_directory_unavailable", "fixture_directory_rejected",
    "registry_unavailable", "registry_rejected", "invalid_build_location",
    "invalid_run_path", "fixture_keyring_unavailable", "fixture_construction_failed",
    "fixture_storage_unavailable", "fixture_identity_not_empty", "fixture_save_missing",
    "fixture_lease_unavailable", "fixture_executable_unavailable", "fixture_spawn_failed",
    "fixture_pipe_failed", "fixture_serialization_failed", "fixture_reap_failed",
    "fixture_worker_failed", "fixture_worker_timeout", "fixture_invalid_output",
    "fixture_status_mutated_storage", "fixture_wrong_home_mutated_storage",
    "fixture_lease_mutated_storage", "fixture_cleanup_left_key",
    "fixture_committed_key_deleted", "fixture_cleanup_busy", "fixture_cleanup_failed",
    "fixture_cleanup_incomplete",
}


def canonical_uuid(value):
    try:
        parsed = uuid.UUID(value)
        return bool(parsed.int) and str(parsed) == value
    except (ValueError, TypeError, AttributeError):
        return False


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def private_directory(path, create=False):
    if create:
        path.mkdir(mode=0o700)
    metadata = path.lstat()
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or stat.S_IMODE(metadata.st_mode) != 0o700 or path.resolve() != path):
        raise ValueError("fixture_directory_rejected")


def kill_and_reap(process):
    # Popen starts a private session; only this driver's process group is killed.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def capture(command, environment, timeout, cwd):
    process = subprocess.Popen(command, cwd=cwd, env=environment,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        output, errors = process.communicate(timeout=timeout)
        return process.returncode, output, errors
    except BaseException:
        kill_and_reap(process)
        raise


def parse_report(output, cleanup_only):
    # Raw output never reaches a log, including when the helper misbehaves.
    if len(output) > 32 * 1024:
        raise ValueError("invalid_report")
    value = json.loads(output)
    fields = {"schema", "passed", "authorization_ui_disabled", "network_operations",
              "real_account_access", "checks", "registered_identities",
              "confirmed_absent", "cleanup_complete", "failure"}
    if not isinstance(value, dict) or set(value) != fields or value["schema"] != 1:
        raise ValueError("invalid_report")
    for field in ("passed", "authorization_ui_disabled", "real_account_access", "cleanup_complete"):
        if type(value[field]) is not bool:
            raise ValueError("invalid_report")
    for field in ("network_operations", "registered_identities", "confirmed_absent"):
        if type(value[field]) is not int or not 0 <= value[field] <= 16:
            raise ValueError("invalid_report")
    if (value["network_operations"] != 0 or value["real_account_access"]
            or not value["authorization_ui_disabled"]
            or value["failure"] is not None and value["failure"] not in FAILURES):
        raise ValueError("invalid_report")
    checks = value["checks"]
    if not isinstance(checks, list) or len(checks) > len(CHECKS) or cleanup_only and checks:
        raise ValueError("invalid_report")
    seen = set()
    for check in checks:
        if (not isinstance(check, dict)
                or set(check) != {"name", "expected_status", "observed_status", "passed"}
                or check["name"] not in CHECKS or check["name"] in seen
                or check["expected_status"] != CHECKS[check["name"]]
                or check["observed_status"] not in STATUSES or type(check["passed"]) is not bool
                or check["passed"] != (check["observed_status"] == check["expected_status"])):
            raise ValueError("invalid_report")
        seen.add(check["name"])
    complete = (value["cleanup_complete"] and value["registered_identities"] == value["confirmed_absent"]
                and value["failure"] is None)
    if value["passed"] and (not complete or not cleanup_only and
                            (seen != set(CHECKS) or not all(check["passed"] for check in checks))):
        raise ValueError("invalid_report")
    return value


def runtime_contains_metadata_only(run):
    """Inspect only newly created runtime metadata; never read credential stores."""
    runtime = run / "runtime"
    if not runtime.exists():
        return False
    try:
        private_directory(runtime)
        registry = json.loads((run / "identities.json").read_bytes())
        entries = registry["identities"]
        known = {entry["case_id"]: entry["generation"] for entry in entries}
        if not 1 <= len(known) <= 16 or len(known) != len(entries):
            return False
        for path in runtime.rglob("*"):
            metadata = path.lstat()
            relative = path.relative_to(runtime).parts
            if relative[0] not in known or not canonical_uuid(relative[0]):
                return False
            if stat.S_ISDIR(metadata.st_mode):
                if len(relative) == 2 and relative[1] != "identities":
                    return False
                if len(relative) == 3 and relative[1:] != ("identities", known[relative[0]]):
                    return False
                if len(relative) > 3:
                    return False
                private_directory(path)
                continue
            if (not stat.S_ISREG(metadata.st_mode) or len(relative) != 2
                    or relative[1] not in {"account.lock", "active.json", "pending.json"}
                    or metadata.st_size > 4096 or metadata.st_nlink != 1):
                return False
            content = path.read_bytes()
            if relative[1] == "account.lock":
                if content:
                    return False
                continue
            value = json.loads(content)
            keys = {"schema", "generation"} if relative[1] == "active.json" else {
                "schema", "kind", "operation_id", "generation"}
            if (set(value) != keys or value["schema"] != 1
                    or value["generation"] != known[relative[0]]):
                return False
            if relative[1] == "pending.json" and (value["kind"] not in {"login", "logout"}
                                                  or not canonical_uuid(value["operation_id"])):
                return False
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def interrupted(_signal, _frame):
    raise InterruptedError("interrupted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    arguments = parser.parse_args()
    binary = arguments.binary.absolute()
    metadata = binary.lstat()
    if not stat.S_ISREG(metadata.st_mode) or binary.resolve() != binary:
        raise ValueError("binary_rejected")
    WORK.mkdir(mode=0o700, parents=True, exist_ok=True)
    private_directory(WORK)
    run = WORK / f"run-{uuid.uuid4()}"
    private_directory(run, create=True)
    evidence = run / "evidence"
    private_directory(evidence, create=True)
    temporary = run / "tmp"
    private_directory(temporary, create=True)
    executable = evidence / "lumax-worker-smoke"
    shutil.copyfile(binary, executable)
    executable.chmod(0o755)
    environment = {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": str(temporary)}
    result = {"schema": 1, "passed": False, "constructed_credentials_only": True,
              "host_policy_read": False, "real_account_access": False,
              "remote_revocation_tested": False, "evidence_directory": str(evidence),
              "source_sha256": sha256(Path(__file__).with_suffix(".rs")),
              "input_binary_sha256": sha256(binary), "signed_copy_sha256": None,
              "signature_verified": False, "driver_report": None, "cleanup_report": None,
              "runtime_metadata_only": False, "failure": None}
    previous_term = signal.signal(signal.SIGTERM, interrupted)
    ready_to_run = False
    try:
        for command in (
            ["/usr/bin/codesign", "--force", "--sign", CERTIFICATE, "--identifier", IDENTIFIER,
             "--options", "runtime", "--timestamp=none", str(executable)],
            ["/usr/bin/codesign", "--verify", "--strict", str(executable)],
        ):
            code, _output, _errors = capture(command, environment, 30, run)
            if code != 0:
                raise ValueError("signature_failed")
        result["signature_verified"] = True
        result["signed_copy_sha256"] = sha256(executable)
        ready_to_run = True
        code, output, errors = capture([str(executable), "--run", str(run)], environment, 150, run)
        result["driver_report"] = parse_report(output, False)
        if code != 0 or errors or not result["driver_report"]["passed"]:
            result["failure"] = "driver_failed"
    except (KeyboardInterrupt, InterruptedError):
        result["failure"] = "interrupted"
    except subprocess.TimeoutExpired:
        result["failure"] = "driver_timeout"
    except (OSError, ValueError, TypeError):
        result["failure"] = "driver_or_signature_failed"
    finally:
        # Finish cleanup despite a repeated SIGTERM/Control-C. A hard kill is
        # outside this guarantee; the durable registry remains for exact retry.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        previous_int = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            if ready_to_run and (run / "identities.json").exists():
                code, output, errors = capture([str(executable), "--cleanup-run", str(run)],
                                               environment, 60, run)
                result["cleanup_report"] = parse_report(output, True)
                if code != 0 or errors or not result["cleanup_report"]["passed"]:
                    result["failure"] = "cleanup_failed"
            elif ready_to_run:
                # Registration precedes every save; no registry means no save.
                result["failure"] = result["failure"] or "driver_missing_registry"
        except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
            result["failure"] = "cleanup_failed"
        finally:
            signal.signal(signal.SIGINT, previous_int)
            signal.signal(signal.SIGTERM, previous_term)
        result["runtime_metadata_only"] = runtime_contains_metadata_only(run)
        result["passed"] = bool(result["failure"] is None and result["driver_report"]
                                and result["driver_report"]["passed"] and result["cleanup_report"]
                                and result["cleanup_report"]["passed"] and result["runtime_metadata_only"])
        destination = evidence / "result.json"
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as report:
            json.dump(result, report, ensure_ascii=False, indent=2)
            report.write("\n")
    print(f"{'PASS' if result['passed'] else 'FAIL'}: {evidence / 'result.json'}")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError):
        print("FAIL: worker smoke setup rejected", file=sys.stderr)
        sys.exit(2)

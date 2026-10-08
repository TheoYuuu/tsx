#!/usr/bin/env python3
"""Run only the coordinated, signed no-account auth helper against loopback.

No Rust/Keychain operations occur on import. Invocation is reserved for the root
verification wrapper after signature and source review. All credentials remain
in HTTP/IPC memory or the helper's exact randomly scoped Keychain test entries.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fake_issuer import EXCHANGE, POLL, USERCODE, RESPONSES, FakeIssuer

ALLOWED_STATUSES = {
    "device_code_ready", "device_code_failed", "cancelled", "login_failed", "storage_unavailable",
    "already_signed_in", "target_not_empty", "signed_in", "signed_out", "cleanup_required", "environment_rejected",
    "invalid_stored_auth", "unexpected_auth_method", "target_changed", "worker_failed", "identity_busy",
    "staging_failed", "ui_suppression_failed", "fixture_corrupted",
    "invalid_input", "invalid_process_output", "host_timeout", "output_limit",
    "invalid_control", "timed_out",
    "ok", "unauthorized", "invalid_or_incomplete_response", "managed_auth_denied",
    "managed_auth_or_storage_denied", "managed_policy_unavailable", "unsupported_managed_policy",
    "managed_network_denied", "auth_initialization_failed", "refresh_expired", "refresh_reused",
    "refresh_revoked", "refresh_rejected", "refresh_unavailable", "refresh_policy_denied",
    "refresh_incomplete", "identity_inconsistent", "replacement_signed_out", "invalid_fixture_home",
}
SUCCESS_SCENARIOS = ("success", "pending_403", "pending_404")
ERROR_SCENARIOS = (
    "device_disabled", "device_issuer_error", "device_malformed", "device_numeric_interval",
    "device_missing_code", "poll_denied", "poll_expired", "poll_malformed",
    "exchange_error_json", "exchange_error_text", "exchange_malformed", "invalid_id_token",
)


class Interrupted(Exception):
    pass


def atomic_write_json(path, value):
    # Serialize before opening any file. A killed writer can leave a temporary
    # file, but never a truncated previous identity manifest or report.
    payload = json.dumps(value, indent=2) + "\n"
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def stop_process_group(process):
    """Only a freshly spawned process's own session; never inspect other apps."""
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=0.4)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=2)
    # A supervisor can die before its worker; kill any remaining same-session
    # members even when its own PID is already reaped.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def bounded_invoke(binary, request, environment, cwd, *, timeout=15.0, require_status=True):
    payload = json.dumps(request).encode()
    if len(payload) > 8192:
        raise ValueError("fixture IPC request too large")
    output = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + timeout
    terminal = None
    selector = selectors.DefaultSelector()
    process = None
    try:
        process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd, env=environment,
            start_new_session=True, close_fds=True)
        process.stdin.write(payload)
        process.stdin.close()
        for name, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        while selector.get_map():
            if time.monotonic() >= deadline:
                terminal = "host_timeout"
                break
            for key, _events in selector.select(timeout=0.05):
                data = os.read(key.fileobj.fileno(), 8192)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                output[key.data].extend(data)
                if len(output[key.data]) > 65536:
                    terminal = "output_limit"
                    break
            if terminal is not None:
                break
        if terminal is None:
            process.wait(timeout=max(0.01, deadline - time.monotonic()))
        else:
            stop_process_group(process)
        try:
            result = json.loads(output["stdout"])
            if not isinstance(result, dict) or (require_status and result.get("status") not in ALLOWED_STATUSES):
                result = {"status": "invalid_process_output"}
        except (ValueError, UnicodeError):
            result = {"status": "invalid_process_output"}
        if terminal is not None:
            result = {"status": terminal}
        return result, bytes(output["stdout"]), bytes(output["stderr"]), process.returncode
    finally:
        selector.close()
        if process is not None:
            stop_process_group(process)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()


def session_event_checks(issuer, request_id, events):
    """Inspect in-memory events; never return a ready code in persisted evidence."""
    objects = all(isinstance(event, dict) for event in events)
    if not objects:
        return {"status": "invalid_process_output"}, {"event_objects": False}
    ready = [event for event in events if event.get("event") == "ready"]
    terminal = [event for event in events if event.get("event") == "terminal"]
    phases = [event.get("phase") for event in events if event.get("event") == "phase"]
    labels = [event.get("event") for event in events]
    private = False
    for event in events:
        safe = dict(event)
        if event.get("event") == "ready":
            private |= not issuer.valid_device_response(event)
            safe.pop("user_code", None)
            safe.pop("verification_url", None)
        private |= issuer.contains_secret(json.dumps(safe).encode())
    checks = {
        "event_schema": bool(events) and all(event.get("event") in ("ready", "phase", "terminal")
            and type(event.get("protocol_version")) is int and event.get("protocol_version") == 1
            and event.get("request_id") == request_id
            and event.get("authorization_ui_disabled") is True for event in events),
        "ready_at_most_once": len(ready) <= 1,
        "ready_code_matches_issuer": all(issuer.valid_device_response(event) for event in ready),
        "terminal_once_and_last": len(terminal) == 1 and labels[-1:] == ["terminal"],
        "phase_order": phases in ([], ["before_promotion"], ["before_promotion", "after_promotion"])
            and (not phases or labels[:1] == ["ready"]),
        "private_event_content_absent": not private,
        "terminal_status_known": len(terminal) == 1 and terminal[0].get("status") in ALLOWED_STATUSES,
    }
    return terminal[0] if len(terminal) == 1 else {"status": "invalid_process_output"}, checks


def output_closed_event_checks(issuer, request_id, events):
    _result, checks = session_event_checks(issuer, request_id, events)
    # BrokenPipe intentionally prevents terminal delivery. The earlier phase
    # events must still identify this request and the real saved-target boundary.
    checks.pop("terminal_once_and_last", None)
    checks.pop("terminal_status_known", None)
    checks["saved_target_phase_before_output_closed"] = [event.get("event") if isinstance(event, dict) else None for event in events] == ["ready", "phase", "phase"]
    checks["exact_saved_phase_order"] = [event.get("phase") for event in events if isinstance(event, dict) and event.get("event") == "phase"] == ["before_promotion", "after_promotion"]
    checks["no_terminal_before_output_closed"] = all(isinstance(event, dict) and event.get("event") != "terminal" for event in events)
    return checks


def bounded_session(binary, request, environment, cwd, issuer, *, action="none", trigger=None,
                    timeout=20.0, before_output_close=None):
    """Keep stdin open while collecting bounded NDJSON through natural exit."""
    output = {"stdout": bytearray(), "stderr": bytearray()}
    pending = bytearray()
    events = []
    facts = {"control_sent": False, "ready_while_input_open": False,
             "framing_valid": True, "natural_exit": False, "output_closed": False}
    process = None
    selector = selectors.DefaultSelector()
    deadline = time.monotonic() + timeout
    forced = None
    try:
        process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=cwd, env=environment, start_new_session=True, close_fds=True)
        process.stdin.write(json.dumps(request).encode() + b"\n")
        process.stdin.flush()
        for name, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        while selector.get_map():
            if time.monotonic() >= deadline:
                forced = "host_timeout"
                break
            reached = issuer.hold_entered.is_set() if trigger == "held" else any(
                event.get("event") == "phase" and event.get("phase") == trigger for event in events)
            if action != "none" and not facts["control_sent"] and reached:
                facts["control_sent"] = True
                if action == "output_closed":
                    if before_output_close is None:
                        raise ValueError("output-close fixture requires identity registration")
                    before_output_close()
                    selector.unregister(process.stdout)
                    process.stdout.close()
                    facts["output_closed"] = True
                elif action == "eof":
                    process.stdin.close()
                else:
                    control = {"operation": "cancel", "protocol_version": 1, "request_id": request["request_id"]}
                    if action == "wrong_id":
                        control["request_id"] = str(uuid.uuid4())
                    payload = b"{invalid-control\n" if action == "malformed" else b"x" * 4097 + b"\n" if action == "oversized" else json.dumps(control).encode() + b"\n"
                    process.stdin.write(payload)
                    process.stdin.flush()
            for key, _events in selector.select(timeout=0.02):
                data = os.read(key.fileobj.fileno(), 8192)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                output[key.data].extend(data)
                if len(output[key.data]) > 65536:
                    forced = "output_limit"
                    break
                if key.data != "stdout":
                    continue
                pending.extend(data)
                while b"\n" in pending:
                    line, _, remaining = pending.partition(b"\n")
                    pending[:] = remaining
                    try:
                        event = json.loads(line)
                        if not isinstance(event, dict) or len(line) > 32768:
                            raise ValueError("invalid event")
                        events.append(event)
                        if event.get("event") == "ready" and not process.stdin.closed:
                            facts["ready_while_input_open"] = True
                    except (ValueError, UnicodeError):
                        facts["framing_valid"] = False
                if len(pending) > 32768:
                    forced = "output_limit"
                    break
            if forced:
                break
        if forced is None:
            process.wait(timeout=max(0.01, deadline - time.monotonic()))
            facts["natural_exit"] = True
        facts["framing_valid"] &= not pending
        if forced is not None:
            facts["framing_valid"] = False
        return events, bytes(output["stdout"]), bytes(output["stderr"]), process.returncode, facts
    finally:
        selector.close()
        if process is not None:
            stop_process_group(process)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()


class Probe:
    def __init__(self, binary: Path, output_root: Path, native_binary=None):
        self.binary = binary.resolve(strict=True)
        self.native_binary = native_binary.resolve(strict=True) if native_binary else None
        self.output_root = output_root.resolve(strict=True)
        self.run = self.output_root / ("run-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:10])
        self.run.mkdir(mode=0o700)
        for name in ("identities", "child-home", "tmp", "workspace"):
            (self.run / name).mkdir(mode=0o700)
        self.identities = set()
        self.rows = []
        self.invocation_checks = []
        self.cleanup = []
        self.discovery_failed_homes = set()
        self.interrupted = False
        self.finished = False
        self.cleanup_complete = False
        self.environment = {
            "TMPDIR": str(self.run / "tmp"), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
        }
        self.write_manifest()

    def write_manifest(self):
        # This survives forced termination. Keep every identity directory until
        # precise logout AND signed_out have independently succeeded.
        value = {"schema_version": 1, "run": str(self.run), "accounts_used": False,
                 "identity_homes": sorted(str(path) for path in self.identities),
                 "cleanup": self.cleanup, "interrupted": self.interrupted,
                 "finished": self.finished, "cleanup_complete": self.cleanup_complete,
                 "cleanup_required": not self.cleanup_complete}
        atomic_write_json(self.run / "identity-manifest.json", value)

    def home(self, label):
        path = self.run / "identities" / (label + "-" + uuid.uuid4().hex)
        path.mkdir(mode=0o700)
        self.identities.add(path.resolve())
        self.write_manifest()
        return path

    def discover_stages(self):
        for base in sorted(self.identities):
            journal = base / ".pending-auth-cleanup.json"
            try:
                if journal.is_symlink():
                    raise ValueError("invalid cleanup journal")
                if not journal.exists():
                    continue
                if journal.stat().st_size > 4096:
                    raise ValueError("invalid cleanup journal")
                data = json.loads(journal.read_text(encoding="utf-8"))
                if (not isinstance(data, dict) or data.get("target_home") != str(base)
                        or data.get("target_initially_signed_out") is not True
                        or not isinstance(data.get("stage_home"), str)):
                    raise ValueError("cleanup journal target mismatch")
                self.register_stage(data["stage_home"])
            except (OSError, ValueError):
                # A damaged journal must not prevent the other exact registered
                # identities from being cleaned. Keep a sticky failure because
                # the damaged entry can conceal an unregistered stage identity.
                if base not in self.discovery_failed_homes:
                    self.discovery_failed_homes.add(base)
                    self.cleanup.append({"identity_home": str(base), "cleanup_required": True,
                                         "failure": "cleanup_journal_discovery_failed"})
        self.write_manifest()

    def register_stage(self, value):
        if not isinstance(value, str):
            return
        stage = Path(value)
        # The helper creates stage directories directly below its fixed runtime
        # root. Only names derived from this operation's own result/journal qualify.
        if not stage.is_absolute() or stage.parent != self.output_root or not stage.name.startswith("stage-") or stage.is_symlink():
            raise ValueError("stage escapes the allowed runtime root")
        uuid.UUID(stage.name.removeprefix("stage-"))
        if not stage.exists():
            # A helper may remove an already-cleaned empty stage directory.
            # Recreate the identical path for independent exact-key absence checks.
            stage.mkdir(mode=0o700)
        if stage.resolve(strict=True) != stage:
            raise ValueError("stage path is not canonical")
        self.identities.add(stage)

    def auth_json_absent(self):
        # Check only exact known target/stage paths, including sibling stages;
        # never scan another run or inspect auth-file contents.
        return all(not (home / "auth.json").exists() and not (home / "auth.json").is_symlink()
                   for home in self.identities)

    def invoke(self, issuer, operation, home, *, extra=None, env_extra=None, timeout=15.0):
        request = {"operation": operation, "identity_home": str(home), "issuer": issuer.issuer}
        if extra:
            request.update(extra)
        environment = dict(self.environment)
        if env_extra:
            environment.update(env_extra)
        started = time.monotonic()
        result, out, err, exit_code = bounded_invoke(self.binary, request, environment, self.run / "workspace", timeout=timeout)
        self.register_stage(result.get("stage_home"))
        self.discover_stages()
        # request_device_code intentionally returns its one-time code through
        # IPC; callers check it only in memory, never include it in a report.
        expected_code_output = operation == "request_device_code" and result.get("status") == "device_code_ready"
        if expected_code_output:
            remaining = {key: value for key, value in result.items() if key not in ("user_code", "verification_url")}
            private_stdout = not issuer.valid_device_response(result) or issuer.contains_secret(json.dumps(remaining).encode())
        elif operation == "authenticated_translate" and result.get("status") == "ok":
            remaining = {key: value for key, value in result.items() if key != "text"}
            private_stdout = not issuer.valid_translation_result(result) or issuer.contains_secret(json.dumps(remaining).encode())
        else:
            private_stdout = issuer.contains_secret(out)
        common = {"exit_zero": exit_code == 0, "stderr_empty": not err,
                  "stderr_private_content_absent": not issuer.contains_secret(err),
                  "stdout_private_content_absent": not private_stdout,
                  "authorization_ui_disabled": result.get("authorization_ui_disabled") is True}
        if env_extra:
            common["environment_sentinel_not_emitted"] = all(value.encode() not in out and value.encode() not in err for value in env_extra.values())
        self.invocation_checks.append(common)
        return result, common, round((time.monotonic() - started) * 1000)

    def add(self, case, result, checks, elapsed, issuer, *, authenticated_model=False):
        snapshot = issuer.snapshot()
        checks.update({"wire_contracts": snapshot["all_contracts_valid"],
                       "wire_authorization_policy": snapshot["headers_valid"] if authenticated_model else snapshot["authorization_header_absent"],
                       "wire_cookies_absent": snapshot["cookie_header_absent"],
                       "fixture_no_violation": not snapshot["violations"]})
        row = {"case": case, "status": result.get("status"), "checks": checks,
               "passed": all(checks.values()), "elapsed_ms": elapsed, "wire": snapshot}
        self.rows.append(row)
        print(json.dumps(row), flush=True)
        self.write_summary()

    def status(self, issuer, home, *, expected=None):
        extra = None
        if expected:
            extra = {"expected_account_id": expected["account_id"], "expected_user_id": expected["user_id"]}
        return self.invoke(issuer, "status", home, extra=extra)

    def session_case(self, phase="success", action="none", *, native=False):
        name = ("native_session_" if native else "session_") + phase + "_" + action
        if native and action != "none":
            name = "native_session_ready_" + action
        home = self.home(name)
        scenario = "cancel_" + phase if phase in ("usercode", "poll", "exchange") else "success"
        request = {"operation": "login_session", "protocol_version": 1,
                   "request_id": str(uuid.uuid4()), "identity_home": str(home), "deadline_ms": 6000}
        if phase in ("before_promotion", "after_promotion"):
            request["fixture_pause_" + phase + "_ms"] = 1000
        started = time.monotonic()
        with FakeIssuer(scenario) as issuer:
            request["issuer"] = issuer.issuer
            if native:
                payload = {"helper_path": str(self.binary), "request": request,
                           "action": "none" if action == "none" else action + "_ready"}
                response, out, err, exit_code = bounded_invoke(self.native_binary, payload,
                    self.environment, self.run / "workspace", timeout=35.0, require_status=False)
                events = response.get("events", [])
                if not isinstance(events, list):
                    events = []
                outer = {key: value for key, value in response.items() if key != "events"}
                facts = {"native_host_completed": response.get("host_status") == "completed",
                         "native_helper_reaped": response.get("helper_reaped") is True,
                         "native_helper_stderr_empty": response.get("stderr_empty") is True,
                         "native_outer_private_content_absent": not issuer.contains_secret(json.dumps(outer).encode())}
            else:
                events, out, err, exit_code, observed = bounded_session(self.binary, request,
                    self.environment, self.run / "workspace", issuer, action=action,
                    trigger="held" if phase in ("usercode", "poll", "exchange") else phase)
                facts = {"framing_valid": observed["framing_valid"],
                         "helper_exited_without_host_kill": observed["natural_exit"],
                         "control_delivered": action == "none" or observed["control_sent"],
                         "ready_delivered_before_input_closed": phase == "usercode" or observed["ready_while_input_open"]}
            result, checks = session_event_checks(issuer, request["request_id"], events)
            checks.update(facts)
            checks.update({"exit_zero": exit_code == 0, "stderr_empty": not err,
                           "stderr_private_content_absent": not issuer.contains_secret(err)})
            self.register_stage(result.get("stage_home"))
            self.discover_stages()
            expected = "signed_in" if action == "none" else "invalid_control" if action in ("malformed", "wrong_id", "oversized") else "cancelled"
            ready_count = sum(isinstance(event, dict) and event.get("event") == "ready" for event in events)
            counts = issuer.snapshot()["requests"]
            checks.update({"exact_terminal_status": result.get("status") == expected,
                           "ready_count": ready_count == (0 if phase == "usercode" else 1),
                           "one_code_request": counts.get(USERCODE) == 1,
                           "stage_cleaned": result.get("stage_cleanup_ok") is True,
                           "worker_reaped": result.get("worker_reaped") is True,
                           "one_exchange_at_most": counts.get(EXCHANGE, 0) <= 1})
            if action == "none":
                checks["exact_success_requests"] = counts == {USERCODE: 1, POLL: 1, EXCHANGE: 1}
                status, follow, _ = self.status(issuer, home, expected=issuer.expected_identity())
                checks["persisted_identity_matches"] = status.get("status") == "signed_in" and status.get("account_matches") is True and status.get("user_matches") is True
                checks["official_auth_header_present"] = status.get("auth_header_present") is True
            else:
                status, follow, _ = self.status(issuer, home)
                checks["no_target_identity"] = status.get("status") == "signed_out"
                checks["no_late_success"] = not any(isinstance(event, dict) and event.get("status") == "signed_in" for event in events)
                if phase in ("before_promotion", "after_promotion"):
                    checks["saved_stage_confirmed"] = result.get("stage_saved_confirmed") is True
                    checks["requested_phase_observed"] = any(isinstance(event, dict) and event.get("event") == "phase" and event.get("phase") == phase for event in events)
                if not native and phase in ("usercode", "poll", "exchange"):
                    checks["held_requested_phase"] = issuer.hold_entered.is_set()
                    checks["client_socket_closed"] = issuer.closed_during_hold.wait(0.8)
                    checks["exact_held_requests"] = counts == ({USERCODE: 1} if phase == "usercode" else {USERCODE: 1, POLL: 1} if phase == "poll" else {USERCODE: 1, POLL: 1, EXCHANGE: 1})
            checks.update({"followup_" + key: value for key, value in follow.items()})
            stage_home = result.get("stage_home")
            if isinstance(stage_home, str) and Path(stage_home) in self.identities:
                # Check before global cleanup_all performs any logout. Otherwise
                # that safety sweep could conceal a session's stage-cleanup bug.
                stage_status, stage_follow, _ = self.status(issuer, Path(stage_home))
                checks["stage_absent_before_cleanup_sweep"] = stage_status.get("status") == "signed_out"
                checks.update({"stage_status_" + key: value for key, value in stage_follow.items()})
            else:
                journal = home / ".pending-auth-cleanup.json"
                checks["stage_not_created_before_request"] = (counts.get(USERCODE, 0) == 0
                    and not journal.exists() and not journal.is_symlink())
            checks["auth_json_absent"] = self.auth_json_absent()
            self.invocation_checks.append(dict(checks))
            self.add(name, result, checks, round((time.monotonic() - started) * 1000), issuer)

    def output_closed_session_case(self):
        name = "session_output_closed_after_promotion"
        home = self.home(name)
        identities_before = set(self.identities)
        stages = set()

        def register_before_output_close():
            self.discover_stages()
            stages.update(self.identities - identities_before)
            if len(stages) != 1:
                raise ValueError("saved-session stage was not precisely registered")

        started = time.monotonic()
        with FakeIssuer() as issuer:
            request = {"operation": "login_session", "protocol_version": 1,
                       "request_id": str(uuid.uuid4()), "identity_home": str(home),
                       "issuer": issuer.issuer, "deadline_ms": 6000,
                       "fixture_pause_after_promotion_ms": 1000}
            events, _out, err, exit_code, facts = bounded_session(self.binary, request,
                self.environment, self.run / "workspace", issuer, action="output_closed",
                trigger="after_promotion", before_output_close=register_before_output_close)
            checks = output_closed_event_checks(issuer, request["request_id"], events)
            checks.update({"output_pipe_closed_after_stage_registered": facts["output_closed"] and len(stages) == 1,
                           "framing_valid_before_output_closed": facts["framing_valid"],
                           "ready_delivered_before_input_closed": facts["ready_while_input_open"],
                           "helper_exited_without_host_kill": facts["natural_exit"],
                           "exact_output_failure_exit": exit_code == 4,
                           "stderr_empty": not err,
                           "stderr_private_content_absent": not issuer.contains_secret(err),
                           "exact_success_requests": issuer.snapshot()["requests"] == {USERCODE: 1, POLL: 1, EXCHANGE: 1}})
            # No terminal can arrive on the intentionally closed pipe. Verify
            # both native identities before the final safety sweep deletes any.
            for label, identity in [("target", home)] + [("stage", path) for path in stages]:
                status, follow, _ = self.status(issuer, identity)
                checks[label + "_absent_before_cleanup_sweep"] = status.get("status") == "signed_out"
                checks.update({label + "_status_" + key: value for key, value in follow.items()})
            checks["auth_json_absent"] = self.auth_json_absent()
            self.invocation_checks.append(dict(checks))
            self.add(name, {"status": "output_closed"}, checks,
                     round((time.monotonic() - started) * 1000), issuer)

    def protocol_case(self, case):
        home = self.home(case)
        with FakeIssuer(case) as issuer:
            extra = {"deadline_ms": 1500} if case.startswith("cancel_") else None
            result, checks, elapsed = self.invoke(issuer, "complete_device_code_login", home, extra=extra)
            expected = "signed_in" if case in SUCCESS_SCENARIOS else "cancelled" if case.startswith("cancel_") else "device_code_failed" if case.startswith("device_") else "login_failed"
            checks["exact_status"] = result.get("status") == expected
            checks["stage_cleaned"] = result.get("stage_cleanup_ok") is True
            checks["worker_reaped"] = result.get("worker_reaped") is True
            counts = issuer.snapshot()["requests"]
            checks["one_code_request"] = counts.get(USERCODE) == 1
            checks["one_exchange_at_most"] = counts.get(EXCHANGE, 0) <= 1
            if case in SUCCESS_SCENARIOS:
                checks["exact_poll_count"] = counts.get(POLL) == (2 if case.startswith("pending_") else 1)
                checks["one_exchange"] = counts.get(EXCHANGE) == 1
                status, follow_checks, _ = self.status(issuer, home, expected=issuer.expected_identity())
                checks.update({"persisted_" + key: value for key, value in follow_checks.items()})
                checks["persisted_identity_matches"] = status.get("status") == "signed_in" and status.get("account_matches") is True and status.get("user_matches") is True
                checks["official_auth_header_present"] = status.get("auth_header_present") is True
            else:
                status, _, _ = self.status(issuer, home)
                checks["no_target_identity"] = status.get("status") == "signed_out"
            if case.startswith("cancel_"):
                # Observe while the fixture is still running, before our own
                # server shutdown can close its sockets.
                checks["held_requested_phase"] = issuer.hold_entered.is_set()
                checks["client_socket_closed"] = issuer.closed_during_hold.wait(0.8)
                checks["cancel_and_cleanup_bounded"] = elapsed < 8500
            checks["auth_json_absent"] = self.auth_json_absent()
            self.add(case, result, checks, elapsed, issuer)

    def environment_case(self):
        home = self.home("environment")
        sentinel = "TRANSLATEX_ENV_FIXTURE_" + uuid.uuid4().hex
        names = ("CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_API_KEY", "CODEX_APP_SERVER_LOGIN_CLIENT_ID",
                 "CODEX_REFRESH_TOKEN_URL_OVERRIDE", "CODEX_REVOKE_TOKEN_URL_OVERRIDE")
        with FakeIssuer() as issuer:
            result, checks, elapsed = self.invoke(issuer, "status", home, env_extra={name: sentinel for name in names})
            checks.update({"unsafe_environment_rejected": result.get("status") == "environment_rejected",
                           "no_auth_network": not issuer.snapshot()["requests"]})
            absent, normal_checks, _ = self.status(issuer, home)
            checks["clean_environment_still_signed_out"] = absent.get("status") == "signed_out" and all(normal_checks.values())
            self.add("environment_isolation", result, checks, elapsed, issuer)

    def redirect_case(self, external):
        name = "redirect_usercode_external" if external else "redirect_usercode"
        home = self.home(name)
        with FakeIssuer() as trap:
            with FakeIssuer(name, redirect_target=trap.issuer + "/forbidden-redirect" if external else None) as issuer:
                result, checks, elapsed = self.invoke(issuer, "complete_device_code_login", home)
                checks.update({"redirect_rejected": result.get("status") == "device_code_failed",
                               "only_initial_request": issuer.snapshot()["requests"] == {USERCODE: 1},
                               "other_port_received_nothing": not trap.snapshot()["requests"],
                               "stage_cleaned": result.get("stage_cleanup_ok") is True,
                               "worker_reaped": result.get("worker_reaped") is True})
                self.add(name, result, checks, elapsed, issuer)

    def saved_cancel_case(self):
        home = self.home("cancel-after-saved")
        with FakeIssuer() as issuer:
            result, checks, elapsed = self.invoke(issuer, "complete_device_code_login", home, extra={"cancel_after_saved": True})
            absent, _, _ = self.status(issuer, home)
            stage = Path(result["stage_home"]) if isinstance(result.get("stage_home"), str) else None
            stage_absent = self.status(issuer, stage)[0] if stage in self.identities else {}
            checks.update({"cancelled": result.get("status") == "cancelled",
                           "actual_stage_saved_before_cancel": result.get("stage_saved_confirmed") is True,
                           "stage_cleaned": result.get("stage_cleanup_ok") is True,
                           "worker_reaped": result.get("worker_reaped") is True,
                           "target_absent": absent.get("status") == "signed_out",
                           "stage_independently_absent": stage_absent.get("status") == "signed_out",
                           "exact_wire": issuer.snapshot()["requests"] == {USERCODE: 1, POLL: 1, EXCHANGE: 1},
                           "auth_json_absent": self.auth_json_absent()})
            self.add("cancel_after_saved_before_promotion", result, checks, elapsed, issuer)

    def malformed_storage_case(self):
        home = self.home("malformed-storage")
        with FakeIssuer() as issuer:
            created, checks, elapsed = self.invoke(issuer, "fixture_corrupt_storage", home)
            failed, _, _ = self.status(issuer, home)
            checks.update({"own_fixture_created": created.get("status") == "fixture_corrupted",
                           "official_load_reports_failure": failed.get("status") == "storage_unavailable",
                           "no_auth_json_fallback": self.auth_json_absent(),
                           "no_auth_network": not issuer.snapshot()["requests"]})
            # Independently prove the corrupt exact entry can be deleted before
            # continuing; the global finally repeats absence verification.
            deleted, _, _ = self.invoke(issuer, "logout", home)
            absent, _, _ = self.status(issuer, home)
            checks["corrupt_fixture_removed"] = deleted.get("status") == "signed_out" and absent.get("status") == "signed_out"
            self.add("malformed_exact_keychain_item_load_failure", failed, checks, elapsed, issuer)

    def request_only_case(self):
        home = self.home("request-only")
        with FakeIssuer() as issuer:
            result, checks, elapsed = self.invoke(issuer, "request_device_code", home)
            checks.update({"ready": result.get("status") == "device_code_ready",
                           "public_code_and_url_correct": issuer.valid_device_response(result),
                           "only_user_code_request": issuer.snapshot()["requests"] == {USERCODE: 1},
                           "auth_json_absent": self.auth_json_absent()})
            self.add("request_device_code_without_login", result, checks, elapsed, issuer)

    def isolated_homes_case(self):
        first = self.home("isolation-a")
        second = self.home("isolation-b")
        with FakeIssuer() as issuer_a, FakeIssuer() as issuer_b:
            result, checks, elapsed = self.invoke(issuer_a, "complete_device_code_login", first)
            checks["first_login"] = result.get("status") == "signed_in"
            vacant, _, _ = self.status(issuer_b, second)
            checks["second_does_not_read_first"] = vacant.get("status") == "signed_out"
            second_login, _, _ = self.invoke(issuer_b, "complete_device_code_login", second)
            checks["second_login"] = second_login.get("status") == "signed_in"
            first_deleted, _, _ = self.invoke(issuer_a, "logout", first)
            checks["first_logout"] = first_deleted.get("status") == "signed_out"
            first_absent, _, _ = self.status(issuer_a, first)
            checks["first_absent"] = first_absent.get("status") == "signed_out"
            retained, _, _ = self.status(issuer_b, second, expected=issuer_b.expected_identity())
            checks["second_untouched"] = retained.get("status") == "signed_in" and retained.get("account_matches") is True and retained.get("user_matches") is True
            checks["auth_json_absent"] = self.auth_json_absent()
            self.add("two_homes_do_not_read_or_delete_each_other", result, checks, elapsed, issuer_a)
            # Second issuer metadata is safe and separately preserved.
            (self.run / "isolation-second-wire.json").write_text(json.dumps(issuer_b.snapshot(), indent=2) + "\n")

    def authenticated_translation_case(self, scenario="success", *, policy="default", refresh=False,
                                       expected="ok", replacement=False):
        name = "authenticated_" + scenario + "_" + policy + ("_refresh" if refresh else "") + ("_replacement" if replacement else "")
        home = self.home(name)
        with FakeIssuer(scenario) as issuer:
            login, login_checks, _ = self.invoke(issuer, "complete_device_code_login", home)
            extra = {"text": issuer.translation_input(), "fixture_policy_case": policy,
                     "fixture_policy_workspace": issuer.expected_identity()["account_id"],
                     "fixture_refresh": refresh}
            if replacement:
                other = self.home(name + "-other")
                with FakeIssuer() as other_issuer:
                    other_login, other_checks, _ = self.invoke(other_issuer, "complete_device_code_login", other)
                    extra["fixture_replacement_home"] = str(other)
                    result, checks, elapsed = self.invoke(issuer, "authenticated_translate", home, extra=extra)
                    checks["other_login"] = other_login.get("status") == "signed_in" and all(other_checks.values())
                    checks["other_identity_not_sent_to_model"] = other_issuer.snapshot()["requests"] == {USERCODE: 1, POLL: 1, EXCHANGE: 1}
                    checks["other_wire_valid"] = other_issuer.snapshot()["all_contracts_valid"] and other_issuer.snapshot()["headers_valid"]
                    checks["replacement_secrets_absent"] = not other_issuer.contains_secret(json.dumps(result).encode())
            else:
                result, checks, elapsed = self.invoke(issuer, "authenticated_translate", home, extra=extra)
            wire = issuer.snapshot()
            model_calls = 1 if expected in ("ok", "unauthorized", "invalid_or_incomplete_response") and not replacement and scenario != "refresh_wrong_account" else 0
            refresh_calls = 1 if (refresh or scenario.startswith("expired_")) and policy == "default" else 0
            expected_wire = {USERCODE: 1, POLL: 1, EXCHANGE: 1 + refresh_calls}
            if model_calls:
                expected_wire[RESPONSES] = model_calls
            checks.update({"initial_login": login.get("status") == "signed_in" and all(login_checks.values()),
                           "expected_status": result.get("status") == expected,
                           "exact_model_and_auth_requests": wire["requests"] == expected_wire,
                           "refresh_grant_count": wire["oauth_grants"].get("refresh_token", 0) == refresh_calls,
                           "worker_reaped": result.get("worker_reaped") is True,
                           "translation_matches": issuer.valid_translation_result(result) if expected == "ok" else "text" not in result,
                           "auth_json_absent": self.auth_json_absent()})
            if "transport_attempts" in result:
                checks["one_or_zero_model_attempts"] = result["transport_attempts"] == model_calls
            if refresh or scenario.startswith("expired_"):
                facts = result.get("auth_checks", {})
                checks["explicit_refresh_call_count"] = facts.get("explicit_refresh_calls") == 1
                checks["refresh_completed_matches"] = facts.get("explicit_refresh_completed") is (scenario in ("success", "refresh_wrong_account", "refresh_wrong_account_only", "expired_access", "expired_refresh_still_expired"))
                checks["refresh_requested_matches"] = facts.get("explicit_refresh_requested") is refresh
                if scenario.startswith("expired_"):
                    checks["proactive_refresh_needed"] = facts.get("proactive_refresh_needed") is True
            if replacement:
                checks["replacement_applied"] = result.get("auth_checks", {}).get("replacement_applied") is True
                checks["old_anchor_rejected"] = result.get("auth_checks", {}).get("anchor_matches_after_preparation") is False
            self.add(name, result, checks, elapsed, issuer, authenticated_model=True)

    def cleanup_all(self):
        self.discover_stages()
        deadline = time.monotonic() + 25
        # A cleanup-only issuer should receive no network requests: local logout
        # must not accidentally invoke online revocation with a real endpoint.
        with FakeIssuer() as issuer:
            for home in sorted(self.identities):
                row = {"identity_home": str(home), "cleanup_required": True}
                if deadline - time.monotonic() < 3:
                    row["failure"] = "cleanup_deadline"
                    self.cleanup.append(row)
                    self.write_manifest()
                    continue
                try:
                    deleted, first, _ = self.invoke(issuer, "logout", home, extra={"deadline_ms": 1000}, timeout=min(2, deadline - time.monotonic()))
                    absent, second, _ = self.invoke(issuer, "status", home, extra={"deadline_ms": 1000}, timeout=max(0.01, min(2, deadline - time.monotonic())))
                    row["logout_status"] = deleted.get("status")
                    row["confirmation_status"] = absent.get("status")
                    row["cleanup_required"] = not (deleted.get("status") == "signed_out" and absent.get("status") == "signed_out" and all(first.values()) and all(second.values()))
                except (OSError, ValueError, subprocess.SubprocessError):
                    row["failure"] = "cleanup_operation_failed"
                self.cleanup.append(row)
                self.write_manifest()
            if issuer.snapshot()["requests"]:
                self.cleanup.append({"cleanup_required": True, "failure": "unexpected_cleanup_network"})
        # Do not remove identity directories; they are required to derive the
        # exact native store account if a later cleanup is needed.

    def write_summary(self):
        value = {"schema_version": 1, "accounts_used": False, "openai_requests": 0,
                 "cases": self.rows, "passed": sum(row["passed"] for row in self.rows),
                 "total": len(self.rows), "cleanup": self.cleanup,
                 "all_invocations_safe": all(all(checks.values()) for checks in self.invocation_checks),
                 "finished": self.finished, "cleanup_complete": self.cleanup_complete,
                 "cleanup_required": not self.cleanup_complete,
                 "interrupted": self.interrupted,
                 "not_validated": ["real OpenAI account login", "real managed policy sources or workspace routing",
                                   "actual Keychain write failure", "browser callback flow",
                                   "real token refresh", "token revocation", "hard-killed supervisor recovery",
                                   "cancellation while native Keychain save is in progress"]}
        atomic_write_json(self.run / "report.json", value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--native-binary", type=Path)
    options = parser.parse_args()
    probe = Probe(options.binary, options.output_root, options.native_binary)

    def interrupted(_signum, _frame):
        raise Interrupted()

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    failure = False
    try:
        probe.request_only_case()
        for case in SUCCESS_SCENARIOS + ERROR_SCENARIOS + ("cancel_poll", "cancel_exchange"):
            probe.protocol_case(case)
        probe.environment_case()
        probe.redirect_case(False)
        probe.redirect_case(True)
        probe.saved_cancel_case()
        probe.malformed_storage_case()
        probe.isolated_homes_case()
        for scenario, expected in (("success", "ok"), ("model401", "unauthorized"),
                                   ("modeltool", "invalid_or_incomplete_response")):
            probe.authenticated_translation_case(scenario, expected=expected)
        for scenario, expected in (("success", "ok"), ("refresh_failed", "refresh_rejected"),
                                   ("refresh_malformed", "refresh_unavailable"),
                                   ("refresh_wrong_account", "identity_inconsistent"),
                                   ("refresh_wrong_account_only", "identity_inconsistent")):
            probe.authenticated_translation_case(scenario, refresh=True, expected=expected)
        probe.authenticated_translation_case(replacement=True, expected="managed_network_denied")
        for scenario, expected in (("expired_access", "ok"), ("expired_refresh_failed", "refresh_rejected"),
                                   ("expired_refresh_malformed", "refresh_unavailable"),
                                   ("expired_refresh_still_expired", "refresh_incomplete")):
            probe.authenticated_translation_case(scenario, expected=expected)
        for policy, expected in (("chatgpt_only", "ok"), ("workspace_allowed", "ok"),
                                 ("api_only", "managed_auth_denied"), ("denied", "managed_auth_denied"),
                                 ("workspace_mismatch", "managed_auth_denied"),
                                 ("mdm_overrides_system", "ok"), ("mdm_denies_system", "managed_auth_denied"),
                                 ("cloud_auth_ignored", "ok"), ("network_deny_all", "managed_network_denied"),
                                 ("network_disabled", "ok"), ("malformed", "managed_policy_unavailable"),
                                 ("cloud_error", "managed_policy_unavailable"),
                                 ("unsupported_file_store", "unsupported_managed_policy")):
            probe.authenticated_translation_case(policy=policy, expected=expected)
        probe.session_case()
        for phase in ("usercode", "poll", "exchange", "before_promotion", "after_promotion"):
            for action in ("cancel", "eof"):
                probe.session_case(phase, action)
        for action in ("malformed", "wrong_id", "oversized"):
            probe.session_case("poll", action)
        probe.output_closed_session_case()
        if probe.native_binary:
            probe.session_case(native=True)
            probe.session_case("poll", "cancel", native=True)
            probe.session_case("poll", "eof", native=True)
            probe.session_case("poll", "task_cancel", native=True)
    except (Interrupted, KeyboardInterrupt):
        probe.interrupted = True
        failure = True
    except (OSError, ValueError, subprocess.SubprocessError):
        # Never serialize raw exception text: libraries can include token data.
        failure = True
        probe.rows.append({"case": "runner_failure", "passed": False, "status": "host_error"})
    finally:
        # Allow the wrapper's 30-second graceful cleanup window. A second TERM
        # cannot interrupt exact-item cleanup; the wrapper may still hard-kill.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            probe.cleanup_all()
        except (OSError, ValueError, subprocess.SubprocessError):
            probe.cleanup.append({"cleanup_required": True, "failure": "cleanup_interrupted_or_invalid_journal"})
        confirmed = {row.get("identity_home") for row in probe.cleanup if row.get("cleanup_required") is False}
        probe.cleanup_complete = bool(probe.identities) and confirmed == {str(path) for path in probe.identities} and not any(row["cleanup_required"] for row in probe.cleanup)
        probe.finished = True
        probe.write_manifest()
        probe.write_summary()
    success = not failure and all(row["passed"] for row in probe.rows) and all(all(checks.values()) for checks in probe.invocation_checks) and probe.cleanup_complete
    print(json.dumps({"run": str(probe.run), "passed": success, "finished": probe.finished,
                      "cleanup_complete": probe.cleanup_complete, "cleanup_required": not probe.cleanup_complete}), flush=True)
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())

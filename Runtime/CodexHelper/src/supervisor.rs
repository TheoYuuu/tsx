//! One request, one account lease, and bounded worker/cleanup lifetimes.
//! Credentials never enter this process. A durable active-generation pointer
//! wins over a lost reply; cancellation cannot roll back a committed account.

use crate::account_storage::{AccountStorage, Identity, RecoveryAction};
use crate::protocol::{self, Control, Event, Operation, Outcome, Request, WorkerCommand, WorkerInput};
use std::io::{self, BufRead, BufReader, Stdin};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::process::{ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};
use tokio::sync::Notify;
use tokio::time::{Instant, sleep_until, timeout_at};

const REAP_GRACE: Duration = Duration::from_secs(2);
const CLEANUP_GRACE: Duration = Duration::from_secs(8);
const OUTPUT_GRACE: Duration = Duration::from_secs(1);

#[derive(Clone, Copy)]
enum Stop { Cancelled, InvalidControl, Timeout, OutputClosed }
impl Stop {
    fn status(self) -> &'static str {
        match self { Self::Cancelled => "cancelled", Self::InvalidControl => "invalid_input",
            Self::Timeout => "timeout", Self::OutputClosed => "request_failed" }
    }
}

#[derive(Default)]
struct ControlState { reason: Option<Stop>, committed: bool, finished: bool }
#[derive(Default)]
struct SharedControl { state: Mutex<ControlState>, changed: Notify }
impl SharedControl {
    fn stop(&self, reason: Stop) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if !state.committed && !state.finished && state.reason.is_none() {
            state.reason = Some(reason);
            self.changed.notify_one();
        }
    }
    fn reason(&self) -> Option<Stop> {
        self.state.lock().unwrap_or_else(|error| error.into_inner()).reason
    }
    async fn stopped(&self) {
        loop {
            if self.reason().is_some() { return; }
            self.changed.notified().await;
        }
    }
}

fn control_reader<R: BufRead + Send + 'static>(mut reader: R, request: Request, control: Arc<SharedControl>) {
    // Do not use Tokio's blocking pool: an open stdin must not hold the runtime
    // alive after its one terminal event. Process exit ends this read-only thread.
    std::thread::spawn(move || {
        let reason = match protocol::read_bounded_line(&mut reader, protocol::MAX_CONTROL_LINE) {
            Ok(None) => Stop::Cancelled,
            Ok(Some(bytes)) => match serde_json::from_slice::<Control>(&bytes) {
                Ok(message) if message.cancels(&request) => Stop::Cancelled,
                _ => Stop::InvalidControl,
            },
            Err(_) => Stop::InvalidControl,
        };
        control.stop(reason);
    });
}

struct Output {
    descriptor: i32,
    written: usize,
    failed: bool,
    #[cfg(test)]
    _owned: Option<std::os::unix::net::UnixStream>,
    #[cfg(test)]
    fail_event_write: Option<&'static str>,
}
impl Output {
    fn stdout() -> io::Result<Self> {
        let flags = unsafe { libc::fcntl(libc::STDOUT_FILENO, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(libc::STDOUT_FILENO, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { descriptor: libc::STDOUT_FILENO, written: 0, failed: false,
            #[cfg(test)] _owned: None, #[cfg(test)] fail_event_write: None })
    }
    async fn event(&mut self, event: &Event, operation_deadline: Option<Instant>) -> bool {
        if self.failed { return false; }
        #[cfg(test)]
        if self.fail_event_write == Some(event.event.as_str()) {
            let _ = self._owned.as_ref().unwrap().shutdown(std::net::Shutdown::Write);
        }
        let Ok(mut bytes) = serde_json::to_vec(event) else { self.failed = true; return false };
        bytes.push(b'\n');
        if bytes.len() > protocol::MAX_OUTPUT || self.written.saturating_add(bytes.len()) > protocol::MAX_OUTPUT {
            self.failed = true; return false;
        }
        let mut deadline = Instant::now() + OUTPUT_GRACE;
        if let Some(operation_deadline) = operation_deadline { deadline = deadline.min(operation_deadline); }
        let mut position = 0;
        while position < bytes.len() && Instant::now() < deadline {
            let count = unsafe { libc::write(self.descriptor, bytes[position..].as_ptr().cast(), bytes.len() - position) };
            if count > 0 {
                position += count as usize;
                self.written += count as usize;
            } else if count < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted { continue; }
                if error.kind() == io::ErrorKind::WouldBlock {
                    tokio::time::sleep_until(deadline.min(Instant::now() + Duration::from_millis(5))).await;
                    continue;
                }
                break;
            } else { break; }
        }
        if position != bytes.len() { self.failed = true; }
        !self.failed
    }
}

#[derive(Clone)]
enum WorkerProgram {
    CurrentExecutable,
    #[cfg(test)]
    Fixture(PathBuf),
}
impl WorkerProgram {
    fn command(&self) -> io::Result<Command> {
        Ok(Command::new(match self {
            Self::CurrentExecutable => std::env::current_exe()?,
            #[cfg(test)] Self::Fixture(path) => path.clone(),
        }))
    }
}

struct WorkerResult { outcome: Outcome, reaped: bool }
fn failed_worker(reaped: bool) -> WorkerResult {
    WorkerResult { outcome: Outcome::new(if reaped { "request_failed" } else { "cleanup_required" }), reaped }
}

async fn terminate(child: &mut Child, hard_deadline: Instant) -> bool {
    let _ = child.start_kill();
    matches!(timeout_at(hard_deadline.min(Instant::now() + REAP_GRACE), child.wait()).await, Ok(Ok(_)))
}

fn valid_ready(event: &Event) -> bool {
    event.result.is_none() && event.verification_url.as_deref() == Some(protocol::VERIFICATION_URL)
        && event.user_code.as_ref().is_some_and(|code| protocol::safe_label(code, 128)
            && code.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b' ')))
}

fn valid_outcome(outcome: &Outcome, command: WorkerCommand) -> bool {
    if (!protocol::TERMINAL_STATUSES.contains(&outcome.status.as_str())
        && !(command == WorkerCommand::Login && outcome.status == "login_ready_commit"))
        || outcome.generation.is_some()
    { return false; }
    if outcome.text.as_ref().is_some_and(|text| command != WorkerCommand::Translate
        || outcome.status != "ok" || text.is_empty() || text.len() > crate::sse_guard::MAX_OUTPUT)
    { return false; }
    if let Some(models) = &outcome.models {
        let mut model_ids = std::collections::HashSet::new();
        if command != WorkerCommand::Models || outcome.status != "ok" || models.len() > 256
            || models.iter().any(|model| !protocol::safe_label(&model.id, 256)
                || !model_ids.insert(&model.id)
                || !protocol::safe_label(&model.name, 256) || model.reasoning_efforts.len() > 16
                || model.reasoning_efforts.iter().any(|effort| !protocol::safe_label(effort, 128))
                || model.reasoning_efforts.iter().collect::<std::collections::HashSet<_>>().len() != model.reasoning_efforts.len()
                || model.default_reasoning_effort.as_ref().is_some_and(|effort| !model.reasoning_efforts.contains(effort)))
        { return false; }
    }
    if outcome.account_plan.as_ref().is_some_and(|plan| !protocol::safe_label(plan, 128)
        || !matches!((command, outcome.status.as_str()),
            (WorkerCommand::Status, "signed_in") | (WorkerCommand::Login, "login_ready_commit")))
    { return false; }
    if outcome.remote_revocation.as_ref().is_some_and(|value| command != WorkerCommand::Logout
        || outcome.status != "signed_out" || value != "unconfirmed")
    { return false; }
    // These success codes are private contracts, not generic acknowledgements.
    match command {
        WorkerCommand::Login => !matches!(outcome.status.as_str(), "signed_in" | "signed_out" | "ok"),
        WorkerCommand::Cleanup | WorkerCommand::Logout => !matches!(outcome.status.as_str(), "ok" | "signed_in"),
        WorkerCommand::Translate if outcome.status == "ok" => outcome.text.is_some(),
        WorkerCommand::Models if outcome.status == "ok" => outcome.models.is_some(),
        WorkerCommand::Status => outcome.status != "ok",
        WorkerCommand::Models | WorkerCommand::Translate => !matches!(outcome.status.as_str(), "signed_in" | "signed_out"),
    }
}

async fn worker(
    storage: &AccountStorage, request: &Request, identity: &Identity, command: WorkerCommand,
    deadline: Instant, control: Option<&Arc<SharedControl>>, output: &mut Output, program: &WorkerProgram,
) -> WorkerResult {
    if Instant::now() >= deadline { return WorkerResult { outcome: Outcome::new("timeout"), reaped: true }; }
    // Reserve part of this same budget for kill+wait; cleanup workers must not
    // silently turn their eight-second total budget into ten seconds.
    let work_deadline = deadline - REAP_GRACE.min(deadline.saturating_duration_since(Instant::now()) / 4);
    if let Some(reason) = control.and_then(|value| value.reason()) {
        return WorkerResult { outcome: Outcome::new(reason.status()), reaped: true };
    }
    let lease = match storage.worker_lease() { Ok(value) => value, Err(_) => return failed_worker(true) };
    let descriptor = lease.as_raw_fd();
    let mut command_line = match program.command() { Ok(value) => value, Err(_) => return failed_worker(true) };
    command_line.arg("--worker").arg(descriptor.to_string())
        .env_clear().env("PATH", "/usr/bin:/bin").env("LANG", "en_US.UTF-8")
        .env("TMPDIR", std::env::var_os("TMPDIR").unwrap_or_else(|| "/tmp".into())).current_dir(&identity.home)
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    // No setsid or setpgid here: the native host owns the supervisor's private
    // group, including every worker. Only this exact child's lease FD survives.
    unsafe {
        command_line.pre_exec(move || {
            let flags = libc::fcntl(descriptor, libc::F_GETFD);
            if flags < 0 || libc::fcntl(descriptor, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = match command_line.spawn() { Ok(value) => value, Err(_) => return failed_worker(true) };
    drop(lease);
    let Some(mut stdin) = child.stdin.take() else { return failed_worker(terminate(&mut child, deadline).await) };
    let Some(mut stdout) = child.stdout.take() else { return failed_worker(terminate(&mut child, deadline).await) };
    let Some(mut stderr) = child.stderr.take() else { return failed_worker(terminate(&mut child, deadline).await) };
    let input = WorkerInput { request: request.clone(), identity_home: identity.home.clone(), command };
    let mut input = match serde_json::to_vec(&input) { Ok(value) => value, Err(_) => return failed_worker(terminate(&mut child, deadline).await) };
    input.push(b'\n');
    if input.len() > protocol::MAX_INPUT_LINE { return failed_worker(terminate(&mut child, deadline).await); }
    let sent = tokio::select! {
        biased;
        _ = async { if let Some(control) = control { control.stopped().await } else { std::future::pending().await } } => Err("cancelled"),
        _ = sleep_until(work_deadline) => Err("timeout"),
        result = stdin.write_all(&input) => result.map_err(|_| "request_failed"),
    };
    drop(stdin);
    if let Err(status) = sent {
        let reaped = terminate(&mut child, deadline).await;
        return WorkerResult { outcome: Outcome::new(if reaped {
            control.and_then(|value| value.reason()).map_or(status, Stop::status)
        } else { "cleanup_required" }), reaped };
    }
    let mut pending = Vec::new();
    let mut scanned = 0;
    let mut total = 0usize;
    let mut ready = false;
    let mut terminal = None;
    let mut exit: Option<ExitStatus> = None;
    let mut stdout_ended = false;
    let mut stderr_ended = false;
    let mut chunk = [0_u8; 8192];
    let mut errors = [0_u8; 4096];
    let mut stop = None;
    let mut bad_wire = false;
    loop {
        if stdout_ended && stderr_ended && exit.is_some() { break; }
        tokio::select! {
            biased;
            _ = async { if let Some(control) = control { control.stopped().await } else { std::future::pending().await } } => {
                stop = control.and_then(|value| value.reason()); break;
            }
            _ = sleep_until(work_deadline) => { stop = Some(Stop::Timeout); break; }
            result = stdout.read(&mut chunk), if !stdout_ended => {
                match result {
                    Ok(0) => { stdout_ended = true; if !pending.is_empty() { bad_wire = true; } },
                    Ok(count) => {
                        total = total.saturating_add(count);
                        if total > protocol::MAX_OUTPUT { bad_wire = true; }
                        else {
                            pending.extend_from_slice(&chunk[..count]);
                            while let Some(relative) = pending[scanned..].iter().position(|byte| *byte == b'\n') {
                                let newline = scanned + relative;
                                let bytes: Vec<u8> = pending.drain(..=newline).collect();
                                scanned = 0;
                                let event = serde_json::from_slice::<Event>(&bytes);
                                let event = match event { Ok(value) => value, Err(_) => { bad_wire = true; break; } };
                                if event.protocol_version != protocol::VERSION || event.request_id != request.request_id
                                    || terminal.is_some() { bad_wire = true; break; }
                                match event.event.as_str() {
                                    "ready" if command == WorkerCommand::Login && !ready && valid_ready(&event) => {
                                        ready = true;
                                        if !output.event(&event, Some(work_deadline)).await {
                                            if let Some(control) = control { control.stop(Stop::OutputClosed); }
                                            stop = Some(Stop::OutputClosed); break;
                                        }
                                    }
                                    "terminal" if event.user_code.is_none() && event.verification_url.is_none() => {
                                        match event.result {
                                            Some(value) if valid_outcome(&value, command)
                                                && (value.status != "login_ready_commit" || ready) => terminal = Some(value),
                                            _ => { bad_wire = true; break; }
                                        }
                                    }
                                    _ => { bad_wire = true; break; }
                                }
                            }
                            scanned = pending.len();
                        }
                    }
                    Err(_) => { bad_wire = true; },
                }
            }
            result = stderr.read(&mut errors), if !stderr_ended => {
                // Only observe presence; never retain, decode, print, or return it.
                match result { Ok(0) => stderr_ended = true, _ => bad_wire = true }
            }
            result = child.wait(), if exit.is_none() => {
                match result { Ok(value) => exit = Some(value), Err(_) => { bad_wire = true; } }
            }
        }
        if bad_wire || stop.is_some() { break; }
    }
    if bad_wire || stop.is_some() {
        let reaped = if exit.is_some() { true } else { terminate(&mut child, deadline).await };
        return WorkerResult { outcome: Outcome::new(if !reaped { "cleanup_required" }
            else { stop.map_or("request_failed", Stop::status) }), reaped };
    }
    if exit.is_some_and(|value| value.success()) && let Some(outcome) = terminal {
        WorkerResult { outcome, reaped: true }
    } else { failed_worker(true) }
}

async fn recover(
    storage: &mut AccountStorage, request: &Request, deadline: Instant,
    output: &mut Output, program: &WorkerProgram,
) -> Result<(), ()> {
    match storage.recovery_action().map_err(|_| ())? {
        RecoveryAction::None => Ok(()),
        RecoveryAction::Committed { operation_id, identity } => {
            storage.finalize_committed(&operation_id, &identity.generation).map_err(|_| ())
        }
        RecoveryAction::Cleanup { operation_id, identity, .. } => {
            let result = worker(storage, request, &identity, WorkerCommand::Cleanup, deadline, None, output, program).await;
            if !result.reaped || result.outcome.status != "signed_out" { return Err(()); }
            storage.complete_cleanup(&operation_id, &identity.generation).map_err(|_| ())
        }
    }
}

fn with_generation(mut outcome: Outcome, identity: &Identity) -> Outcome {
    outcome.generation = Some(identity.generation.clone()); outcome
}

async fn execute(
    request: &Request, storage: &mut AccountStorage, control: &Arc<SharedControl>,
    output: &mut Output, program: &WorkerProgram, deadline: Instant, cleanup_grace: Duration,
) -> Outcome {
    if recover(storage, request, Instant::now() + cleanup_grace, output, program).await.is_err() {
        return Outcome::new("cleanup_required");
    }
    if let Some(reason) = control.reason() { return Outcome::new(reason.status()); }
    if Instant::now() >= deadline { return Outcome::new("timeout"); }
    if let Some(expected) = &request.expected_generation {
        match storage.active() {
            Ok(Some(identity)) if &identity.generation == expected => {},
            Ok(_) => return Outcome::new("account_changed"),
            Err(error) => return Outcome::error(error.status()),
        }
    }
    match request.operation {
        Operation::Login => {
            let identity = match storage.begin_login(&request.request_id) {
                Ok(value) => value,
                Err(error) => {
                    let outcome = Outcome::error(error.status());
                    return if recover(storage, request, Instant::now() + cleanup_grace, output, program).await.is_ok() {
                        outcome
                    } else { Outcome::new("cleanup_required") };
                }
            };
            let result = worker(storage, request, &identity, WorkerCommand::Login, deadline,
                Some(control), output, program).await;
            if !result.reaped { return Outcome::new("cleanup_required"); }
            let mut failure = result.outcome.clone();
            if result.outcome.status == "login_ready_commit" {
                if Instant::now() >= deadline { control.stop(Stop::Timeout); }
                if control.reason().is_none()
                    && !output.event(&Event::committing(request), Some(deadline)).await
                { control.stop(Stop::OutputClosed); }
                let decision = {
                    // A cancellation already accepted by the reader wins. Once
                    // this gate commits active.json, later cancellation is late.
                    let mut state = control.state.lock().unwrap_or_else(|error| error.into_inner());
                    if state.reason.is_none() && Instant::now() >= deadline { state.reason = Some(Stop::Timeout); }
                    if state.reason.is_some() { Some(false) }
                    else {
                        match storage.commit_login(&request.request_id, &identity.generation) {
                            Ok(_) => { state.committed = true; Some(true) },
                            Err(_) => match storage.recovery_action() {
                                Ok(RecoveryAction::Committed { identity: committed, .. }) if committed == identity => {
                                    state.committed = true; Some(true)
                                }
                                Ok(RecoveryAction::Cleanup { identity: candidate, .. }) if candidate == identity => Some(false),
                                _ => None,
                            }
                        }
                    }
                };
                match decision {
                    Some(true) => {
                        if storage.finalize_committed(&request.request_id, &identity.generation).is_err() {
                            return Outcome::new("cleanup_required");
                        }
                        let mut outcome = Outcome::new("signed_in");
                        outcome.account_plan = result.outcome.account_plan;
                        return with_generation(outcome, &identity);
                    }
                    None => return Outcome::new("cleanup_required"),
                    Some(false) => failure = Outcome::new("storage_unavailable"),
                }
            }
            if recover(storage, request, Instant::now() + cleanup_grace, output, program).await.is_err() {
                return Outcome::new("cleanup_required");
            }
            control.reason().map_or(failure, |reason| Outcome::new(reason.status()))
        }
        Operation::Logout => {
            let identity = match storage.begin_logout(&request.request_id) {
                Ok(Some(value)) => value,
                Ok(None) => {
                    let mut outcome = Outcome::new("signed_out");
                    outcome.remote_revocation = Some("unconfirmed".into());
                    return outcome;
                }
                Err(error) => return Outcome::error(error.status()),
            };
            let result = worker(storage, request, &identity, WorkerCommand::Logout, deadline,
                Some(control), output, program).await;
            if !result.reaped { return Outcome::new("cleanup_required"); }
            let cleared = if result.outcome.status == "signed_out" {
                storage.complete_cleanup(&request.request_id, &identity.generation).is_ok()
            } else {
                recover(storage, request, Instant::now() + cleanup_grace, output, program).await.is_ok()
            };
            if !cleared { return Outcome::new("cleanup_required"); }
            let mut outcome = Outcome::new("signed_out");
            // The official public API intentionally swallows revoke failures.
            outcome.remote_revocation = Some("unconfirmed".into());
            outcome
        }
        Operation::Status | Operation::Models | Operation::Translate => {
            let identity = match storage.active() {
                Ok(Some(value)) => value,
                Ok(None) => return Outcome::new(if request.operation == Operation::Status { "signed_out" } else { "authentication_failed" }),
                Err(error) => return Outcome::error(error.status()),
            };
            let command = match request.operation { Operation::Status => WorkerCommand::Status,
                Operation::Models => WorkerCommand::Models, _ => WorkerCommand::Translate };
            let result = worker(storage, request, &identity, command, deadline,
                Some(control), output, program).await;
            if !result.reaped { return Outcome::new("cleanup_required"); }
            if result.outcome.status == "signed_out" {
                // Strict worker absence is authoritative; do not leave an empty
                // active pointer that would reject every subsequent login.
                match storage.begin_logout(&request.request_id) {
                    Ok(Some(current)) if current == identity => {
                        if storage.complete_cleanup(&request.request_id, &identity.generation).is_err() {
                            return Outcome::new("cleanup_required");
                        }
                    }
                    _ => return Outcome::new("cleanup_required"),
                }
                return result.outcome;
            }
            if result.outcome.status == "signed_in" {
                with_generation(result.outcome, &identity)
            } else { result.outcome }
        }
    }
}

async fn run_owned<R: BufRead + Send + 'static>(
    request: Request, root: PathBuf, reader: R, mut output: Output, program: WorkerProgram,
    operation_limit: Duration, cleanup_grace: Duration,
) -> i32 {
    let control = Arc::new(SharedControl::default());
    control_reader(reader, request.clone(), Arc::clone(&control));
    let deadline = Instant::now() + operation_limit;
    let mut storage = AccountStorage::lock(&root);
    let outcome = match storage.as_mut() {
        Ok(storage) => execute(&request, storage, &control, &mut output, &program, deadline, cleanup_grace).await,
        Err(error) => Outcome::error(error.status()),
    };
    let outcome = {
        let mut state = control.state.lock().unwrap_or_else(|error| error.into_inner());
        let outcome = if !state.committed && request.operation != Operation::Logout && outcome.status != "cleanup_required" {
            state.reason.map_or(outcome.clone(), |reason| Outcome::new(reason.status()))
        } else { outcome };
        state.finished = true;
        outcome
    };
    if output.event(&Event::terminal(&request, outcome), None).await { 0 } else { 4 }
}

/// Main transfers the same reader used for the first request line. It validates
/// the request, private root, executable identity and allowed environment first.
pub async fn run(request: Request, root: PathBuf, reader: BufReader<Stdin>) -> i32 {
    // Foundation can already provide a private group in its own session.
    let grouped = unsafe { libc::getpgrp() == libc::getpid() };
    if !grouped && unsafe { libc::setsid() } < 0 { return 3; }
    let output = match Output::stdout() { Ok(value) => value, Err(_) => return 3 };
    let limit = match request.operation { Operation::Login => Duration::from_secs(900),
        Operation::Status => Duration::from_secs(30), _ => Duration::from_secs(90) };
    run_owned(request, root, reader, output, WorkerProgram::CurrentExecutable, limit, CLEANUP_GRACE).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::os::unix::net::UnixStream;
    use uuid::Uuid;

    struct Fixture(PathBuf);
    impl Fixture {
        fn new(behavior: &str) -> Self {
            Self::with_cleanup(behavior, "terminal('signed_out')")
        }
        fn with_cleanup(behavior: &str, cleanup: &str) -> Self {
            let root = std::env::temp_dir().canonicalize().unwrap().join(format!("translatex-supervisor-test-{}", Uuid::new_v4()));
            fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
            let script = root.join("worker.py");
            fs::write(&script, format!("#!/usr/bin/python3\n{}\nif command == 'cleanup':\n    {}\n    sys.exit(0)\n{}\n", r#"
import json, os, sys, time
lease = int(sys.argv[2])
os.fstat(lease)
data = json.loads(sys.stdin.readline())
r = data['request']; command = data['command']; home = data['identity_home']
base = dict(protocol_version=1, request_id=r['request_id'])
def emit(event):
    print(json.dumps(dict(base, **event)), flush=True)
def terminal(status, **values):
    emit(dict(event='terminal', result=dict(status=status, **values)))
def ready():
    emit(dict(event='ready', user_code='CONSTRUCTED-CODE', verification_url='https://auth.openai.com/codex/device'))
"#, cleanup, behavior)).unwrap();
            fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
            Self(root)
        }
        fn active(&self) -> Option<Identity> { AccountStorage::lock(&self.0).unwrap().active().unwrap() }
        fn activate(&self) -> Identity {
            let mut storage = AccountStorage::lock(&self.0).unwrap();
            let op = Uuid::new_v4().to_string();
            let identity = storage.begin_login(&op).unwrap();
            storage.commit_login(&op, &identity.generation).unwrap();
            storage.finalize_committed(&op, &identity.generation).unwrap(); identity
        }
    }
    impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
    fn request(operation: Operation) -> Request {
        Request { protocol_version: 1, request_id: Uuid::new_v4().to_string(), operation,
            expected_generation: matches!(operation, Operation::Models | Operation::Translate).then(|| Uuid::new_v4().to_string()),
            model: (operation == Operation::Translate).then(|| "constructed".into()),
            text: (operation == Operation::Translate).then(|| "Constructed sample.".into()), source_language: None,
            target_language: (operation == Operation::Translate).then(|| "zh-Hans".into()) }
    }
    #[derive(Clone, Copy)]
    enum Action { None, CancelReady, EofReady, WrongCancelReady, FailCommittingWrite, FailTerminalWrite }

    async fn invoke(fixture: &Fixture, operation: Operation, action: Action, limit: Duration) -> (i32, Vec<Event>) {
        let mut request = request(operation);
        if matches!(operation, Operation::Models | Operation::Translate) {
            request.expected_generation = Some(fixture.active().map_or_else(|| Uuid::new_v4().to_string(), |identity| identity.generation));
        }
        invoke_request(fixture, request, action, limit).await
    }

    async fn invoke_request(fixture: &Fixture, request: Request, action: Action, limit: Duration) -> (i32, Vec<Event>) {
        let (control_reader, mut control_writer) = UnixStream::pair().unwrap();
        let (output, reader) = UnixStream::pair().unwrap();
        output.set_nonblocking(true).unwrap();
        let descriptor = output.as_raw_fd();
        let id = request.request_id.clone();
        let consumer = std::thread::spawn(move || {
            let mut reader = BufReader::new(reader);
            let mut control = Some(&mut control_writer);
            let mut events = Vec::new();
            while let Some(bytes) = protocol::read_bounded_line(&mut reader, protocol::MAX_OUTPUT).unwrap() {
                let event: Event = serde_json::from_slice(&bytes).unwrap();
                if event.event == "ready" {
                    match action {
                        Action::CancelReady | Action::WrongCancelReady => {
                            let message = serde_json::json!({"protocol_version":1,
                                "request_id": if matches!(action, Action::WrongCancelReady) { Uuid::new_v4().to_string() } else { id.clone() },
                                "action":"cancel"});
                            writeln!(control.as_mut().unwrap(), "{message}").unwrap();
                        }
                        Action::EofReady => { control.as_ref().unwrap().shutdown(std::net::Shutdown::Write).unwrap(); control = None; }
                        _ => {},
                    }
                }
                events.push(event);
            }
            events
        });
        let code = run_owned(request, fixture.0.clone(), BufReader::new(control_reader),
            Output { descriptor, written: 0, failed: false, _owned: Some(output),
                fail_event_write: match action { Action::FailTerminalWrite => Some("terminal"),
                    Action::FailCommittingWrite => Some("committing"), _ => None } },
            WorkerProgram::Fixture(fixture.0.join("worker.py")), limit, Duration::from_secs(2)).await;
        (code, consumer.join().unwrap())
    }
    fn terminal(events: &[Event]) -> &Outcome { events.last().unwrap().result.as_ref().unwrap() }

    #[tokio::test]
    async fn login_commits_generation_only_after_worker_has_exited() {
        let fixture = Fixture::new("ready(); terminal('login_ready_commit', account_plan='plus')");
        let (code, events) = invoke(&fixture, Operation::Login, Action::None, Duration::from_secs(3)).await;
        assert_eq!(code, 0);
        assert_eq!(events.iter().map(|event| event.event.as_str()).collect::<Vec<_>>(), ["ready", "committing", "terminal"]);
        assert_eq!(terminal(&events).status, "signed_in");
        assert_eq!(terminal(&events).generation, fixture.active().map(|identity| identity.generation));
        assert!(matches!(AccountStorage::lock(&fixture.0).unwrap().recovery_action().unwrap(), RecoveryAction::None));
    }

    #[tokio::test]
    async fn cancel_eof_and_wrong_id_reap_then_clean_inactive_candidate() {
        for (action, expected) in [(Action::CancelReady, "cancelled"), (Action::EofReady, "cancelled"), (Action::WrongCancelReady, "invalid_input")] {
            let fixture = Fixture::new("ready(); time.sleep(5); terminal('login_ready_commit')");
            let (_, events) = invoke(&fixture, Operation::Login, action, Duration::from_secs(3)).await;
            assert_eq!(terminal(&events).status, expected);
            assert!(fixture.active().is_none());
            assert!(matches!(AccountStorage::lock(&fixture.0).unwrap().recovery_action().unwrap(), RecoveryAction::None));
        }
    }

    #[tokio::test]
    async fn timeout_reaps_and_cleans_candidate() {
        let fixture = Fixture::new("time.sleep(5)");
        let (_, events) = invoke(&fixture, Operation::Login, Action::None, Duration::from_millis(150)).await;
        assert_eq!(terminal(&events).status, "timeout");
        assert!(fixture.active().is_none());
        assert!(matches!(AccountStorage::lock(&fixture.0).unwrap().recovery_action().unwrap(), RecoveryAction::None));
    }

    #[tokio::test]
    async fn stale_login_recovery_precedes_signed_out_status() {
        let fixture = Fixture::new("raise AssertionError('status must not spawn without active identity')");
        let candidate = AccountStorage::lock(&fixture.0).unwrap().begin_login(&Uuid::new_v4().to_string()).unwrap();
        let (_, events) = invoke(&fixture, Operation::Status, Action::None, Duration::from_secs(3)).await;
        assert_eq!(terminal(&events).status, "signed_out");
        assert!(!candidate.home.exists());
    }

    #[tokio::test]
    async fn committed_recovery_preserves_account_and_clears_only_journal() {
        let fixture = Fixture::new("terminal('signed_in', account_plan='plus')");
        let op = Uuid::new_v4().to_string();
        let mut storage = AccountStorage::lock(&fixture.0).unwrap();
        let candidate = storage.begin_login(&op).unwrap();
        storage.commit_login(&op, &candidate.generation).unwrap(); drop(storage);
        let (_, events) = invoke(&fixture, Operation::Status, Action::None, Duration::from_secs(3)).await;
        assert_eq!(terminal(&events).status, "signed_in");
        assert_eq!(fixture.active(), Some(candidate));
    }

    #[tokio::test]
    async fn failed_logout_still_performs_local_cleanup() {
        let fixture = Fixture::new("terminal('network_unavailable')");
        fixture.activate();
        let (_, events) = invoke(&fixture, Operation::Logout, Action::None, Duration::from_secs(3)).await;
        assert_eq!(terminal(&events).status, "signed_out");
        assert_eq!(terminal(&events).remote_revocation.as_deref(), Some("unconfirmed"));
        assert!(fixture.active().is_none());
    }

    #[tokio::test]
    async fn failed_cleanup_preserves_exact_pending_obligation() {
        for operation in [Operation::Login, Operation::Logout] {
            let fixture = Fixture::with_cleanup("terminal('request_failed')", "terminal('cleanup_required')");
            let active = if operation == Operation::Logout { Some(fixture.activate()) } else { None };
            let (_, events) = invoke(&fixture, operation, Action::None, Duration::from_secs(3)).await;
            assert_eq!(terminal(&events).status, "cleanup_required");
            assert!(terminal(&events).generation.is_none());
            let storage = AccountStorage::lock(&fixture.0).unwrap();
            assert_eq!(storage.active().unwrap(), active);
            match storage.recovery_action().unwrap() {
                RecoveryAction::Cleanup { identity, .. } => {
                    assert!(identity.home.exists());
                    if let Some(active) = active { assert_eq!(identity, active); }
                }
                _ => panic!("unconfirmed local deletion must keep a recoverable journal"),
            }
        }
    }

    #[tokio::test]
    async fn active_errors_are_credential_free_and_keep_generation_private() {
        let fixture = Fixture::new("assert 'HOME' not in os.environ; assert os.environ['TMPDIR'] != home; terminal('authentication_failed')");
        let active = fixture.activate();
        let (_, events) = invoke(&fixture, Operation::Models, Action::None, Duration::from_secs(3)).await;
        assert_eq!(serde_json::to_value(terminal(&events)).unwrap(), serde_json::json!({"status":"authentication_failed"}));
        assert_eq!(fixture.active(), Some(active));
    }

    #[tokio::test]
    async fn strict_absence_removes_empty_active_pointer() {
        let fixture = Fixture::new("terminal('signed_out')");
        fixture.activate();
        let (_, events) = invoke(&fixture, Operation::Status, Action::None, Duration::from_secs(3)).await;
        assert_eq!(terminal(&events).status, "signed_out");
        assert!(fixture.active().is_none());
    }

    #[tokio::test]
    async fn successful_content_has_exact_native_payload_without_account_generation() {
        for (operation, behavior, expected) in [
            (Operation::Models, "terminal('ok', models=[])", serde_json::json!({"status":"ok","models":[]})),
            (Operation::Translate, "terminal('ok', text='Constructed result.')", serde_json::json!({"status":"ok","text":"Constructed result."})),
        ] {
            let fixture = Fixture::new(behavior); fixture.activate();
            let (_, events) = invoke(&fixture, operation, Action::None, Duration::from_secs(3)).await;
            assert_eq!(serde_json::to_value(terminal(&events)).unwrap(), expected);
        }
    }

    #[tokio::test]
    async fn no_active_account_uses_operation_specific_native_status() {
        for (operation, expected) in [
            (Operation::Status, serde_json::json!({"status":"signed_out"})),
            (Operation::Logout, serde_json::json!({"status":"signed_out","remote_revocation":"unconfirmed"})),
            (Operation::Models, serde_json::json!({"status":"account_changed"})),
            (Operation::Translate, serde_json::json!({"status":"account_changed"})),
        ] {
            let fixture = Fixture::new("raise AssertionError('must not spawn without an active account')");
            let (_, events) = invoke(&fixture, operation, Action::None, Duration::from_secs(3)).await;
            assert_eq!(serde_json::to_value(terminal(&events)).unwrap(), expected);
        }
    }

    #[tokio::test]
    async fn malformed_worker_protocol_and_stderr_are_not_forwarded() {
        for behavior in ["ready(); ready(); terminal('login_ready_commit')",
            "ready(); emit(dict(event='terminal', result=dict(status='login_ready_commit', token='PRIVATE-FIXTURE')))",
            "sys.stderr.write('PRIVATE-FIXTURE'); sys.stderr.flush(); time.sleep(5)",
            "sys.stdout.write('x'*4200000); sys.stdout.flush()"] {
            let fixture = Fixture::new(behavior);
            let (_, events) = invoke(&fixture, Operation::Login, Action::None, Duration::from_secs(3)).await;
            assert_eq!(terminal(&events).status, "request_failed");
            assert!(!serde_json::to_string(&events).unwrap().contains("PRIVATE-FIXTURE"));
            assert!(fixture.active().is_none());
        }
    }

    #[tokio::test]
    async fn stale_generation_never_starts_content_or_logout_worker() {
        for operation in [Operation::Models, Operation::Translate, Operation::Logout] {
            let fixture = Fixture::new("raise AssertionError('stale generation must not reach any worker')");
            let active = fixture.activate();
            let mut request = request(operation);
            request.expected_generation = Some(Uuid::new_v4().to_string());
            let (_, events) = invoke_request(&fixture, request, Action::None, Duration::from_secs(3)).await;
            assert_eq!(serde_json::to_value(terminal(&events)).unwrap(), serde_json::json!({"status":"account_changed"}));
            assert_eq!(fixture.active(), Some(active));
        }
    }

    #[tokio::test]
    async fn dropped_reply_after_commit_never_rolls_back_active_identity() {
        let fixture = Fixture::new("ready(); terminal('login_ready_commit')");
        let (code, events) = invoke(&fixture, Operation::Login, Action::FailTerminalWrite, Duration::from_secs(3)).await;
        assert_eq!(code, 4);
        assert_eq!(events.last().unwrap().event, "committing");
        let identity = fixture.active().expect("a failed reply cannot undo the durable commit");
        assert!(identity.home.exists());
        assert!(matches!(AccountStorage::lock(&fixture.0).unwrap().recovery_action().unwrap(), RecoveryAction::None));
    }

    #[tokio::test]
    async fn dropped_committing_event_cleans_candidate_without_activating_it() {
        let fixture = Fixture::new("ready(); terminal('login_ready_commit')");
        let (code, events) = invoke(&fixture, Operation::Login, Action::FailCommittingWrite, Duration::from_secs(3)).await;
        assert_eq!(code, 4);
        assert_eq!(events.iter().map(|event| event.event.as_str()).collect::<Vec<_>>(), ["ready"]);
        assert!(fixture.active().is_none());
        assert!(matches!(AccountStorage::lock(&fixture.0).unwrap().recovery_action().unwrap(), RecoveryAction::None));
    }

    #[test]
    fn outcome_contract_rejects_cross_operation_payload_and_false_revocation_claim() {
        let mut outcome = Outcome::new("ok"); outcome.text = Some("constructed".into());
        assert!(!valid_outcome(&outcome, WorkerCommand::Status));
        outcome = Outcome::new("signed_out"); outcome.remote_revocation = Some("confirmed".into());
        assert!(!valid_outcome(&outcome, WorkerCommand::Logout));
        outcome = Outcome::new("ok"); outcome.account_plan = Some("plus".into());
        assert!(!valid_outcome(&outcome, WorkerCommand::Translate));
    }

    #[test]
    fn ready_and_model_summaries_match_the_native_contract() {
        let request = request(Operation::Login);
        let mut ready = Event::ready(&request, "ASCII-CODE 123".into(), protocol::VERIFICATION_URL.into());
        assert!(valid_ready(&ready));
        ready.user_code = Some("构造代码".into());
        assert!(!valid_ready(&ready));
        let model = protocol::ModelSummary { id: "constructed".into(), name: "Constructed".into(),
            reasoning_efforts: vec!["low".into()], default_reasoning_effort: Some("low".into()) };
        let mut outcome = Outcome::new("ok"); outcome.models = Some(vec![model.clone()]);
        assert!(valid_outcome(&outcome, WorkerCommand::Models));
        outcome.models.as_mut().unwrap().push(model.clone());
        assert!(!valid_outcome(&outcome, WorkerCommand::Models));
        outcome.models = Some(vec![protocol::ModelSummary { reasoning_efforts: vec!["low".into(), "low".into()], ..model.clone() }]);
        assert!(!valid_outcome(&outcome, WorkerCommand::Models));
        outcome.models = Some(vec![protocol::ModelSummary { default_reasoning_effort: Some("high".into()), ..model }]);
        assert!(!valid_outcome(&outcome, WorkerCommand::Models));
    }
}

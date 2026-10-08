//! Signed QA executable for real worker/store integration using only registered
//! random fixture identities. It never starts login, revoke, model, or policy IO.
//! Build as a separate binary in the staged runtime crate; never package it.

use base64::Engine;
use codex_login::{AuthCredentialsStoreMode, AuthDotJson, AuthKeyringBackendKind};
use translatex_codex_runtime::account_storage::{AccountStorage, Identity};
use translatex_codex_runtime::protocol::{Event, Operation, Request, WorkerCommand, WorkerInput};
use translatex_codex_runtime::{host, worker};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;
use uuid::Uuid;

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SecKeychainSetUserInteractionAllowed(state: u8) -> i32;
}

const STORE: AuthCredentialsStoreMode = AuthCredentialsStoreMode::Keyring;
const BACKEND: AuthKeyringBackendKind = AuthKeyringBackendKind::Direct;
const MAX_REGISTRY: u64 = 64 * 1024;
const MAX_CHILD_OUTPUT: u64 = 16 * 1024;
const REGISTRY: &str = "identities.json";
type Result<T> = std::result::Result<T, &'static str>;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RegisteredIdentity {
    case_id: String,
    generation: String,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Registry {
    schema: u8,
    identities: Vec<RegisteredIdentity>,
}

#[derive(Serialize)]
struct Check {
    name: &'static str,
    expected_status: &'static str,
    observed_status: String,
    passed: bool,
}

#[derive(Serialize)]
struct Report {
    schema: u8,
    passed: bool,
    authorization_ui_disabled: bool,
    network_operations: usize,
    real_account_access: bool,
    checks: Vec<Check>,
    registered_identities: usize,
    confirmed_absent: usize,
    cleanup_complete: bool,
    failure: Option<&'static str>,
}

fn uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|id| !id.is_nil() && id.to_string() == value)
}

fn private_directory(path: &Path) -> Result<()> {
    let metadata = std::fs::symlink_metadata(path).map_err(|_| "fixture_directory_unavailable")?;
    if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o7777 != 0o700 || path.canonicalize().ok().as_deref() != Some(path)
    {
        return Err("fixture_directory_rejected");
    }
    Ok(())
}

fn new_directory(path: &Path) -> Result<()> {
    std::fs::DirBuilder::new().mode(0o700).create(path).map_err(|_| "fixture_directory_unavailable")?;
    private_directory(path)
}

fn validate_run(path: &Path) -> Result<()> {
    // build.py stages the crate directly under .build/CodexRuntime. A caller
    // cannot point this QA tool at the product namespace or a default home.
    let parent = Path::new(env!("CARGO_MANIFEST_DIR")).parent().ok_or("invalid_build_location")?;
    if parent.file_name().and_then(|part| part.to_str()) != Some("CodexRuntime")
        || parent.parent().and_then(Path::file_name).and_then(|part| part.to_str()) != Some(".build")
    {
        return Err("invalid_build_location");
    }
    let allowed = parent.join("worker-smoke").canonicalize().map_err(|_| "fixture_directory_unavailable")?;
    let name = path.file_name().and_then(|part| part.to_str()).ok_or("invalid_run_path")?;
    if path.parent() != Some(allowed.as_path()) || !name.strip_prefix("run-").is_some_and(uuid) {
        return Err("invalid_run_path");
    }
    private_directory(path)
}

fn write_registry(run: &Path, registry: &Registry) -> Result<()> {
    let bytes = serde_json::to_vec(registry).map_err(|_| "registry_unavailable")?;
    if bytes.len() as u64 > MAX_REGISTRY { return Err("registry_unavailable"); }
    let temporary = run.join(format!(".registry-{}", Uuid::new_v4()));
    let operation = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(&temporary)
            .map_err(|_| "registry_unavailable")?;
        file.write_all(&bytes).map_err(|_| "registry_unavailable")?;
        file.sync_all().map_err(|_| "registry_unavailable")?;
        std::fs::rename(&temporary, run.join(REGISTRY)).map_err(|_| "registry_unavailable")?;
        File::open(run).and_then(|directory| directory.sync_all()).map_err(|_| "registry_unavailable")
    })();
    if operation.is_err() { let _ = std::fs::remove_file(&temporary); }
    operation
}

fn read_registry(run: &Path) -> Result<Registry> {
    let file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(run.join(REGISTRY)).map_err(|_| "registry_unavailable")?;
    let metadata = file.metadata().map_err(|_| "registry_unavailable")?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o7777 != 0o600 || metadata.nlink() != 1
    {
        return Err("registry_rejected");
    }
    let mut bytes = Vec::new();
    file.take(MAX_REGISTRY + 1).read_to_end(&mut bytes).map_err(|_| "registry_unavailable")?;
    if bytes.len() as u64 > MAX_REGISTRY { return Err("registry_rejected"); }
    let registry: Registry = serde_json::from_slice(&bytes).map_err(|_| "registry_rejected")?;
    let mut cases = std::collections::BTreeSet::new();
    if registry.schema != 1 || registry.identities.len() > 16
        || registry.identities.iter().any(|entry| !uuid(&entry.case_id) || !uuid(&entry.generation)
            || !cases.insert(entry.case_id.as_str()))
    {
        return Err("registry_rejected");
    }
    Ok(registry)
}

fn case_root(run: &Path, entry: &RegisteredIdentity) -> Result<PathBuf> {
    if !uuid(&entry.case_id) || !uuid(&entry.generation) { return Err("registry_rejected"); }
    private_directory(&run.join("runtime"))?;
    let root = run.join("runtime").join(&entry.case_id);
    private_directory(&root)?;
    Ok(root)
}

fn registered_home(run: &Path, entry: &RegisteredIdentity) -> Result<PathBuf> {
    let root = case_root(run, entry)?;
    private_directory(&root.join("identities"))?;
    let home = root.join("identities").join(&entry.generation);
    private_directory(&home)?;
    Ok(home)
}

fn raw_present(home: &Path) -> Result<bool> {
    codex_login::load_auth_dot_json(home, STORE, BACKEND)
        .map(|value| value.is_some()).map_err(|_| "fixture_keyring_unavailable")
}

fn fixture_auth() -> Result<AuthDotJson> {
    let nonce = Uuid::new_v4().to_string();
    let claims = json!({"email":format!("fixture-{nonce}@example.invalid"),
        "https://api.openai.com/auth":{"chatgpt_account_id":format!("fixture-account-{nonce}"),
        "chatgpt_user_id":format!("fixture-user-{nonce}"),"chatgpt_plan_type":"plus"}});
    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
        serde_json::to_vec(&claims).map_err(|_| "fixture_construction_failed")?,
    );
    let id_token = format!("e30.{payload}.invalid-fixture-signature");
    serde_json::from_value(json!({"auth_mode":"chatgpt","tokens":{
        "id_token":id_token,"access_token":format!("fixture-access-{nonce}"),
        "refresh_token":format!("fixture-refresh-{nonce}"),"account_id":format!("fixture-account-{nonce}")},
        "last_refresh":"2026-09-26T00:00:00Z"}))
        .map_err(|_| "fixture_construction_failed")
}

fn request(operation: Operation) -> Request {
    Request { protocol_version: 1, request_id: Uuid::new_v4().to_string(), operation,
        expected_generation: None,
        model: None, text: None, source_language: None, target_language: None }
}

struct Case {
    storage: AccountStorage,
    root: PathBuf,
    identity: Identity,
    login: Request,
}

impl Case {
    fn new(run: &Path, registry: &mut Registry, with_auth: bool) -> Result<Self> {
        let case_id = Uuid::new_v4().to_string();
        let root = run.join("runtime").join(&case_id);
        new_directory(&root)?;
        let mut storage = AccountStorage::lock(&root).map_err(|_| "fixture_storage_unavailable")?;
        let login = request(Operation::Login);
        let identity = storage.begin_login(&login.request_id).map_err(|_| "fixture_storage_unavailable")?;
        registry.identities.push(RegisteredIdentity { case_id, generation: identity.generation.clone() });
        // Durable exact-home cleanup registration must precede the first save.
        write_registry(run, registry)?;
        if raw_present(&identity.home)? { return Err("fixture_identity_not_empty"); }
        if with_auth {
            codex_login::save_auth(&identity.home, &fixture_auth()?, STORE, BACKEND)
                .map_err(|_| "fixture_keyring_unavailable")?;
            if !raw_present(&identity.home)? { return Err("fixture_save_missing"); }
        }
        Ok(Self { storage, root, identity, login })
    }

    fn commit(&mut self, finalize: bool) -> Result<()> {
        self.storage.commit_login(&self.login.request_id, &self.identity.generation)
            .map_err(|_| "fixture_storage_unavailable")?;
        if finalize {
            self.storage.finalize_committed(&self.login.request_id, &self.identity.generation)
                .map_err(|_| "fixture_storage_unavailable")?;
        }
        Ok(())
    }
}

async fn call_worker(case: &Case, input: WorkerInput, separate_lease: bool) -> Result<Event> {
    let lease = if separate_lease {
        OpenOptions::new().read(true).write(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(case.root.join("account.lock")).map_err(|_| "fixture_lease_unavailable")?
    } else {
        case.storage.worker_lease().map_err(|_| "fixture_lease_unavailable")?
    };
    let descriptor = lease.as_raw_fd();
    let mut command = Command::new(std::env::current_exe().map_err(|_| "fixture_executable_unavailable")?);
    command.arg("--worker").arg(descriptor.to_string()).arg(&case.root)
        .env_clear().env("PATH", "/usr/bin:/bin").env("LANG", "en_US.UTF-8")
        .env("TMPDIR", std::env::var_os("TMPDIR").ok_or("fixture_directory_unavailable")?)
        .current_dir(&case.identity.home)
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    unsafe {
        command.pre_exec(move || {
            let flags = libc::fcntl(descriptor, libc::F_GETFD);
            if flags < 0 || libc::fcntl(descriptor, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn().map_err(|_| "fixture_spawn_failed")?;
    drop(lease);
    let mut stdout = child.stdout.take().ok_or("fixture_pipe_failed")?.take(MAX_CHILD_OUTPUT + 1);
    let mut stderr = child.stderr.take().ok_or("fixture_pipe_failed")?.take(4097);
    let mut stdin = child.stdin.take().ok_or("fixture_pipe_failed")?;
    let mut bytes = serde_json::to_vec(&input).map_err(|_| "fixture_serialization_failed")?;
    bytes.push(b'\n');
    let mut output = Vec::new();
    let mut errors = Vec::new();
    let operation = async {
        stdin.write_all(&bytes).await.map_err(|_| "fixture_pipe_failed")?;
        drop(stdin);
        let (output_result, error_result, exit_result) = tokio::join!(
            stdout.read_to_end(&mut output), stderr.read_to_end(&mut errors), child.wait(),
        );
        output_result.map_err(|_| "fixture_pipe_failed")?;
        error_result.map_err(|_| "fixture_pipe_failed")?;
        let exit = exit_result.map_err(|_| "fixture_reap_failed")?;
        if !exit.success() || !errors.is_empty() || output.len() as u64 > MAX_CHILD_OUTPUT {
            return Err("fixture_worker_failed");
        }
        Ok(())
    };
    match tokio::time::timeout(Duration::from_secs(12), operation).await {
        Ok(Ok(())) => {},
        failed => {
            let _ = child.start_kill();
            if !matches!(tokio::time::timeout(Duration::from_secs(2), child.wait()).await, Ok(Ok(_))) {
                return Err("fixture_reap_failed");
            }
            return Err(match failed { Ok(Err(error)) => error, _ => "fixture_worker_timeout" });
        }
    }
    // Parse the complete buffer as one object, so duplicate/truncated events fail.
    let event: Event = serde_json::from_slice(&output).map_err(|_| "fixture_invalid_output")?;
    if event.protocol_version != 1 || event.request_id != input.request.request_id
        || event.event != "terminal" || event.user_code.is_some() || event.verification_url.is_some()
        || event.result.is_none()
    {
        return Err("fixture_invalid_output");
    }
    Ok(event)
}

async fn check(
    case: &Case, name: &'static str, command: WorkerCommand, operation: Operation,
    home: PathBuf, separate_lease: bool, expected: &'static str,
) -> Result<Check> {
    let event = call_worker(case, WorkerInput { request: request(operation), identity_home: home, command }, separate_lease).await?;
    let outcome = event.result.ok_or("fixture_invalid_output")?;
    if outcome.text.is_some() || outcome.models.is_some() || outcome.generation.is_some()
        || outcome.remote_revocation.is_some()
    {
        return Err("fixture_invalid_output");
    }
    let safe_status = if ["signed_in", "signed_out", "invalid_account_storage", "busy"].contains(&outcome.status.as_str()) {
        outcome.status.clone()
    } else { "unexpected_status".into() };
    let passed = outcome.status == expected
        && if expected == "signed_in" { outcome.account_plan.as_deref() == Some("plus") } else { outcome.account_plan.is_none() };
    Ok(Check { name, expected_status: expected, observed_status: safe_status, passed })
}

async fn scenarios(run: &Path, registry: &mut Registry, checks: &mut Vec<Check>) -> Result<()> {
    let mut present = Case::new(run, registry, true)?;
    present.commit(true)?;
    checks.push(check(&present, "status_constructed_signed_in", WorkerCommand::Status, Operation::Status,
        present.identity.home.clone(), false, "signed_in").await?);
    if !raw_present(&present.identity.home)? { return Err("fixture_status_mutated_storage"); }

    let mut absent = Case::new(run, registry, false)?;
    absent.commit(true)?;
    checks.push(check(&absent, "status_strict_absence", WorkerCommand::Status, Operation::Status,
        absent.identity.home.clone(), false, "signed_out").await?);

    // Use a genuinely registered second fixture home as the wrong identity.
    checks.push(check(&present, "status_rejects_other_registered_home", WorkerCommand::Status, Operation::Status,
        absent.identity.home.clone(), false, "invalid_account_storage").await?);
    if !raw_present(&present.identity.home)? || raw_present(&absent.identity.home)? {
        return Err("fixture_wrong_home_mutated_storage");
    }

    checks.push(check(&present, "independent_descriptor_cannot_bypass_lease", WorkerCommand::Status, Operation::Status,
        present.identity.home.clone(), true, "busy").await?);
    if !raw_present(&present.identity.home)? { return Err("fixture_lease_mutated_storage"); }

    let mut pending_logout = Case::new(run, registry, true)?;
    pending_logout.commit(true)?;
    pending_logout.storage.begin_logout(&Uuid::new_v4().to_string()).map_err(|_| "fixture_storage_unavailable")?;
    checks.push(check(&pending_logout, "pending_logout_cleanup_deletes_exact_key", WorkerCommand::Cleanup, Operation::Logout,
        pending_logout.identity.home.clone(), false, "signed_out").await?);
    if raw_present(&pending_logout.identity.home)? { return Err("fixture_cleanup_left_key"); }
    checks.push(check(&pending_logout, "pending_cleanup_is_idempotent", WorkerCommand::Cleanup, Operation::Logout,
        pending_logout.identity.home.clone(), false, "signed_out").await?);

    let mut committed = Case::new(run, registry, true)?;
    committed.commit(false)?;
    checks.push(check(&committed, "cleanup_cannot_delete_committed_login", WorkerCommand::Cleanup, Operation::Login,
        committed.identity.home.clone(), false, "invalid_account_storage").await?);
    if !raw_present(&committed.identity.home)? { return Err("fixture_committed_key_deleted"); }
    Ok(())
}

fn cleanup_registered(run: &Path) -> Result<(usize, usize)> {
    let registry = read_registry(run)?;
    let mut absent = 0;
    let mut failed = false;
    for entry in &registry.identities {
        let operation = (|| {
            let root = case_root(run, entry)?;
            // A surviving worker holds the inherited lease. Never clean its item
            // concurrently or delete the canonical home after a cleanup failure.
            let storage = AccountStorage::lock(&root).map_err(|_| "fixture_cleanup_busy")?;
            let home = registered_home(run, entry)?;
            codex_login::logout(&home, STORE, BACKEND).map_err(|_| "fixture_cleanup_failed")?;
            if raw_present(&home)? { return Err("fixture_cleanup_left_key"); }
            drop(storage);
            Ok(())
        })();
        match operation {
            Ok(()) => absent += 1,
            Err(_) => failed = true,
        }
    }
    if failed { return Err("fixture_cleanup_incomplete"); }
    Ok((registry.identities.len(), absent))
}

fn report(value: &Report) -> i32 {
    // All fields are fixed statuses/counts/booleans. No token, original error,
    // account identifier, email, user code, or private response is serialized.
    match serde_json::to_vec(value) {
        Ok(mut bytes) => {
            bytes.push(b'\n');
            if io::stdout().write_all(&bytes).is_err() { return 74; }
            if value.passed { 0 } else { 1 }
        }
        Err(_) => 74,
    }
}

async fn driver(run: &Path, cleanup_only: bool) -> i32 {
    let mut checks = Vec::new();
    let mut failure = None;
    if !cleanup_only {
        if run.join(REGISTRY).exists() || new_directory(&run.join("runtime")).is_err() {
            return 64;
        }
        let mut registry = Registry { schema: 1, identities: Vec::new() };
        if write_registry(run, &registry).is_err() { return 64; }
        if let Err(error) = scenarios(run, &mut registry, &mut checks).await { failure = Some(error); }
    }
    let (registered, absent, cleanup_complete) = match cleanup_registered(run) {
        Ok((registered, absent)) => (registered, absent, true),
        Err(error) => {
            failure = Some(error);
            (read_registry(run).map_or(0, |value| value.identities.len()), 0, false)
        }
    };
    let passed = failure.is_none() && cleanup_complete && registered == absent
        && (cleanup_only || (checks.len() == 7 && checks.iter().all(|check| check.passed)));
    report(&Report { schema: 1, passed, authorization_ui_disabled: true,
        network_operations: 0, real_account_access: false, checks,
        registered_identities: registered, confirmed_absent: absent, cleanup_complete, failure })
}

async fn child(root: &Path, descriptor: i32) -> i32 {
    let Some(run) = root.parent().and_then(Path::parent) else { return 64 };
    if validate_run(run).is_err() || !root.file_name().and_then(|part| part.to_str()).is_some_and(uuid) {
        return 64;
    }
    let registry = match read_registry(run) { Ok(value) => value, Err(_) => return 64 };
    let Some(entry) = registry.identities.iter().find(|entry| root.file_name().and_then(|part| part.to_str()) == Some(entry.case_id.as_str())) else { return 64 };
    if case_root(run, entry).ok().as_deref() != Some(root) { return 64; }
    let input = match translatex_codex_runtime::protocol::read_bounded_line(&mut io::stdin().lock(), 16 * 1024) {
        Ok(Some(bytes)) => match serde_json::from_slice::<WorkerInput>(&bytes) {
            Ok(value) => value,
            Err(_) => return 64,
        },
        _ => return 64,
    };
    // A bug in the test driver cannot widen this tool into a real login,
    // policy reader, revoke client, or model request.
    if !matches!(input.command, WorkerCommand::Status | WorkerCommand::Cleanup) { return 64; }
    let lease = match worker::take_lease(descriptor) { Ok(value) => value, Err(_) => return 64 };
    worker::run(root, lease, input).await
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if !host::allowed_environment() || unsafe { SecKeychainSetUserInteractionAllowed(0) } != 0 {
        std::process::exit(65);
    }
    let code = match args.as_slice() {
        [_, operation, path] if matches!(operation.as_str(), "--run" | "--cleanup-run") => {
            let path = Path::new(path);
            if validate_run(path).is_err() { 64 } else { driver(path, operation == "--cleanup-run").await }
        }
        [_, operation, descriptor, root] if operation == "--worker" => {
            match descriptor.parse::<i32>() {
                Ok(value) => child(Path::new(root), value).await,
                Err(_) => 64,
            }
        }
        _ => 64,
    };
    std::process::exit(code);
}

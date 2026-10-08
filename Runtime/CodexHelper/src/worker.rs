//! One official account operation while retaining the parent's identity lease.
//! No tracing subscriber is installed: upstream stream/auth diagnostics must
//! never become stderr, protocol data, or a file on disk.
use crate::account_storage::{AccountStorage, OperationKind, RecoveryAction};
use crate::connection::{self, TrustedPolicyFileSystem};
use crate::policy;
use crate::protocol::{Event, Operation, Outcome, VERIFICATION_URL, WorkerCommand, WorkerInput, safe_label};
use codex_http_client::{HttpClientFactory, NetworkPolicyController, OutboundProxyPolicy};
use codex_login::{AuthCredentialsStoreMode, AuthDotJson, AuthKeyringBackendKind, AuthRouteConfig,
    ServerOptions, complete_device_code_login, load_auth_dot_json, logout,
    logout_with_revoke, request_device_code};
use codex_protocol::auth::AuthMode;
use codex_protocol::config_types::ForcedLoginMethod;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::path::Path;
use std::time::{Duration, Instant};

const STORE: AuthCredentialsStoreMode = AuthCredentialsStoreMode::Keyring;
const BACKEND: AuthKeyringBackendKind = AuthKeyringBackendKind::Direct;

/// Takes ownership of the inherited descriptor only after validating the
/// numeric range. The parent opened it CLOEXEC and clears that bit only in its
/// child's pre-exec hook. Re-arm CLOEXEC immediately; no grandchildren use it.
pub fn take_lease(fd: RawFd) -> io::Result<File> {
    if fd < 3 || unsafe { libc::fcntl(fd, libc::F_GETFD) } < 0 { return Err(io::Error::other("invalid_lease")); }
    let file = unsafe { File::from_raw_fd(fd) };
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file)
}

fn authorized_identity(storage: &AccountStorage, input: &WorkerInput) -> Result<(), &'static str> {
    if !input.request.valid() { return Err("invalid_input"); }
    if input.command != WorkerCommand::Cleanup
        && input.request.expected_generation.as_ref().is_some_and(|expected|
            input.identity_home.file_name().and_then(|name| name.to_str()) != Some(expected.as_str()))
    { return Err("account_changed"); }
    let action = storage.recovery_action().map_err(|error| error.status())?;
    let valid = match (&action, input.command) {
        (RecoveryAction::Cleanup { operation_id, kind: OperationKind::Login, identity }, WorkerCommand::Login) =>
            input.request.operation == Operation::Login && operation_id == &input.request.request_id
                && identity.home == input.identity_home,
        (RecoveryAction::Cleanup { operation_id, kind: OperationKind::Logout, identity }, WorkerCommand::Logout) =>
            input.request.operation == Operation::Logout && operation_id == &input.request.request_id
                && identity.home == input.identity_home,
        // Recovery uses the current native request ID. Its target must be the
        // exact durable pending record, never a caller-selected old identity.
        (RecoveryAction::Cleanup { identity, .. }, WorkerCommand::Cleanup) => identity.home == input.identity_home,
        (RecoveryAction::None, command @ (WorkerCommand::Status | WorkerCommand::Models | WorkerCommand::Translate)) => {
            let operation = match command { WorkerCommand::Status => Operation::Status,
                WorkerCommand::Models => Operation::Models, _ => Operation::Translate };
            input.request.operation == operation && storage.active().map_err(|error| error.status())?
                .is_some_and(|identity| identity.home == input.identity_home)
        }
        _ => false,
    };
    if valid { Ok(()) } else { Err("invalid_account_storage") }
}

/// The fixed root is selected by the executable, not by the worker payload.
pub async fn run(root: &Path, lease: File, input: WorkerInput) -> i32 {
    let storage = match AccountStorage::from_worker_lease(root, lease) {
        Ok(value) => value,
        Err(error) => return finish(&input, Outcome::error(error.status())),
    };
    if let Err(error) = authorized_identity(&storage, &input) { return finish(&input, Outcome::error(error)); }
    let result = match input.command {
        WorkerCommand::Status => status(&input.identity_home),
        WorkerCommand::Cleanup => cleanup(&input.identity_home),
        WorkerCommand::Login => login(&input).await,
        WorkerCommand::Logout => sign_out(&input.identity_home).await,
        WorkerCommand::Models => connection::models(&input.identity_home).await.map(|models| {
            let mut result = Outcome::new("ok"); result.models = Some(models); result
        }),
        WorkerCommand::Translate => connection::translate(&input.identity_home, &input.request).await.map(|text| {
            let mut result = Outcome::new("ok"); result.text = Some(text); result
        }),
    };
    // Retain storage/lease until both the terminal write and all credential work
    // are complete. Process termination, not this reply, releases the parent.
    let code = if matches!(result, Err("output_closed")) { 74 }
        else { finish(&input, result.unwrap_or_else(operation_error)) };
    drop(storage);
    code
}

fn finish(input: &WorkerInput, outcome: Outcome) -> i32 {
    if write_event(&Event::terminal(&input.request, outcome)).is_ok() { 0 } else { 74 }
}

fn operation_error(code: &'static str) -> Outcome {
    // Only the explicit status/cleanup branch can assert strict Keychain
    // absence. An auth manager losing its cache during a request cannot.
    Outcome::error(if code == "signed_out" { "authentication_failed" } else { code })
}

fn status(home: &Path) -> Result<Outcome, &'static str> {
    let Some(auth) = load_auth_dot_json(home, STORE, BACKEND).map_err(|_| "storage_unavailable")? else {
        // This status is a strict absence assertion; the supervisor may clear
        // an empty active pointer only after this worker has exited.
        return Ok(Outcome::new("signed_out"));
    };
    let plan = stored_account_plan(&auth)?;
    let mut outcome = Outcome::new("signed_in"); outcome.account_plan = plan; Ok(outcome)
}

fn stored_account_plan(auth: &AuthDotJson) -> Result<Option<String>, &'static str> {
    if auth.auth_mode.is_some_and(|mode| mode != AuthMode::Chatgpt)
        || auth.openai_api_key.is_some() || auth.agent_identity.is_some()
        || auth.personal_access_token.is_some() || auth.bedrock_api_key.is_some() || auth.bedrock_access_keys.is_some()
    { return Err("authentication_failed"); }
    let tokens = auth.tokens.as_ref().ok_or("authentication_failed")?;
    let account = tokens.account_id.as_ref().filter(|value| !value.trim().is_empty()).ok_or("authentication_failed")?;
    if tokens.access_token.trim().is_empty() || tokens.refresh_token.trim().is_empty()
        || tokens.id_token.raw_jwt.trim().is_empty() || auth.last_refresh.is_none()
        || tokens.id_token.chatgpt_account_id.as_ref().is_some_and(|value| value != account)
    { return Err("authentication_failed"); }
    // Never surface unrecognized plan text from claims as account information.
    Ok(tokens.id_token.get_chatgpt_plan_type_raw()
        .filter(|value| ["free", "go", "plus", "pro", "team", "business", "enterprise", "edu"].contains(&value.as_str())))
}

fn cleanup(home: &Path) -> Result<Outcome, &'static str> {
    logout(home, STORE, BACKEND).map_err(|_| "cleanup_required")?;
    if load_auth_dot_json(home, STORE, BACKEND).map_err(|_| "cleanup_required")?.is_some() {
        return Err("cleanup_required");
    }
    Ok(Outcome::new("signed_out"))
}

async fn local_route(home: &Path) -> Result<(ServerOptions, NetworkPolicyController), &'static str> {
    let controller = NetworkPolicyController::default();
    let revision = controller.policy().revision();
    let local = policy::load_local_trusted(&TrustedPolicyFileSystem, home).await.map_err(|error| error.status())?;
    let network = local.snapshot.publish(&controller, revision).map_err(|error| error.status())?;
    let factory = HttpClientFactory::new(OutboundProxyPolicy::RespectSystemProxy).with_network_policy(network.for_current_account());
    let route = AuthRouteConfig::from_http_client_factory(factory);
    let config = local.snapshot.auth_config(home.to_path_buf(), route.clone()).map_err(|error| error.status())?;
    if !config.is_login_method_allowed(ForcedLoginMethod::Chatgpt) { return Err("managed_auth_denied"); }
    let mut options = ServerOptions::new(home.to_path_buf(), codex_login::CLIENT_ID.to_owned(),
        config.effective_chatgpt_workspaces(), STORE, BACKEND, route);
    options.open_browser = false;
    Ok((options, controller))
}

fn valid_device_code(code: &str, url: &str) -> bool {
    url == VERIFICATION_URL && !code.is_empty() && code.len() <= 128
        && code.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b' ')
        && !code.trim().is_empty()
}

async fn login(input: &WorkerInput) -> Result<Outcome, &'static str> {
    // The durable pending identity must start empty; never replace credentials.
    if load_auth_dot_json(&input.identity_home, STORE, BACKEND).map_err(|_| "storage_unavailable")?.is_some() {
        return Err("invalid_account_storage");
    }
    let (options, controller) = tokio::time::timeout(Duration::from_secs(20), local_route(&input.identity_home))
        .await.map_err(|_| "timeout")??;
    let code = tokio::time::timeout(Duration::from_secs(20), request_device_code(&options))
        .await.map_err(|_| "timeout")?.map_err(|_| "login_unavailable")?;
    if !valid_device_code(&code.user_code, &code.verification_url) { return Err("login_failed"); }
    write_event(&Event::ready(&input.request, code.user_code.clone(), code.verification_url.clone()))
        .map_err(|_| "output_closed")?;
    // Reserve time within the native 15-minute operation for initial and final
    // policy checks. The parent can kill/reap this worker during every stage.
    let result = tokio::time::timeout(Duration::from_secs(780), complete_device_code_login(options, code))
        .await.map_err(|_| "timeout")?.map_err(|_| "login_failed");
    controller.policy().invalidate();
    result?;
    let account_plan = connection::validate_login(&input.identity_home).await?;
    if account_plan.as_ref().is_some_and(|value| !safe_label(value, 128)) { return Err("authentication_failed"); }
    let mut outcome = Outcome::new("login_ready_commit"); outcome.account_plan = account_plan; Ok(outcome)
}

async fn sign_out(home: &Path) -> Result<Outcome, &'static str> {
    // A changed/denying management policy never blocks deletion of the local
    // account. Network revoke is attempted only under a valid current route.
    if let Ok(Ok((options, controller))) = tokio::time::timeout(Duration::from_secs(10), local_route(home)).await {
        let _ = tokio::time::timeout(Duration::from_secs(10), logout_with_revoke(home, STORE, BACKEND, &options.auth_route_config)).await;
        controller.policy().invalidate();
    }
    let mut outcome = cleanup(home)?;
    // The upstream API deliberately swallows revoke errors. We can assert
    // local absence, but not remote revocation, even when its Result is Ok.
    outcome.remote_revocation = Some("unconfirmed".into());
    Ok(outcome)
}

/// Bounded writes also cover a native owner which stopped reading after launch.
/// A partial/failed event is never followed by another success event.
pub fn write_event(event: &Event) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(event).map_err(io::Error::other)?;
    bytes.push(b'\n');
    if bytes.len() > crate::protocol::MAX_OUTPUT { return Err(io::Error::other("output_too_large")); }
    let fd = libc::STDOUT_FILENO;
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut position = 0;
    while position < bytes.len() {
        if Instant::now() >= deadline { return Err(io::Error::new(io::ErrorKind::TimedOut, "output_closed")); }
        let count = unsafe { libc::write(fd, bytes[position..].as_ptr().cast(), bytes.len() - position) };
        if count > 0 { position += count as usize; continue; }
        let error = io::Error::last_os_error();
        if count == 0 { return Err(io::Error::new(io::ErrorKind::WriteZero, "output_closed")); }
        if error.kind() == io::ErrorKind::Interrupted { continue; }
        if error.kind() != io::ErrorKind::WouldBlock { return Err(error); }
        let mut poll = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
        let wait = deadline.saturating_duration_since(Instant::now()).as_millis().min(100) as i32;
        if unsafe { libc::poll(&mut poll, 1, wait) } < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::DirBuilderExt;
    use uuid::Uuid;

    #[test]
    fn auth_cache_absence_is_not_a_strict_storage_absence_assertion() {
        assert_eq!(operation_error("signed_out").status, "authentication_failed");
    }

    #[test]
    fn login_prompt_only_accepts_exact_official_destination_and_bounded_code() {
        assert!(valid_device_code("ABCD-EFGH", VERIFICATION_URL));
        for url in ["https://auth.openai.com/codex/device?token=constructed", "https://auth.openai.com.other.invalid/codex/device", "http://auth.openai.com/codex/device"] {
            assert!(!valid_device_code("ABCD-EFGH", url));
        }
        for code in ["", "  ", "code\nbody", "中文"] { assert!(!valid_device_code(code, VERIFICATION_URL)); }
        assert!(!valid_device_code(&"A".repeat(129), VERIFICATION_URL));
    }
    #[test]
    fn worker_requires_exact_pending_or_active_identity_and_operation() {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!("translatex-worker-test-{}", Uuid::new_v4()));
        std::fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let mut storage = AccountStorage::lock(&root).unwrap();
        let request = crate::protocol::Request { protocol_version: 1, request_id: Uuid::new_v4().to_string(), operation: Operation::Login,
            expected_generation: None,
            model: None, text: None, source_language: None, target_language: None };
        let identity = storage.begin_login(&request.request_id).unwrap();
        let worker_storage = AccountStorage::from_worker_lease(&root, storage.worker_lease().unwrap()).unwrap();
        let mut input = WorkerInput { request, identity_home: identity.home, command: WorkerCommand::Login };
        assert!(authorized_identity(&worker_storage, &input).is_ok());
        input.identity_home = root.join("identities").join(Uuid::new_v4().to_string());
        assert!(authorized_identity(&worker_storage, &input).is_err());
        input.identity_home = storage.recovery_action().ok().and_then(|action| match action { RecoveryAction::Cleanup { identity, .. } => Some(identity.home), _ => None }).unwrap();
        input.command = WorkerCommand::Status;
        assert!(authorized_identity(&worker_storage, &input).is_err());
        input.command = WorkerCommand::Cleanup;
        assert!(authorized_identity(&worker_storage, &input).is_ok());
        storage.commit_login(&input.request.request_id, &identity.generation).unwrap();
        assert!(authorized_identity(&worker_storage, &input).is_err());
        storage.finalize_committed(&input.request.request_id, &identity.generation).unwrap();
        input.command = WorkerCommand::Status; input.request.operation = Operation::Status;
        assert!(authorized_identity(&worker_storage, &input).is_ok());
        drop(worker_storage); drop(storage); std::fs::remove_dir_all(root).unwrap();
    }
}

//! Isolated official-device-code / strict-Keyring fixture helper. Never a real account client.
mod account_request;
mod auth_policy;
mod translation;
mod sse_guard;

use codex_http_client::{
    DestinationPolicy, HttpClientFactory, NetworkPolicyController, OutboundProxyPolicy
};
use codex_keyring_store::{DefaultKeyringStore, KeyringStore};
use codex_login::{
    AuthCredentialsStoreMode, AuthKeyringBackendKind, AuthManager, AuthRouteConfig, ServerOptions
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs::{File, OpenOptions},
    io::{BufRead, Read, Write},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::{Path, PathBuf},
    process::Stdio,
    sync::{Arc, Mutex},
    time::{Duration, Instant}
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::Command
};
use url::Url;
use uuid::Uuid;

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SecKeychainSetUserInteractionAllowed(state: u8) -> i32;
}
unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}
const STORE: AuthCredentialsStoreMode = AuthCredentialsStoreMode::Keyring;
const BACKEND: AuthKeyringBackendKind = AuthKeyringBackendKind::Direct;
const CLIENT_ID: &str = "translatex-fixture-client";

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Input {
    operation: String,
    identity_home: PathBuf,
    issuer: String,
    #[serde(default)]
    deadline_ms: Option<u64>,
    #[serde(default)]
    expected_account_id: Option<String>,
    #[serde(default)]
    expected_user_id: Option<String>,
    #[serde(default)]
    cancel_after_saved: bool,
    #[serde(default)]
    protocol_version: Option<u32>,
    #[serde(default)]
    request_id: Option<String>,
    #[serde(default)]
    fixture_pause_before_promotion_ms: u64,
    #[serde(default)]
    fixture_pause_after_promotion_ms: u64,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    fixture_policy_case: Option<String>,
    #[serde(default)]
    fixture_policy_workspace: Option<String>,
    #[serde(default)]
    fixture_replacement_home: Option<PathBuf>,
    #[serde(default)]
    fixture_refresh: bool,
    // Internal worker fields. Public supervisor rejects them.
    #[serde(default)]
    stage_home: Option<PathBuf>,
    #[serde(default)]
    cleanup_homes: Vec<PathBuf>,
}

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fixed app directory")
        .to_path_buf()
}

fn fixed(status: &str) -> Value {
    json!({"status": status, "authorization_ui_disabled": true})
}

fn valid_home(home: &Path) -> bool {
    let Ok(base) = root().join("runtime").canonicalize() else {
        return false;
    };
    let Ok(actual) = home.canonicalize() else {
        return false;
    };
    home.is_absolute()
        && actual == home
        && actual.starts_with(&base)
        && actual != base
        && actual.is_dir()
}

fn valid(input: &Input, worker: bool) -> bool {
    let Ok(url) = Url::parse(&input.issuer) else {
        return false
    };
    if url.scheme() != "http"
        || url.host_str() != Some("127.0.0.1")
        || url.port().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        return false
    }
    if !valid_home(&input.identity_home) {
        return false
    }
    if worker {
        if input.stage_home.as_ref().is_some_and(|p| !valid_home(p))
            || input.cleanup_homes.iter().any(|p| !valid_home(p))
        {
            return false
        }
    } else if input.stage_home.is_some()
        || !input.cleanup_homes.is_empty()
        || !matches!(
            input.operation.as_str(),
            "request_device_code"
                | "complete_device_code_login"
                | "status"
                | "logout"
                | "fixture_corrupt_storage"
                | "login_session"
                | "authenticated_translate"
        )
    {
        return false
    }
    if input.operation == "login_session" || input.operation == "__session_stage" {
        let Some(id) = input.request_id.as_ref() else {
            return false;
        };
        if input.protocol_version != Some(1)
            || id.len() != 36
            || Uuid::parse_str(id).is_err()
            || input.fixture_pause_before_promotion_ms > 1000
            || input.fixture_pause_after_promotion_ms > 1000
        {
            return false;
        }
    }
    if input.fixture_replacement_home.as_ref().is_some_and(|home|
        !valid_home(home) || home == &input.identity_home
            || home.parent() != input.identity_home.parent())
        || input.text.as_ref().is_some_and(|text| text.len() > 8192 || text.trim().is_empty())
        || input.fixture_policy_case.as_ref().is_some_and(|value| value.len() > 64)
        || input.fixture_policy_workspace.as_ref().is_some_and(|value| value.len() > 256)
    {
        return false;
    }
    true
}

async fn authenticated_translate(input: &Input) -> Value {
    let Some(text) = input.text.as_ref() else { return fixed("invalid_input") };
    let snapshot = match auth_policy::load_fixture(
        input.fixture_policy_case.as_deref().unwrap_or("default"),
        &input.identity_home, input.fixture_policy_workspace.as_deref(),
    ).await {
        Ok(snapshot) => snapshot,
        Err(status) => return fixed(status),
    };
    let controller = NetworkPolicyController::default();
    let policy = match snapshot.install_network_policy(&controller) {
        Ok(policy) => policy,
        Err(status) => return fixed(status),
    };
    let issuer = input.issuer.trim_end_matches('/');
    let model_url = Url::parse(&format!("{issuer}/v1/responses")).expect("validated issuer");
    let endpoints = [model_url.clone(), Url::parse(&format!("{issuer}/oauth/token")).expect("validated issuer")]
        .into_iter().collect();
    let policy = policy.restrict_to_endpoints(endpoints);
    let factory = HttpClientFactory::new(OutboundProxyPolicy::ReqwestDefault)
        .with_network_policy(policy.clone());
    let config = snapshot.auth_config(input.identity_home.clone(), Some(input.issuer.clone()),
        AuthRouteConfig::from_http_client_factory(factory));
    if config.validate().is_err()
        || !config.is_login_method_allowed(codex_protocol::config_types::ForcedLoginMethod::Chatgpt)
    {
        return fixed("managed_auth_denied");
    }
    // Explicitly check the official load result: AuthManager initialization can
    // otherwise collapse a policy/storage load error into a signed-out snapshot.
    let expected = match config.load_auth(false).await {
        Ok(Some(auth)) => auth,
        Ok(None) => return fixed(if read_presence(&input.identity_home) == Ok(true) {
            "managed_auth_denied"
        } else { "signed_out" }),
        Err(_) => return fixed("managed_auth_or_storage_denied"),
    };
    let manager = match AuthManager::shared_from_auth_config(config, false).await {
        Ok(manager) => manager,
        Err(_) => return fixed("auth_initialization_failed"),
    };
    let bound_policy = manager.application_network_policy().for_current_account();
    let prepared = match account_request::prepare_account_request(manager, expected,
        account_request::AccountRequestOptions {
            fixture_replacement_home: input.fixture_replacement_home.clone(),
            explicit_refresh: input.fixture_refresh,
        }).await {
        Ok(prepared) => prepared,
        Err(error) => {
            let mut value = fixed(error.status());
            value["auth_checks"] = json!(error.checks);
            value["transport_attempts"] = json!(0);
            return value;
        }
    };
    // Loopback fixtures deliberately use the engine's no-proxy/no-retry raw
    // transport. Retain the official account-bound permit for the entire auth,
    // request and stream operation. Product traffic needs official routing.
    let mut result = match bound_policy.acquire(&model_url) {
        Ok(permit) => match permit.run(translation::run(
            json!({"endpoint": format!("{issuer}/v1"), "text": text}), prepared.provider,
        )).await {
            Ok(value) => value,
            Err(_) => json!({"status":"managed_network_denied", "transport_attempts":0}),
        },
        Err(_) => json!({"status":"managed_network_denied", "transport_attempts":0}),
    };
    result["authorization_ui_disabled"] = json!(true);
    result["auth_checks"] = json!(prepared.checks);
    result
}

fn route(input: &Input) -> AuthRouteConfig {
    let endpoints: BTreeSet<_> = [
        "/api/accounts/deviceauth/usercode",
        "/api/accounts/deviceauth/token",
        "/oauth/token"
    ]
    .into_iter()
    .map(|path|
        Url::parse(&format!("{}{}", input.issuer.trim_end_matches('/'), path))
            .expect("validated loopback URL")
    )
    .collect();
    // Managed policy enters the official route-aware path, including redirect checks.
    // The endpoint restriction still narrows Unrestricted to these three loopback URLs.
    let controller = NetworkPolicyController::default();
    let policy = controller.policy();
    assert!(controller.publish(policy.revision(), DestinationPolicy::Unrestricted));
    let factory = HttpClientFactory::new(OutboundProxyPolicy::ReqwestDefault)
        .with_network_policy(policy.restrict_to_endpoints(endpoints));
    AuthRouteConfig::from_http_client_factory(factory)
}

fn options(input: &Input, home: PathBuf) -> ServerOptions {
    let mut options = ServerOptions::new(home, CLIENT_ID.into(), None, STORE, BACKEND, route(input));
    options.issuer = input.issuer.trim_end_matches('/').into();
    options.open_browser = false;
    options
}

fn read_presence(home: &Path) -> Result<bool, ()> {
    codex_login::load_auth_dot_json(home, STORE, BACKEND)
        .map(|auth| auth.is_some())
        .map_err(|_| ())
}

fn clear(home: &Path) -> bool {
    codex_login::logout(home, STORE, BACKEND).is_ok() && read_presence(home) == Ok(false)
}

async fn status(input: &Input) -> Value {
    match read_presence(&input.identity_home) {
        Err(()) => fixed("storage_unavailable"),
        Ok(false) => json!({
            "status": "signed_out",
            "target_auth_present": false,
            "authorization_ui_disabled": true
        }),
        Ok(true) => {
            let manager = AuthManager::shared(
                input.identity_home.clone(),
                false,
                STORE,
                None,
                Some(input.issuer.clone()),
                BACKEND,
                route(input)
            )
            .await;
            let Some(auth) = manager.auth_cached() else {
                return fixed("invalid_stored_auth")
            };
            if !auth.is_chatgpt_auth() {
                return fixed("unexpected_auth_method")
            }
            let adapter = codex_model_provider::auth_provider_from_auth_manager(
                Arc::clone(&manager), &auth
            );
            // Inspect only whether the official adapter can construct headers; never return values.
            let headers = adapter.to_auth_headers();
            let account_matches = input.expected_account_id.as_ref()
                .map(|id| auth.get_account_id().as_ref() == Some(id));
            let user_matches = input.expected_user_id.as_ref()
                .map(|id| auth.get_chatgpt_user_id().as_ref() == Some(id));
            json!({
                "status": "signed_in",
                "target_auth_present": true,
                "auth_header_present": headers.contains_key("authorization"),
                "account_matches": account_matches,
                "user_matches": user_matches,
                "authorization_ui_disabled": true
            })
        }
    }
}

async fn worker(input: Input) -> Value {
    match input.operation.as_str() {
        "authenticated_translate" => authenticated_translate(&input).await,
        "status" => status(&input).await,
        "logout" => if clear(&input.identity_home) {
            json!({
                "status": "signed_out",
                "target_auth_present": false,
                "authorization_ui_disabled": true
            })
        } else {
            fixed("storage_unavailable")
        },
        "fixture_corrupt_storage" => {
            if read_presence(&input.identity_home) != Ok(false) {
                return fixed("target_not_empty")
            }
            // Match the pinned official DirectKeyringAuthStorage key, only for a
            // caller-created canonical fixture home. This never enumerates keys.
            let digest = format!(
                "{:x}",
                Sha256::digest(input.identity_home.to_string_lossy().as_bytes())
            );
            let account = format!("cli|{}", &digest[..16]);
            if DefaultKeyringStore.save("Codex Auth", &account, "fixture-invalid-auth-json").is_err() {
                return fixed("storage_unavailable")
            }
            fixed("fixture_corrupted")
        },
        "request_device_code" => match codex_login::request_device_code(
            &options(&input, input.identity_home.clone())
        )
        .await
        {
            Ok(code) if code.user_code.len() <= 128 => json!({
                "status": "device_code_ready",
                "user_code": code.user_code,
                "verification_url": code.verification_url,
                "authorization_ui_disabled": true
            }),
            _ => fixed("device_code_failed"),
        },
        "__login_stage" | "__session_stage" => {
            let Some(stage) = input.stage_home.clone() else {
                return fixed("invalid_input")
            };
            let opts = options(&input, stage.clone());
            let code = match codex_login::request_device_code(&opts).await {
                Ok(code) => code,
                Err(_) => return fixed("device_code_failed")
            };
            if input.operation == "__session_stage" {
                if code.user_code.is_empty() || code.user_code.len() > 128
                    || code.verification_url.len() > 512
                {
                    return fixed("device_code_failed");
                }
                let mut ready = session_event(&input, "ready");
                ready["user_code"] = json!(code.user_code);
                ready["verification_url"] = json!(code.verification_url);
                if !emit_line(&ready) {
                    return fixed("output_closed");
                }
            }
            match codex_login::complete_device_code_login(opts, code).await {
                Ok(()) if read_presence(&stage) == Ok(true) => fixed("stage_ready"),
                Ok(()) => fixed("storage_unavailable"),
                Err(error) => {
                    // Only classify fixed upstream storage prefixes; never return the error text.
                    let message = error.to_string();
                    if message.starts_with("failed to write OAuth tokens to keyring:")
                        || message.starts_with("failed to load CLI auth from keyring:")
                        || message.starts_with("failed to deserialize CLI auth from keyring:")
                    {
                        fixed("storage_unavailable")
                    } else {
                        fixed("login_failed")
                    }
                }
            }
        },
        "__promote" => {
            let Some(stage) = input.stage_home.as_ref() else {
                return fixed("invalid_input")
            };
            if read_presence(&input.identity_home) != Ok(false) {
                return fixed("target_changed")
            }
            let stored = match codex_login::load_auth_dot_json(stage, STORE, BACKEND) {
                Ok(Some(value)) => value,
                _ => return fixed("storage_unavailable")
            };
            if codex_login::save_auth(&input.identity_home, &stored, STORE, BACKEND).is_err() {
                return fixed("storage_unavailable")
            }
            status(&input).await
        },
        "__cleanup" => {
            let mut cleaned = true;
            for home in &input.cleanup_homes {
                cleaned = clear(home) && cleaned;
            }
            json!({
                "status": if cleaned {"cleanup_complete"} else {"cleanup_required"},
                "stage_cleanup_ok": cleaned,
                "authorization_ui_disabled": true
            })
        },
        _ => fixed("invalid_operation"),
    }
}

struct ChildResult {
    value: Value,
    reaped: bool
}

async fn terminate(process: &mut tokio::process::Child) -> bool {
    let _ = process.start_kill();
    matches!(
        tokio::time::timeout(Duration::from_secs(2), process.wait()).await,
        Ok(Ok(_))
    )
}

async fn child(input: &Input, limit: Duration) -> ChildResult {
    let started = Instant::now();
    let Ok(executable) = std::env::current_exe() else {
        return ChildResult { value: fixed("worker_failed"), reaped: true }
    };
    let mut command = Command::new(executable);
    command.arg("--worker")
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("LANG", "en_US.UTF-8")
        .env("TMPDIR", root().join("tmp"))
        .current_dir(root())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    if input.operation == "authenticated_translate" {
        command.env("CODEX_REFRESH_TOKEN_URL_OVERRIDE", format!("{}/oauth/token", input.issuer.trim_end_matches('/')));
    }
    let spawn = command.spawn();
    let mut process = match spawn {
        Ok(process) => process,
        Err(_) => return ChildResult { value: fixed("worker_failed"), reaped: true }
    };
    let Some(mut stdin) = process.stdin.take() else {
        return ChildResult {
            value: fixed("worker_failed"),
            reaped: terminate(&mut process).await
        }
    };
    let data = match serde_json::to_vec(input) {
        Ok(data) => data,
        Err(_) => return ChildResult {
            value: fixed("worker_failed"),
            reaped: terminate(&mut process).await
        }
    };
    if !matches!(
        tokio::time::timeout(remaining(started, limit), stdin.write_all(&data)).await,
        Ok(Ok(()))
    ) {
        return ChildResult {
            value: fixed("worker_failed"),
            reaped: terminate(&mut process).await
        }
    }
    drop(stdin);
    let Some(stdout) = process.stdout.take() else {
        return ChildResult {
            value: fixed("worker_failed"),
            reaped: terminate(&mut process).await
        }
    };
    let output = tokio::spawn(async move {
        let mut bytes = Vec::new();
        let _ = stdout.take(32769).read_to_end(&mut bytes).await;
        bytes
    });
    match tokio::time::timeout(remaining(started, limit), process.wait()).await {
        Ok(Ok(exit)) => {
            let bytes = output.await.unwrap_or_default();
            let value = if exit.success() && bytes.len() <= 32768 {
                serde_json::from_slice(&bytes).unwrap_or_else(|_| fixed("worker_failed"))
            } else {
                fixed("worker_failed")
            };
            ChildResult { value, reaped: true }
        }
        _ => {
            let reaped = terminate(&mut process).await;
            output.abort();
            let _ = output.await;
            ChildResult { value: fixed("cancelled"), reaped }
        }
    }
}

fn lock(home: &Path) -> Result<File, ()> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(home.join(".translatex-auth-probe.lock"))
        .map_err(|_| ())?;
    if !file.metadata().map_err(|_| ())?.is_file() {
        return Err(())
    }
    // A kernel lock is released on process death; an empty lock file is not a stale lock.
    if unsafe { flock(file.as_raw_fd(), 2 | 4) } != 0 {
        return Err(())
    }
    Ok(file)
}

fn remaining(start: Instant, deadline: Duration) -> Duration {
    deadline.saturating_sub(start.elapsed())
}

async fn cleanup(input: &Input, homes: Vec<PathBuf>) -> bool {
    let mut cleanup = input.clone();
    cleanup.operation = "__cleanup".into();
    cleanup.cleanup_homes = homes;
    let result = child(&cleanup, Duration::from_secs(2)).await;
    result.reaped && result.value.get("status").and_then(Value::as_str) == Some("cleanup_complete")
}

async fn supervise(input: Input) -> Value {
    let start = Instant::now();
    let limit = Duration::from_millis(input.deadline_ms.unwrap_or(6000).clamp(1, 6000));
    if matches!(input.operation.as_str(), "request_device_code" | "status") {
        let result = child(&input, limit).await;
        let mut value = result.value;
        value["worker_reaped"] = json!(result.reaped);
        return value;
    }
    let _lock = match lock(&input.identity_home) {
        Ok(lock) => lock,
        Err(()) => return fixed("identity_busy")
    };
    if matches!(input.operation.as_str(), "logout" | "fixture_corrupt_storage" | "authenticated_translate") {
        let result = child(&input, limit).await;
        let mut value = result.value;
        value["worker_reaped"] = json!(result.reaped);
        return value;
    }
    let mut check = input.clone();
    check.operation = "status".into();
    let initial = child(&check, remaining(start, limit)).await;
    if !initial.reaped {
        return fixed("cleanup_required")
    }
    match initial.value.get("status").and_then(Value::as_str) {
        Some("signed_out") => {},
        Some("signed_in") => return fixed("already_signed_in"),
        _ => return initial.value,
    }
    let stage = root().join("runtime").join(format!("stage-{}", Uuid::new_v4()));
    if std::fs::create_dir(&stage).is_err() {
        return fixed("staging_failed")
    }
    let journal = input.identity_home.join(".pending-auth-cleanup.json");
    let mut journal_file = match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&journal)
    {
        Ok(file) => file,
        Err(_) => {
            let _ = std::fs::remove_dir(&stage);
            return fixed("cleanup_required")
        }
    };
    let journal_json = json!({
        "stage_home": stage,
        "target_home": input.identity_home,
        "target_initially_signed_out": true
    });
    if journal_file.write_all(journal_json.to_string().as_bytes())
        .and_then(|_| journal_file.sync_all())
        .is_err()
    {
        return fixed("cleanup_required")
    }
    let mut login = input.clone();
    login.operation = "__login_stage".into();
    login.stage_home = Some(stage.clone());
    let login_result = child(&login, remaining(start, limit)).await;
    let mut reaped = login_result.reaped;
    let mut outcome = login_result.value;
    let mut promotion_started = false;
    let stage_saved = reaped && outcome.get("status").and_then(Value::as_str) == Some("stage_ready");
    if stage_saved && input.cancel_after_saved {
        outcome = fixed("cancelled");
    } else if stage_saved {
        promotion_started = true;
        let mut promotion = login.clone();
        promotion.operation = "__promote".into();
        let result = child(&promotion, remaining(start, limit)).await;
        reaped = result.reaped;
        outcome = result.value;
    }
    let signed_in = outcome.get("status").and_then(Value::as_str) == Some("signed_in");
    let target_changed = outcome.get("status").and_then(Value::as_str) == Some("target_changed");
    // Never delete a target this attempt did not write. A competing actor which
    // ignores this fixture's kernel lock is outside our ownership boundary.
    let homes = if signed_in || !promotion_started || target_changed {
        vec![stage.clone()]
    } else {
        vec![stage.clone(), input.identity_home.clone()]
    };
    let mut cleaned = if reaped {
        cleanup(&input, homes.clone()).await
    } else {
        false
    };
    // Retain the empty canonical home for independent post-cleanup verification.
    if cleaned {
        cleaned = std::fs::remove_file(&journal).is_ok();
    }
    if !cleaned {
        outcome = fixed("cleanup_required");
        outcome["pending_cleanup_homes"] = json!(homes);
        outcome["cleanup_journal"] = json!(journal);
    }
    outcome["stage_cleanup_ok"] = json!(cleaned);
    outcome["worker_reaped"] = json!(reaped);
    outcome["stage_home"] = json!(stage);
    outcome["stage_saved_confirmed"] = json!(stage_saved);
    if cleaned && !target_changed {
        outcome["target_auth_present"] = json!(signed_in);
    }
    outcome
}

const INITIAL_LINE_LIMIT: usize = 32768;
const CONTROL_LINE_LIMIT: usize = 4096;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CancelMessage {
    operation: String,
    protocol_version: u32,
    request_id: String,
}

#[derive(Default)]
struct SessionControl {
    reason: Option<&'static str>,
    committed: bool,
}

type SharedControl = Arc<Mutex<SessionControl>>;

fn read_bounded_line(reader: &mut impl BufRead, limit: usize) -> Result<Option<Vec<u8>>, ()> {
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf().map_err(|_| ())?;
        if available.is_empty() {
            return Ok(if line.is_empty() { None } else { Some(line) });
        }
        let count = available.iter().position(|byte| *byte == b'\n')
            .map_or(available.len(), |position| position + 1);
        if line.len().saturating_add(count) > limit {
            return Err(());
        }
        line.extend_from_slice(&available[..count]);
        let ended = line.last() == Some(&b'\n');
        reader.consume(count);
        if ended {
            return Ok(Some(line));
        }
    }
}

fn session_event(input: &Input, event: &str) -> Value {
    json!({
        "event": event,
        "protocol_version": 1,
        "request_id": input.request_id,
        "authorization_ui_disabled": true,
    })
}

fn emit_line(value: &Value) -> bool {
    let Ok(mut bytes) = serde_json::to_vec(value) else {
        return false;
    };
    if bytes.len() >= INITIAL_LINE_LIMIT {
        return false;
    }
    bytes.push(b'\n');
    let mut output = std::io::stdout().lock();
    output.write_all(&bytes).and_then(|_| output.flush()).is_ok()
}

fn stop_session(control: &SharedControl, reason: &'static str) {
    let mut state = control.lock().expect("session control mutex");
    if !state.committed && state.reason.is_none() {
        state.reason = Some(reason);
    }
}

fn session_reason(control: &SharedControl, start: Instant, limit: Duration) -> Option<&'static str> {
    let mut state = control.lock().expect("session control mutex");
    if !state.committed && state.reason.is_none() && start.elapsed() >= limit {
        state.reason = Some("timed_out");
    }
    state.reason
}

fn start_control_reader(
    mut reader: std::io::BufReader<std::io::Stdin>,
    request_id: String,
    control: SharedControl,
) {
    // This detached, read-only thread does not use Tokio's blocking pool, so an
    // open host stdin cannot prevent process exit after a terminal event.
    std::thread::spawn(move || {
        let reason = match read_bounded_line(&mut reader, CONTROL_LINE_LIMIT) {
            Ok(None) => "cancelled",
            Ok(Some(line)) if line.last() == Some(&b'\n') => {
                match serde_json::from_slice::<CancelMessage>(&line) {
                    Ok(message) if message.operation == "cancel"
                        && message.protocol_version == 1
                        && message.request_id == request_id => "cancelled",
                    _ => "invalid_control",
                }
            }
            _ => "invalid_control",
        };
        stop_session(&control, reason);
    });
}

fn isolate_session_process() -> bool {
    let pid = unsafe { libc::getpid() };
    // Foundation.Process may already create a private process group while
    // retaining its parent's session; a group leader cannot call setsid again.
    let grouped = unsafe { libc::getpgrp() } == pid;
    if !grouped && unsafe { libc::setsid() } == -1 {
        return false;
    }
    // A disconnected or stalled stdout must not block cleanup. Every event is
    // bounded; a partial/failed write is not a successful terminal delivery.
    let flags = unsafe { libc::fcntl(libc::STDOUT_FILENO, libc::F_GETFL) };
    flags != -1 && unsafe {
        libc::fcntl(libc::STDOUT_FILENO, libc::F_SETFL, flags | libc::O_NONBLOCK)
    } != -1
}

async fn session_child(
    input: &Input,
    start: Instant,
    limit: Duration,
    control: &SharedControl,
) -> ChildResult {
    if let Some(reason) = session_reason(control, start, limit) {
        return ChildResult { value: fixed(reason), reaped: true };
    }
    let executable = match std::env::current_exe() {
        Ok(value) => value,
        Err(_) => return ChildResult { value: fixed("worker_failed"), reaped: true },
    };
    let mut process = match Command::new(executable)
        .arg("--worker")
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("LANG", "en_US.UTF-8")
        .env("TMPDIR", root().join("tmp"))
        .current_dir(root())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
    {
        Ok(value) => value,
        Err(_) => return ChildResult { value: fixed("worker_failed"), reaped: true },
    };
    let Some(mut stdin) = process.stdin.take() else {
        return ChildResult { value: fixed("worker_failed"), reaped: terminate(&mut process).await };
    };
    let data = match serde_json::to_vec(input) {
        Ok(value) => value,
        Err(_) => return ChildResult { value: fixed("worker_failed"), reaped: terminate(&mut process).await },
    };
    if !matches!(
        tokio::time::timeout(remaining(start, limit), stdin.write_all(&data)).await,
        Ok(Ok(()))
    ) {
        return ChildResult { value: fixed("worker_failed"), reaped: terminate(&mut process).await };
    }
    drop(stdin);
    let Some(mut stdout) = process.stdout.take() else {
        return ChildResult { value: fixed("worker_failed"), reaped: terminate(&mut process).await };
    };
    let mut poll = tokio::time::interval(Duration::from_millis(10));
    let mut chunk = [0_u8; 4096];
    let mut buffer = Vec::new();
    let mut total = 0_usize;
    let mut ready_seen = false;
    let mut result = None;
    let mut exit = None;
    let mut eof = false;
    loop {
        if let Some(reason) = session_reason(control, start, limit) {
            return ChildResult { value: fixed(reason), reaped: terminate(&mut process).await };
        }
        if eof && exit.is_some() {
            break;
        }
        tokio::select! {
            biased;
            _ = poll.tick() => {},
            outcome = process.wait(), if exit.is_none() => {
                exit = Some(outcome.is_ok_and(|status| status.success()));
            },
            received = stdout.read(&mut chunk), if !eof => {
                match received {
                    Ok(0) => { eof = true; },
                    Ok(count) => {
                        total = total.saturating_add(count);
                        if total > INITIAL_LINE_LIMIT {
                            return ChildResult { value: fixed("worker_failed"), reaped: terminate(&mut process).await };
                        }
                        buffer.extend_from_slice(&chunk[..count]);
                        while let Some(position) = buffer.iter().position(|byte| *byte == b'\n') {
                            let line: Vec<_> = buffer.drain(..=position).collect();
                            let value: Value = match serde_json::from_slice(&line) {
                                Ok(value) => value,
                                Err(_) => return ChildResult { value: fixed("worker_failed"), reaped: terminate(&mut process).await },
                            };
                            if value.get("event").and_then(Value::as_str) == Some("ready")
                                && input.operation == "__session_stage" && !ready_seen && result.is_none()
                            {
                                ready_seen = true;
                                if session_reason(control, start, limit).is_none() && !emit_line(&value) {
                                    stop_session(control, "output_closed");
                                }
                            } else if value.get("event").is_none()
                                && value.get("status").and_then(Value::as_str).is_some() && result.is_none()
                            {
                                result = Some(value);
                            } else {
                                return ChildResult { value: fixed("worker_failed"), reaped: terminate(&mut process).await };
                            }
                        }
                    },
                    Err(_) => return ChildResult { value: fixed("worker_failed"), reaped: terminate(&mut process).await },
                }
            },
        }
    }
    let value = if exit == Some(true) && buffer.is_empty() {
        result.unwrap_or_else(|| fixed("worker_failed"))
    } else {
        fixed("worker_failed")
    };
    ChildResult { value, reaped: true }
}

async fn session_phase(
    input: &Input,
    phase: &str,
    delay_ms: u64,
    start: Instant,
    limit: Duration,
    control: &SharedControl,
) {
    if session_reason(control, start, limit).is_some() {
        return;
    }
    let mut value = session_event(input, "phase");
    value["phase"] = json!(phase);
    if !emit_line(&value) {
        stop_session(control, "output_closed");
        return;
    }
    let until = Instant::now() + Duration::from_millis(delay_ms);
    while Instant::now() < until && session_reason(control, start, limit).is_none() {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

fn terminal_event(input: &Input, result: Value) -> Value {
    let mut terminal = session_event(input, "terminal");
    if let Some(fields) = result.as_object() {
        for (name, value) in fields {
            terminal[name] = value.clone();
        }
    }
    terminal
}

fn finish_session(input: &Input, result: Value, control: &SharedControl) {
    let mut state = control.lock().expect("session control mutex");
    state.committed = true;
    let _ = emit_line(&terminal_event(input, result));
}

async fn login_session(input: Input, control: SharedControl) {
    let start = Instant::now();
    let limit = Duration::from_millis(input.deadline_ms.unwrap_or(6000).clamp(1, 6000));
    let _lock = match lock(&input.identity_home) {
        Ok(value) => value,
        Err(()) => {
            finish_session(&input, fixed("identity_busy"), &control);
            return;
        }
    };
    let mut check = input.clone();
    check.operation = "status".into();
    let initial = session_child(&check, start, limit, &control).await;
    if !initial.reaped {
        finish_session(&input, fixed("cleanup_required"), &control);
        return;
    }
    match initial.value.get("status").and_then(Value::as_str) {
        Some("signed_out") => {},
        Some("signed_in") => {
            finish_session(&input, fixed("already_signed_in"), &control);
            return;
        },
        _ => {
            let mut result = initial.value;
            result["worker_reaped"] = json!(true);
            finish_session(&input, result, &control);
            return;
        }
    }
    if let Some(reason) = session_reason(&control, start, limit) {
        let mut result = fixed(reason);
        result["worker_reaped"] = json!(true);
        result["target_auth_present"] = json!(false);
        result["stage_cleanup_ok"] = json!(true);
        finish_session(&input, result, &control);
        return;
    }
    let stage = root().join("runtime").join(format!("stage-{}", Uuid::new_v4()));
    if std::fs::create_dir(&stage).is_err() {
        finish_session(&input, fixed("staging_failed"), &control);
        return;
    }
    let journal = input.identity_home.join(".pending-auth-cleanup.json");
    let persisted = OpenOptions::new()
        .write(true).create_new(true).mode(0o600).custom_flags(libc::O_NOFOLLOW)
        .open(&journal)
        .and_then(|mut file| {
            let value = json!({"stage_home": stage, "target_home": input.identity_home,
                "target_initially_signed_out": true, "request_id": input.request_id});
            file.write_all(value.to_string().as_bytes())?;
            file.sync_all()
        });
    if persisted.is_err() {
        let mut result = fixed("cleanup_required");
        result["stage_home"] = json!(stage);
        result["cleanup_journal"] = json!(journal);
        finish_session(&input, result, &control);
        return;
    }
    let mut login = input.clone();
    login.operation = "__session_stage".into();
    login.stage_home = Some(stage.clone());
    let result = session_child(&login, start, limit, &control).await;
    let mut reaped = result.reaped;
    let mut outcome = result.value;
    let stage_saved = reaped && outcome.get("status").and_then(Value::as_str) == Some("stage_ready");
    let mut promotion_started = false;
    if stage_saved {
        session_phase(&input, "before_promotion", input.fixture_pause_before_promotion_ms,
            start, limit, &control).await;
        if input.cancel_after_saved {
            stop_session(&control, "cancelled");
        }
        if session_reason(&control, start, limit).is_none() {
            promotion_started = true;
            let mut promotion = login.clone();
            promotion.operation = "__promote".into();
            let promoted = session_child(&promotion, start, limit, &control).await;
            reaped = promoted.reaped;
            outcome = promoted.value;
            if reaped && outcome.get("status").and_then(Value::as_str) == Some("signed_in") {
                session_phase(&input, "after_promotion", input.fixture_pause_after_promotion_ms,
                    start, limit, &control).await;
            }
        }
    }
    let target_changed = outcome.get("status").and_then(Value::as_str) == Some("target_changed");
    let signed_in = outcome.get("status").and_then(Value::as_str) == Some("signed_in");
    let mut cleaned = reaped && cleanup(&input, vec![stage.clone()]).await;
    if !reaped || !cleaned {
        outcome = fixed("cleanup_required");
    } else if let Some(reason) = session_reason(&control, start, limit) {
        outcome = fixed(reason);
    }
    let mut success_delivered = false;
    let mut terminal_delivery_attempted = false;
    if signed_in && cleaned {
        let mut state = control.lock().expect("session control mutex");
        if state.reason.is_none() && start.elapsed() < limit {
            let mut result = outcome.clone();
            result["worker_reaped"] = json!(reaped);
            result["stage_home"] = json!(stage);
            result["stage_saved_confirmed"] = json!(stage_saved);
            result["stage_cleanup_ok"] = json!(true);
            result["target_auth_present"] = json!(true);
            // The control thread shares this gate. A cancellation received before
            // successful terminal delivery wins and forces target rollback.
            terminal_delivery_attempted = true;
            if emit_line(&terminal_event(&input, result)) {
                state.committed = true;
                success_delivered = true;
            } else {
                state.reason = Some("output_closed");
            }
        } else if state.reason.is_none() {
            state.reason = Some("timed_out");
        }
    }
    if success_delivered {
        // Keep recovery metadata through terminal delivery. If the last metadata
        // removal fails, retain it and use a nonzero exit: hosts must wait for
        // process success as well as the terminal frame before reporting success.
        if std::fs::remove_file(&journal).is_err() {
            std::process::exit(3);
        }
        return;
    }
    // A cancelled promotion can have finished its blocking Keychain write. Only
    // after its process was joined is it safe to remove the exact target item.
    if reaped && promotion_started && !target_changed {
        cleaned = cleanup(&input, vec![input.identity_home.clone()]).await && cleaned;
    }
    if let Some(reason) = session_reason(&control, start, limit) {
        outcome = fixed(reason);
    }
    if cleaned {
        if journal.exists() {
            cleaned = std::fs::remove_file(&journal).is_ok();
        }
    }
    if !cleaned {
        outcome = fixed("cleanup_required");
        let homes = if promotion_started && !target_changed {
            vec![stage.clone(), input.identity_home.clone()]
        } else {
            vec![stage.clone()]
        };
        outcome["pending_cleanup_homes"] = json!(homes);
        outcome["cleanup_journal"] = json!(journal);
    }
    outcome["worker_reaped"] = json!(reaped);
    outcome["stage_home"] = json!(stage);
    outcome["stage_saved_confirmed"] = json!(stage_saved);
    outcome["stage_cleanup_ok"] = json!(cleaned);
    if cleaned && !target_changed {
        outcome["target_auth_present"] = json!(false);
    }
    if terminal_delivery_attempted {
        // A failed/partial terminal write cannot be repaired with a second
        // terminal. Cleanup is complete or its journal is retained for recovery.
        std::process::exit(4);
    }
    finish_session(&input, outcome, &control);
}

fn allowed_environment(worker: bool, input: Option<&Input>) -> bool {
    if worker && input.is_some_and(|input| input.operation == "authenticated_translate") {
        let input = input.expect("checked request");
        if std::env::var("CODEX_REFRESH_TOKEN_URL_OVERRIDE").ok().as_deref()
            != Some(format!("{}/oauth/token", input.issuer.trim_end_matches('/')).as_str())
        {
            return false;
        }
    }
    std::env::vars_os().all(|(key, value)| match key.to_str() {
        Some("PATH" | "LANG" | "TMPDIR") => true,
        Some("CODEX_REFRESH_TOKEN_URL_OVERRIDE") if worker => input.is_some_and(|input|
            input.operation == "authenticated_translate" && value.to_str() == Some(
                format!("{}/oauth/token", input.issuer.trim_end_matches('/')).as_str())),
        // CoreFoundation inserts this before main, even with a cleared launch
        // environment. Permit only its bounded numeric encoding for this UID.
        Some("__CF_USER_TEXT_ENCODING") => {
            let Some(value) = value.to_str() else {
                return false;
            };
            if value.len() > 32 {
                return false;
            }
            let fields: Option<Vec<u32>> = value
                .split(':')
                .map(|field| {
                    field.strip_prefix("0x")
                        .filter(|digits| !digits.is_empty() && digits.len() <= 8
                            && digits.bytes().all(|byte| byte.is_ascii_hexdigit()))
                        .and_then(|digits| u32::from_str_radix(digits, 16).ok())
                })
                .collect();
            matches!(fields.as_deref(), Some([uid, _, _]) if *uid == unsafe { libc::getuid() })
        }
        _ => false,
    })
}

#[tokio::main]
async fn main() {
    // Suppress Keychain authorization UI only for this fixture process.
    if unsafe { SecKeychainSetUserInteractionAllowed(0) } != 0 {
        println!("{{\"status\":\"ui_suppression_failed\"}}");
        return
    }
    let worker_mode = std::env::args().nth(1).as_deref() == Some("--worker");
    if !worker_mode && !allowed_environment(false, None) {
        println!("{}", fixed("environment_rejected"));
        return
    }
    let mut reader = std::io::BufReader::new(std::io::stdin());
    let mut bytes = match read_bounded_line(&mut reader, INITIAL_LINE_LIMIT) {
        Ok(Some(bytes)) => bytes,
        _ => {
            println!("{}", fixed("invalid_input"));
            return;
        }
    };
    if !worker_mode {
        if let Ok(input) = serde_json::from_slice::<Input>(&bytes) {
            if input.operation == "login_session" {
                if bytes.last() != Some(&b'\n') || !valid(&input, false) {
                    println!("{}", fixed("invalid_input"));
                    return;
                }
                if !isolate_session_process() {
                    let _ = emit_line(&terminal_event(&input, fixed("process_isolation_failed")));
                    return;
                }
                let control = Arc::new(Mutex::new(SessionControl::default()));
                start_control_reader(reader, input.request_id.clone().expect("validated request ID"),
                    Arc::clone(&control));
                login_session(input, control).await;
                return;
            }
        }
    }
    // Legacy one-object operations still accept pretty-printed JSON through EOF.
    let mut remaining_bytes = Vec::new();
    let _ = reader.take((INITIAL_LINE_LIMIT + 1 - bytes.len()) as u64)
        .read_to_end(&mut remaining_bytes);
    bytes.extend_from_slice(&remaining_bytes);
    let result = if bytes.len() > INITIAL_LINE_LIMIT {
        fixed("invalid_input")
    } else {
        match serde_json::from_slice::<Input>(&bytes) {
            Ok(input) if valid(&input, worker_mode) => if worker_mode {
                if allowed_environment(true, Some(&input)) { worker(input).await }
                else { fixed("environment_rejected") }
            } else {
                supervise(input).await
            },
            _ => fixed("invalid_input"),
        }
    };
    println!("{}", result);
}

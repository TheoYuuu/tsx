//! Bridges an explicitly owned official AuthManager to one account-bound request.
//!
//! This module performs no model request and never returns tokens or upstream
//! error text. The caller owns deadlines, fixture registration, environment
//! validation, request counting, and exact-identity cleanup.
//! The supervisor must hold the account-storage generation lease for the whole
//! operation. A prepared provider is valid for this request only; never cache it
//! across operations or release the lease while a refresh remains in progress.
use codex_api::{AuthError, AuthHeadersFuture, AuthProvider, SharedAuthProvider};
use codex_login::auth::RefreshTokenFailedReason;
use codex_login::{
    AuthCredentialsStoreMode, AuthKeyringBackendKind, AuthManager, CodexAuth,
    RefreshTokenError,
};
use serde::Serialize;
use http::{HeaderMap, header::AUTHORIZATION};
use std::fmt;
#[cfg(feature = "qa-fixtures")]
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Default)]
pub struct AccountRequestOptions {
    /// The caller must already have registered this separate random fixture home.
    /// For defense in depth this module only accepts a canonical sibling of the
    /// manager's explicit target home. This is never a production account switch.
    #[cfg(feature = "qa-fixtures")]
    pub fixture_replacement_home: Option<PathBuf>,
    pub explicit_refresh: bool,
}

#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
pub struct AccountRequestChecks {
    pub replacement_applied: bool,
    pub explicit_refresh_requested: bool,
    pub proactive_refresh_needed: bool,
    /// Counts calls into refresh_token, not HTTP requests. The fake issuer owns
    /// independent wire counts; a guarded reload can avoid a refresh HTTP request.
    pub explicit_refresh_calls: u8,
    pub explicit_refresh_completed: bool,
    pub anchor_matches_after_preparation: bool,
}

pub struct PreparedAccountRequest {
    /// Constructed before any replacement or refresh, retaining the starting
    /// account anchor. Pass this to the actual ResponsesClient without swapping
    /// it for a new adapter after preparing the request.
    pub provider: SharedAuthProvider,
    pub checks: AccountRequestChecks,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AccountRequestError {
    code: &'static str,
    pub checks: AccountRequestChecks,
}

impl AccountRequestError {
    pub fn status(&self) -> &'static str {
        self.code
    }
}

impl fmt::Display for AccountRequestError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.code)
    }
}

impl std::error::Error for AccountRequestError {}

fn failure(code: &'static str, checks: &AccountRequestChecks) -> AccountRequestError {
    AccountRequestError { code, checks: checks.clone() }
}

fn same_anchor(current: &CodexAuth, expected: &CodexAuth) -> bool {
    // Mirror only the official adapter's identity checks for a safe boolean.
    // Enforcement remains in the original adapter when Responses applies auth.
    current.uses_codex_backend()
        && current.get_account_id() == expected.get_account_id()
        && current.get_chatgpt_user_id() == expected.get_chatgpt_user_id()
        && current.is_workspace_account() == expected.is_workspace_account()
}

fn account_claims_are_consistent(tokens: &codex_login::token_data::TokenData) -> bool {
    // Official refresh persistence replaces id_token but retains account_id.
    // Reject contradictory identities before an adapter can send the new bearer
    // with the old account header. Optional absent claims remain optional.
    // These are officially parsed claims, not a local JWT signature verification.
    match (
        tokens.account_id.as_deref(),
        tokens.id_token.chatgpt_account_id.as_deref(),
    ) {
        (Some(stored), Some(claimed)) => stored == claimed,
        _ => true,
    }
}

fn ensure_identity_consistent(
    auth: &CodexAuth,
    checks: &AccountRequestChecks,
) -> Result<(), AccountRequestError> {
    let tokens = auth
        .get_token_data()
        .map_err(|_| failure("identity_inconsistent", checks))?;
    if !account_claims_are_consistent(&tokens) {
        return Err(failure("identity_inconsistent", checks));
    }
    Ok(())
}

#[cfg(feature = "qa-fixtures")]
fn canonical_sibling(target: &Path, replacement: &Path) -> bool {
    target != replacement
        && target.is_absolute()
        && replacement.is_absolute()
        && target.parent() == replacement.parent()
        && target.canonicalize().is_ok_and(|path| path == target && path.is_dir())
        && replacement.canonicalize().is_ok_and(|path| path == replacement && path.is_dir())
}

fn refresh_failure(error: RefreshTokenError, checks: &AccountRequestChecks) -> AccountRequestError {
    let code = match error {
        RefreshTokenError::Permanent(error) => match error.reason {
            RefreshTokenFailedReason::Expired => "refresh_expired",
            RefreshTokenFailedReason::Exhausted => "refresh_reused",
            RefreshTokenFailedReason::Revoked => "refresh_revoked",
            RefreshTokenFailedReason::Other => "refresh_rejected",
        },
        RefreshTokenError::Transient(_) => "refresh_unavailable",
        RefreshTokenError::Policy(_) => "refresh_policy_denied",
    };
    failure(code, checks)
}

#[derive(Clone, Copy)]
struct RefreshDeadline {
    seconds: i64,
    inclusive: bool,
}

impl RefreshDeadline {
    fn is_due(self, now: i64) -> bool {
        if self.inclusive { now >= self.seconds } else { now > self.seconds }
    }
}

fn now_seconds() -> Result<i64, ()> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|_| ())?;
    i64::try_from(now.as_secs()).map_err(|_| ())
}

fn refresh_deadline(access_token: &str, last_refresh: Option<i64>) -> Result<RefreshDeadline, ()> {
    if access_token.is_empty() || last_refresh.is_none() {
        return Err(());
    }
    // These pinned upstream thresholds are private (manager.rs 3004): exp at
    // most five minutes away, otherwise last_refresh strictly older than eight
    // days. Use the official JWT parser; do not invent a second claims decoder.
    if let Ok(Some(expiration)) = codex_login::token_data::parse_jwt_expiration(access_token) {
        Ok(RefreshDeadline { seconds: expiration.timestamp().saturating_sub(300), inclusive: true })
    } else {
        Ok(RefreshDeadline {
            seconds: last_refresh.ok_or(())?.saturating_add(8 * 24 * 60 * 60),
            inclusive: false,
        })
    }
}

fn stored_refresh_deadline(
    manager: &AuthManager,
    auth: &CodexAuth,
    checks: &AccountRequestChecks,
) -> Result<RefreshDeadline, AccountRequestError> {
    let tokens = auth.get_token_data().map_err(|_| failure("identity_inconsistent", checks))?;
    let stored = codex_login::load_auth_dot_json(
        &manager.runtime_config().codex_home,
        AuthCredentialsStoreMode::Keyring, AuthKeyringBackendKind::Direct,
    )
    .map_err(|_| failure("storage_unavailable", checks))?
    .ok_or_else(|| failure("signed_out", checks))?;
    // last_refresh is not publicly exposed on CodexAuth. Never combine a new
    // store timestamp with different cached tokens, even for the same owner.
    if stored.tokens.as_ref() != Some(&tokens) {
        return Err(failure("identity_inconsistent", checks));
    }
    refresh_deadline(&tokens.access_token, stored.last_refresh.map(|date| date.timestamp()))
        .map_err(|_| failure("refresh_incomplete", checks))
}

struct PreparedAuthProvider {
    official: SharedAuthProvider,
    freshness: Option<RefreshDeadline>,
}

impl PreparedAuthProvider {
    fn checked_headers(&self) -> Result<HeaderMap, AuthError> {
        let unavailable = || AuthError::Transient("prepared authentication is unavailable".into());
        if let Some(deadline) = self.freshness {
            // Crossing the boundary after preparation fails this request; it
            // must not silently trigger a second refresh while applying auth.
            if deadline.is_due(now_seconds().map_err(|_| unavailable())?) {
                return Err(unavailable());
            }
        }
        // Keep the original official identity anchor. Its synchronous path
        // consults auth_cached; its async path would invoke auth(), which may
        // fall back to stale credentials after a failed proactive refresh.
        let headers = self.official.to_auth_headers();
        if !headers.contains_key(AUTHORIZATION) {
            return Err(unavailable());
        }
        Ok(headers)
    }
}

impl AuthProvider for PreparedAuthProvider {
    fn add_auth_headers(&self, headers: &mut HeaderMap) {
        if let Ok(prepared) = self.checked_headers() {
            headers.extend(prepared);
        }
    }

    fn resolve_auth_headers(&self) -> AuthHeadersFuture<'_> {
        Box::pin(async move { self.checked_headers() })
    }
}

pub async fn prepare_account_request(
    manager: Arc<AuthManager>,
    expected_auth: CodexAuth,
    options: AccountRequestOptions,
) -> Result<PreparedAccountRequest, AccountRequestError> {
    let mut checks = AccountRequestChecks {
        explicit_refresh_requested: options.explicit_refresh,
        ..AccountRequestChecks::default()
    };
    if !matches!(expected_auth, CodexAuth::Chatgpt(_)) {
        return Err(failure("unexpected_auth_method", &checks));
    }
    ensure_identity_consistent(&expected_auth, &checks)?;
    let provider = codex_model_provider::auth_provider_from_auth_manager(
        Arc::clone(&manager), &expected_auth,
    );
    #[cfg(feature = "qa-fixtures")]
    if let Some(replacement) = options.fixture_replacement_home {
        let target = manager.runtime_config().codex_home;
        if !canonical_sibling(&target, &replacement) {
            return Err(failure("invalid_fixture_home", &checks));
        }
        let replacement_auth = codex_login::load_auth_dot_json(
            &replacement, AuthCredentialsStoreMode::Keyring, AuthKeyringBackendKind::Direct,
        )
        .map_err(|_| failure("storage_unavailable", &checks))?
        .ok_or_else(|| failure("replacement_signed_out", &checks))?;
        codex_login::save_auth(
            &target, &replacement_auth,
            AuthCredentialsStoreMode::Keyring, AuthKeyringBackendKind::Direct,
        )
        .map_err(|_| failure("storage_unavailable", &checks))?;
        checks.replacement_applied = true;
        manager.reload().await;
    }
    let current = manager.auth_cached().ok_or_else(|| failure("signed_out", &checks))?;
    ensure_identity_consistent(&current, &checks)?;
    checks.anchor_matches_after_preparation = same_anchor(&current, &expected_auth);
    let mut freshness = None;
    // Never refresh a newly substituted owner on behalf of the original request.
    // The retained official adapter (or account-bound network permit) rejects it.
    if checks.anchor_matches_after_preparation {
        let deadline = stored_refresh_deadline(&manager, &current, &checks)?;
        checks.proactive_refresh_needed = deadline.is_due(
            now_seconds().map_err(|_| failure("refresh_incomplete", &checks))?,
        );
        if options.explicit_refresh || checks.proactive_refresh_needed {
            // This is the only refresh call in the request state machine. The
            // legacy counter names count explicit calls into the official API,
            // including a call needed by proactive expiry checking.
            checks.explicit_refresh_calls = 1;
            manager.refresh_token().await.map_err(|error| refresh_failure(error, &checks))?;
            checks.explicit_refresh_completed = true;
            let current = manager.auth_cached().ok_or_else(|| failure("signed_out", &checks))?;
            ensure_identity_consistent(&current, &checks)?;
            checks.anchor_matches_after_preparation = same_anchor(&current, &expected_auth);
            if checks.anchor_matches_after_preparation {
                let deadline = stored_refresh_deadline(&manager, &current, &checks)?;
                if deadline.is_due(now_seconds().map_err(|_| failure("refresh_incomplete", &checks))?) {
                    return Err(failure("refresh_incomplete", &checks));
                }
                freshness = Some(deadline);
            }
        } else {
            freshness = Some(deadline);
        }
    }
    let provider = Arc::new(PreparedAuthProvider { official: provider, freshness });
    Ok(PreparedAccountRequest { provider, checks })
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_http_client::NetworkPolicyDenied;
    use codex_login::auth::RefreshTokenFailedError;
    use base64::Engine;

    fn jwt(payload: serde_json::Value) -> String {
        format!("e30.{}.fixture", base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(serde_json::to_vec(&payload).unwrap()))
    }

    #[test]
    fn jwt_refresh_window_includes_exact_five_minute_boundary() {
        let now = 2_000_000_000;
        for (expiry, due) in [(now - 1, true), (now, true), (now + 299, true),
                              (now + 300, true), (now + 301, false)] {
            let deadline = refresh_deadline(&jwt(serde_json::json!({"exp": expiry})), Some(now)).unwrap();
            assert_eq!(deadline.is_due(now), due);
        }
    }

    #[test]
    fn opaque_and_missing_or_invalid_exp_use_strict_eight_day_boundary() {
        let refreshed = 2_000_000_000;
        for token in ["opaque-fixture-token".into(), jwt(serde_json::json!({})),
                      jwt(serde_json::json!({"exp": "invalid"}))] {
            let deadline = refresh_deadline(&token, Some(refreshed)).unwrap();
            assert!(!deadline.is_due(refreshed + 8 * 86_400 - 1));
            assert!(!deadline.is_due(refreshed + 8 * 86_400));
            assert!(deadline.is_due(refreshed + 8 * 86_400 + 1));
        }
    }

    #[test]
    fn jwt_expiry_takes_precedence_over_old_fallback_timestamp() {
        let now = 2_000_000_000;
        assert!(!refresh_deadline(&jwt(serde_json::json!({"exp": now + 3600})), Some(0))
            .unwrap().is_due(now));
    }

    #[test]
    fn missing_material_is_not_fresh() {
        assert!(refresh_deadline("", Some(0)).is_err());
        assert!(refresh_deadline("opaque", None).is_err());
        assert!(refresh_deadline(&jwt(serde_json::json!({"exp": 2_000_000_000})), None).is_err());
    }

    struct SyncOnlyAuth { empty: bool }

    impl AuthProvider for SyncOnlyAuth {
        fn add_auth_headers(&self, headers: &mut HeaderMap) {
            if !self.empty {
                headers.insert(AUTHORIZATION, http::HeaderValue::from_static("Bearer constructed-token"));
            }
        }

        fn resolve_auth_headers(&self) -> AuthHeadersFuture<'_> {
            panic!("the prepared provider must never invoke implicit refresh");
        }
    }

    #[tokio::test]
    async fn prepared_provider_uses_sync_auth_and_rejects_empty_or_stale_headers() {
        let provider = PreparedAuthProvider {
            official: Arc::new(SyncOnlyAuth { empty: false }),
            freshness: Some(RefreshDeadline { seconds: i64::MAX, inclusive: true }),
        };
        assert!(provider.resolve_auth_headers().await.unwrap().contains_key(AUTHORIZATION));
        let empty = PreparedAuthProvider { official: Arc::new(SyncOnlyAuth { empty: true }), freshness: None };
        assert!(empty.resolve_auth_headers().await.is_err());
        let stale = PreparedAuthProvider {
            official: Arc::new(SyncOnlyAuth { empty: false }),
            freshness: Some(RefreshDeadline { seconds: 0, inclusive: true }),
        };
        assert!(stale.resolve_auth_headers().await.is_err());
        assert!(stale.to_auth_headers().is_empty());
    }

    #[test]
    fn account_only_claim_change_is_rejected_without_a_user_change() {
        let mut tokens = codex_login::token_data::TokenData {
            account_id: Some("fixture-account-original".into()),
            id_token: codex_login::token_data::IdTokenInfo {
                chatgpt_account_id: Some("fixture-account-original".into()),
                chatgpt_user_id: Some("fixture-same-user".into()),
                ..Default::default()
            },
            ..Default::default()
        };
        assert!(account_claims_are_consistent(&tokens));
        tokens.id_token.chatgpt_account_id = Some("fixture-account-replaced".into());
        assert!(!account_claims_are_consistent(&tokens));
        assert_eq!(tokens.id_token.chatgpt_user_id.as_deref(), Some("fixture-same-user"));
    }

    #[test]
    fn absent_optional_account_claims_do_not_invent_a_contradiction() {
        let mut tokens = codex_login::token_data::TokenData::default();
        assert!(account_claims_are_consistent(&tokens));
        tokens.account_id = Some("fixture-account".into());
        assert!(account_claims_are_consistent(&tokens));
        tokens.account_id = None;
        tokens.id_token.chatgpt_account_id = Some("fixture-account".into());
        assert!(account_claims_are_consistent(&tokens));
    }

    #[test]
    fn permanent_refresh_errors_keep_only_fixed_classification() {
        let cases = [
            (RefreshTokenFailedReason::Expired, "refresh_expired"),
            (RefreshTokenFailedReason::Exhausted, "refresh_reused"),
            (RefreshTokenFailedReason::Revoked, "refresh_revoked"),
            (RefreshTokenFailedReason::Other, "refresh_rejected"),
        ];
        for (reason, expected) in cases {
            let error = refresh_failure(
                RefreshTokenError::Permanent(RefreshTokenFailedError::new(
                    reason, "private-fixture-token-and-server-error",
                )),
                &AccountRequestChecks::default(),
            );
            assert_eq!(error.status(), expected);
            assert_eq!(error.to_string(), expected);
            assert!(!format!("{error:?}").contains("private-fixture"));
        }
    }

    #[test]
    fn transient_and_policy_errors_do_not_expose_inner_details() {
        let transient = refresh_failure(
            RefreshTokenError::Transient(std::io::Error::other("private-fixture-response")),
            &AccountRequestChecks::default(),
        );
        assert_eq!(transient.status(), "refresh_unavailable");
        assert!(!format!("{transient:?}").contains("private-fixture"));
        let policy = refresh_failure(
            RefreshTokenError::Policy(NetworkPolicyDenied::Destination),
            &AccountRequestChecks::default(),
        );
        assert_eq!(policy.status(), "refresh_policy_denied");
    }
}

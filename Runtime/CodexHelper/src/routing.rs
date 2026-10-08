//! Workspace discovery and bounded metadata, using public types from Codex
//! 36650394c5b38c2990ccf2a3457165ca3e9d9726. This module never refreshes auth.
//! A resolver belongs to one immutable configuration/account operation; replace
//! the operation on configuration change instead of reusing stale discovery.

use crate::network::{self, NetworkError};
use codex_api::{ModelsClient, Provider, RetryConfig, SharedAuthProvider};
use codex_backend_client::{AccountEntry, AccountsCheckResponse, ConfigBundleResponse};
use codex_config::{CloudConfigBundle, CloudConfigFragment, CloudRequirementsFragment};
use codex_http_client::HttpClientFactory;
use codex_login::{AuthManager, CodexAuth, WorkspaceRouting, WorkspaceRoutingRequest, WorkspaceRoutingResolver};
use codex_model_provider::{
    ModelProvider, ModelProviderFuture, ProviderAccountError, ProviderAccountResult,
    ResolvedResponsesProvider, WorkspaceRoutingContext,
};
use codex_model_provider_info::ModelProviderInfo;
use codex_models_manager::manager::SharedModelsManager;
use codex_protocol::openai_models::ModelsResponse;
use codex_protocol::account::PlanType;
use std::{fmt, future::Future, io, path::PathBuf, pin::Pin, sync::Arc, time::Duration};
use url::Url;

const MAX_METADATA_BYTES: usize = 1024 * 1024;
const PINNED_CLIENT_VERSION: &str = "0.157.1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RoutingError(&'static str);

impl RoutingError {
    pub fn status(self) -> &'static str { self.0 }
}

impl fmt::Display for RoutingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for RoutingError {}

impl From<NetworkError> for RoutingError {
    fn from(error: NetworkError) -> Self { Self(error.status()) }
}

fn secure_url(url: &Url) -> bool {
    url.scheme() == "https" && url.host_str().is_some() && url.username().is_empty()
        && url.password().is_none() && url.query().is_none() && url.fragment().is_none()
}

fn normalized_bootstrap(bootstrap: &Url) -> Result<Url, RoutingError> {
    if !secure_url(bootstrap) { return Err(RoutingError("invalid_bootstrap_url")); }
    let mut base = bootstrap.as_str().trim_end_matches('/').to_string();
    // Follow BackendClient's path conventions, with exact hostname matching.
    if matches!(bootstrap.host_str(), Some("chatgpt.com" | "chat.openai.com"))
        && !bootstrap.path().contains("/backend-api")
    {
        base.push_str("/backend-api");
    }
    Url::parse(&base).map_err(|_| RoutingError("invalid_bootstrap_url"))
}

fn metadata_url(bootstrap: &Url, resource: &str) -> Result<Url, RoutingError> {
    let base = normalized_bootstrap(bootstrap)?;
    let prefix = if base.path().contains("/backend-api") { "wham" } else { "api/codex" };
    Url::parse(&format!("{}/{prefix}/{resource}", base.as_str().trim_end_matches('/')))
        .map_err(|_| RoutingError("invalid_bootstrap_url"))
}

fn selected_entry(response: AccountsCheckResponse, account_id: &str) -> Result<AccountEntry, RoutingError> {
    let mut matches = response.accounts.into_iter().filter(|entry| entry.id == account_id);
    let entry = matches.next().ok_or(RoutingError("workspace_missing"))?;
    if matches.next().is_some() { return Err(RoutingError("workspace_duplicated")); }
    Ok(entry)
}

fn routing_from_entry(
    entry: AccountEntry,
    required_backend: Option<&Url>,
    bootstrap: &Url,
) -> Result<WorkspaceRouting, RoutingError> {
    // Mirrors the official app-server resolver's selection contract. Do not
    // substitute a default workspace or treat missing discovery as independent.
    let route = entry.account_routing_override
        .filter(|value| matches!(value.as_str(), "NO_CONSTRAINT" | "us" | "us_cr"))
        .ok_or(RoutingError("invalid_workspace_routing"))?;
    let backend = entry.workspace_backend_origin.ok_or(RoutingError("workspace_backend_missing"))?;
    let discovered = if backend == "NO_CONSTRAINT" { None } else {
        let parsed = Url::parse(&backend).map_err(|_| RoutingError("invalid_workspace_backend"))?;
        if !secure_url(&parsed) || parsed.path() != "/" || backend.trim() != backend {
            return Err(RoutingError("invalid_workspace_backend"));
        }
        Some(parsed)
    };
    if required_backend.is_some_and(|url| !secure_url(url)) {
        return Err(RoutingError("invalid_required_backend"));
    }
    let origin = match (required_backend, discovered.as_ref()) {
        (Some(required), Some(discovered)) if required.origin() != discovered.origin() => {
            return Err(RoutingError("workspace_backend_conflict"));
        }
        (Some(required), _) => required.origin(),
        (_, Some(discovered)) => discovered.origin(),
        (None, None) => bootstrap.origin(),
    };
    Ok(WorkspaceRouting { chatgpt_account_id: entry.id,
        backend_origin: origin.ascii_serialization(), account_routing_override: route })
}

fn is_workspace_bound(
    request: &WorkspaceRoutingRequest,
    bootstrap: &Url,
    routing: &WorkspaceRouting,
) -> Result<bool, RoutingError> {
    let provider = Url::parse(&request.provider_base_url).map_err(|_| RoutingError("invalid_provider_url"))?;
    let session = Url::parse(&request.chatgpt_base_url).map_err(|_| RoutingError("invalid_session_bootstrap"))?;
    if !secure_url(&session) { return Err(RoutingError("invalid_session_bootstrap")); }
    let selected_backend = provider.origin().ascii_serialization() == routing.backend_origin;
    let bound = request.previously_routed
        || request.provider_base_url == codex_model_provider::CHATGPT_CODEX_BASE_URL
        || provider.origin() == session.origin()
        || (session.origin() == bootstrap.origin() && selected_backend);
    if bound && session.origin() != bootstrap.origin() {
        return Err(RoutingError("workspace_bootstrap_changed"));
    }
    Ok(bound)
}

/// This owner is installed exactly once on a fresh manager. Holding the returned
/// Arc keeps the official manager's weak resolver alive through the request.
pub struct WorkspaceResolver {
    manager: Arc<AuthManager>,
    bootstrap: Url,
    required_backend: Option<Url>,
    auth: SharedAuthProvider,
    factory: HttpClientFactory,
    account_id: String,
    owner_generation: u64,
    deadline: Duration,
}

impl WorkspaceResolver {
    pub fn install(
        manager: Arc<AuthManager>,
        bootstrap: Url,
        required_backend: Option<Url>,
        auth: SharedAuthProvider,
        deadline: Duration,
    ) -> Result<Arc<Self>, RoutingError> {
        let bootstrap = normalized_bootstrap(&bootstrap)?;
        if required_backend.as_ref().is_some_and(|url| !secure_url(url)) {
            return Err(RoutingError("invalid_required_backend"));
        }
        let current = manager.auth_cached().ok_or(RoutingError("signed_out"))?;
        if !current.is_chatgpt_auth() { return Err(RoutingError("unexpected_auth_method")); }
        let account_id = current.get_account_id().filter(|id| !id.is_empty() && id.trim() == id)
            .ok_or(RoutingError("workspace_identity_missing"))?;
        let owner_generation = manager.auth_change_state_receiver().borrow().owner_generation;
        let factory = manager.http_client_factory();
        let resolver = Arc::new(Self {
            manager: Arc::clone(&manager), bootstrap, required_backend, auth,
            factory, account_id, owner_generation, deadline,
        });
        let erased: Arc<dyn WorkspaceRoutingResolver> = resolver.clone();
        manager.set_workspace_routing_resolver(Arc::downgrade(&erased));
        Ok(resolver)
    }

    fn check_owner(&self) -> Result<(), RoutingError> {
        if self.manager.auth_change_state_receiver().borrow().owner_generation != self.owner_generation
            || self.manager.auth_cached().and_then(|auth| auth.get_account_id()).as_deref()
                != Some(self.account_id.as_str())
        {
            return Err(RoutingError("workspace_account_changed"));
        }
        Ok(())
    }

    async fn discover(&self, request: WorkspaceRoutingRequest) -> Result<Option<WorkspaceRouting>, RoutingError> {
        self.check_owner()?;
        // The helper owns an immutable policy/configuration snapshot per request.
        // It cannot silently ignore app-server retained-session configuration.
        if request.session.is_some() { return Err(RoutingError("unsupported_routing_session")); }
        let url = metadata_url(&self.bootstrap, "accounts/check")?;
        let response = network::get_json(self.factory.clone(), url, Arc::clone(&self.auth),
            self.deadline, MAX_METADATA_BYTES).await?;
        self.check_owner()?;
        let routing = routing_from_entry(selected_entry(response, &self.account_id)?,
            self.required_backend.as_ref(), &self.bootstrap)?;
        if is_workspace_bound(&request, &self.bootstrap, &routing)? { Ok(Some(routing)) }
        else { Ok(None) }
    }
}

impl WorkspaceRoutingResolver for WorkspaceResolver {
    fn resolve(&self, request: WorkspaceRoutingRequest)
        -> Pin<Box<dyn Future<Output = io::Result<Option<WorkspaceRouting>>> + Send + '_>>
    {
        Box::pin(async move {
            let mut changes = self.manager.auth_change_state_receiver();
            tokio::select! {
                biased;
                _ = changes.wait_for(|state| state.owner_generation != self.owner_generation) => {
                    Err(io::Error::other("workspace_account_changed"))
                }
                result = self.discover(request) => result.map_err(io::Error::other),
            }
        })
    }
}

/// A routing-only adapter: the default official Responses method calls auth()
/// twice, so delegating to ConfiguredModelProvider would implicitly refresh.
/// This private implementation always returns the prepared cached snapshot.
struct RequestModelProvider {
    info: ModelProviderInfo,
    manager: Arc<AuthManager>,
    prepared: SharedAuthProvider,
    snapshot: CodexAuth,
    tokens: codex_login::token_data::TokenData,
    owner_generation: u64,
}

impl fmt::Debug for RequestModelProvider {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("RequestModelProvider").finish_non_exhaustive()
    }
}

impl RequestModelProvider {
    fn new(manager: Arc<AuthManager>, prepared: SharedAuthProvider) -> Result<Self, RoutingError> {
        let snapshot = manager.auth_cached().ok_or(RoutingError("signed_out"))?;
        if !snapshot.is_chatgpt_auth() {
            return Err(RoutingError("unexpected_auth_method"));
        }
        let tokens = snapshot.get_token_data().map_err(|_| RoutingError("authentication_unavailable"))?;
        if tokens.access_token.is_empty() || tokens.account_id.as_ref().is_none_or(String::is_empty) {
            return Err(RoutingError("workspace_identity_missing"));
        }
        let owner_generation = manager.auth_change_state_receiver().borrow().owner_generation;
        Ok(Self {
            info: ModelProviderInfo::create_openai_provider(None),
            manager, prepared, snapshot, tokens, owner_generation,
        })
    }

    async fn validate(&self) -> Result<(), RoutingError> {
        let headers = self.prepared.resolve_auth_headers().await
            .map_err(|_| RoutingError("authentication_unavailable"))?;
        // The prepared adapter supplies freshness/identity checks. Also bind it
        // to this exact cached snapshot; never mix another adapter's bearer or
        // a concurrent same-account refresh with this routing operation.
        let bearer = format!("Bearer {}", self.tokens.access_token);
        if headers.get(http::header::AUTHORIZATION).map(http::HeaderValue::as_bytes)
                != Some(bearer.as_bytes())
            || headers.get("ChatGPT-Account-ID").map(http::HeaderValue::as_bytes)
                != self.tokens.account_id.as_ref().map(|value| value.as_bytes())
        {
            return Err(RoutingError("authentication_unavailable"));
        }
        if self.manager.auth_change_state_receiver().borrow().owner_generation != self.owner_generation
            || self.manager.auth_cached().and_then(|auth| auth.get_token_data().ok()).as_ref()
                != Some(&self.tokens)
        {
            return Err(RoutingError("workspace_account_changed"));
        }
        Ok(())
    }
}

impl ModelProvider for RequestModelProvider {
    fn info(&self) -> &ModelProviderInfo { &self.info }

    fn auth_manager(&self) -> Option<Arc<AuthManager>> { Some(Arc::clone(&self.manager)) }

    fn auth(&self) -> ModelProviderFuture<'_, Option<CodexAuth>> {
        // Never call manager.auth() here. A missing/changed/expired identity is
        // rejected around routing, not represented as None (which skips it).
        Box::pin(async { Some(self.snapshot.clone()) })
    }

    fn account_state(&self) -> ProviderAccountResult {
        Err(ProviderAccountError::MissingChatgptAccountDetails)
    }

    fn models_manager(&self, _: PathBuf, _: Option<ModelsResponse>) -> SharedModelsManager {
        unreachable!("private routing-only provider cannot create a model manager")
    }
}

async fn resolve_checked_provider(
    provider: &RequestModelProvider,
    bootstrap: &Url,
) -> Result<ResolvedResponsesProvider, RoutingError> {
    provider.validate().await?;
    let context = WorkspaceRoutingContext::new(bootstrap.to_string());
    let mut resolved = provider.responses_api_provider(&context).await
        .map_err(|_| RoutingError("workspace_routing_failed"))?;
    provider.validate().await?;
    resolved.provider.retry = RetryConfig { max_attempts: 0, base_delay: Duration::ZERO,
        retry_429: false, retry_5xx: false, retry_transport: false };
    resolved.redirect_policy = codex_login::default_client::ClientRedirectPolicy::Reject;
    Ok(resolved)
}

/// Only an installed strong routing owner can enter this operation; arbitrary
/// ModelProvider implementations cannot introduce auth refresh or skip discovery.
/// The official default method still applies the discovered origin and header.
pub async fn resolve_responses_provider(
    resolver: &Arc<WorkspaceResolver>,
) -> Result<ResolvedResponsesProvider, RoutingError> {
    resolver.check_owner()?;
    let provider = RequestModelProvider::new(Arc::clone(&resolver.manager), Arc::clone(&resolver.auth))?;
    let resolved = resolve_checked_provider(&provider, &resolver.bootstrap).await?;
    resolver.check_owner()?;
    Ok(resolved)
}

/// Map only the official enterprise-managed buckets, preserving backend order.
/// Validation and merge precedence remain the official config loader's job.
pub fn bundle_from_response(response: ConfigBundleResponse) -> CloudConfigBundle {
    let mut bundle = CloudConfigBundle::default();
    if let Some(config) = response.config_toml.flatten() {
        for fragment in config.enterprise_managed.flatten().unwrap_or_default() {
            bundle.config_toml.enterprise_managed.push(CloudConfigFragment {
                id: fragment.id, name: fragment.name, contents: fragment.contents,
            });
        }
    }
    if let Some(requirements) = response.requirements_toml.flatten() {
        for fragment in requirements.enterprise_managed.flatten().unwrap_or_default() {
            bundle.requirements_toml.enterprise_managed.push(CloudRequirementsFragment {
                id: fragment.id, name: fragment.name, contents: fragment.contents,
            });
        }
    }
    bundle
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloudBundleEligibility {
    Required,
    NotRequired,
}

fn plan_bundle_eligibility(plan: Option<PlanType>) -> Result<CloudBundleEligibility, RoutingError> {
    let plan = plan.filter(|plan| *plan != PlanType::Unknown)
        .ok_or(RoutingError("account_plan_unavailable"))?;
    // Exact pinned cloud-config/service.rs eligibility. Team-like plans are
    // distinct from business-like plans; do not broaden this to workspace=true.
    if plan.is_business_like() || plan.is_education_like() || plan == PlanType::Enterprise {
        Ok(CloudBundleEligibility::Required)
    } else {
        Ok(CloudBundleEligibility::NotRequired)
    }
}

pub fn cloud_bundle_eligibility(auth: &CodexAuth) -> Result<CloudBundleEligibility, RoutingError> {
    if !auth.is_chatgpt_auth() { return Err(RoutingError("unexpected_auth_method")); }
    plan_bundle_eligibility(auth.account_plan_type())
}

/// Call only after eligibility is Required. A successful empty bundle remains a
/// successful CloudConfigBundle; any fetch/parse failure stays an Err, never None.
pub async fn fetch_cloud_bundle(
    factory: HttpClientFactory,
    bootstrap: &Url,
    auth: SharedAuthProvider,
    deadline: Duration,
) -> Result<CloudConfigBundle, RoutingError> {
    let response = network::get_json(factory, metadata_url(bootstrap, "config/bundle")?,
        auth, deadline, MAX_METADATA_BYTES).await?;
    Ok(bundle_from_response(response))
}

/// Supply the official un-routed bootstrap provider, as models_endpoint.rs does.
/// No bundled fallback or disk cache is substituted for a failed account catalog.
pub async fn fetch_models(
    factory: HttpClientFactory,
    bootstrap_provider: &Provider,
    auth: SharedAuthProvider,
    deadline: Duration,
) -> Result<ModelsResponse, RoutingError> {
    let base = Url::parse(&bootstrap_provider.base_url).map_err(|_| RoutingError("invalid_provider_url"))?;
    if !secure_url(&base) { return Err(RoutingError("invalid_provider_url")); }
    let url = ModelsClient::<network::StrictTransport>::request_url(bootstrap_provider, PINNED_CLIENT_VERSION);
    let url = Url::parse(&url).map_err(|_| RoutingError("invalid_provider_url"))?;
    network::get_json_with_headers(factory, url, auth, bootstrap_provider.headers.clone(),
        deadline, MAX_METADATA_BYTES).await.map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_api::{AuthHeadersFuture, AuthProvider};
    use codex_login::{ExternalAuth, ExternalAuthFuture, ExternalAuthRefreshContext};
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct SpyExternal {
        auth: CodexAuth,
        calls: Arc<AtomicUsize>,
    }

    impl ExternalAuth for SpyExternal {
        fn resolve(&self) -> ExternalAuthFuture<'_, CodexAuth> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Box::pin(async { Ok(self.auth.clone()) })
        }

        fn refresh(&self, _: ExternalAuthRefreshContext) -> ExternalAuthFuture<'_, CodexAuth> {
            panic!("routing must never request an auth refresh")
        }
    }

    struct PreparedSpy {
        headers: http::HeaderMap,
        calls: AtomicUsize,
        allowed_calls: usize,
    }

    impl AuthProvider for PreparedSpy {
        fn add_auth_headers(&self, headers: &mut http::HeaderMap) {
            headers.extend(self.headers.clone());
        }

        fn resolve_auth_headers(&self) -> AuthHeadersFuture<'_> {
            Box::pin(async {
                if self.calls.fetch_add(1, Ordering::SeqCst) >= self.allowed_calls {
                    return Err(codex_api::AuthError::Transient("fixture authentication unavailable".into()));
                }
                Ok(self.headers.clone())
            })
        }
    }

    struct FixedRouting {
        calls: Arc<AtomicUsize>,
    }

    impl WorkspaceRoutingResolver for FixedRouting {
        fn resolve(&self, _: WorkspaceRoutingRequest)
            -> Pin<Box<dyn Future<Output = io::Result<Option<WorkspaceRouting>>> + Send + '_>>
        {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Box::pin(async {
                Ok(Some(WorkspaceRouting {
                    chatgpt_account_id: "account_id".into(),
                    backend_origin: "https://region.example.invalid".into(),
                    account_routing_override: "us".into(),
                }))
            })
        }
    }

    fn prepared_spy(allowed_calls: usize) -> Arc<PreparedSpy> {
        let mut headers = http::HeaderMap::new();
        headers.insert(http::header::AUTHORIZATION, http::HeaderValue::from_static("Bearer Access Token"));
        headers.insert("ChatGPT-Account-ID", http::HeaderValue::from_static("account_id"));
        Arc::new(PreparedSpy { headers, calls: AtomicUsize::new(0), allowed_calls })
    }

    #[tokio::test]
    async fn official_routing_uses_cached_snapshot_without_async_manager_auth() {
        // These official constructors hold auth solely in memory. No default
        // identity, config, file store, Keychain, or network is consulted.
        let auth = CodexAuth::create_dummy_chatgpt_auth_for_testing();
        let manager = AuthManager::from_auth_for_testing(auth.clone());
        let external_calls = Arc::new(AtomicUsize::new(0));
        manager.set_external_auth(Arc::new(SpyExternal {
            auth, calls: Arc::clone(&external_calls),
        })).await.unwrap();
        assert_eq!(external_calls.load(Ordering::SeqCst), 1);
        let routing_calls = Arc::new(AtomicUsize::new(0));
        let resolver: Arc<dyn WorkspaceRoutingResolver> = Arc::new(FixedRouting {
            calls: Arc::clone(&routing_calls),
        });
        manager.set_workspace_routing_resolver(Arc::downgrade(&resolver));
        let prepared = prepared_spy(2);
        let provider = RequestModelProvider::new(Arc::clone(&manager), prepared.clone()).unwrap();
        let result = resolve_checked_provider(&provider, &bootstrap()).await.unwrap();
        assert_eq!(result.provider.base_url, "https://region.example.invalid/backend-api/codex");
        assert_eq!(result.provider.headers[codex_model_provider::ACCOUNT_ROUTING_HEADER], "us");
        assert_eq!(result.redirect_policy, codex_login::default_client::ClientRedirectPolicy::Reject);
        assert_eq!(result.provider.retry.max_attempts, 0);
        assert_eq!(routing_calls.load(Ordering::SeqCst), 1);
        assert_eq!(prepared.calls.load(Ordering::SeqCst), 2);
        assert_eq!(external_calls.load(Ordering::SeqCst), 1);

        // Sensitivity control: the original async manager path would call this
        // in-memory spy again. The assertions above therefore detect delegation.
        assert!(manager.auth().await.is_some());
        assert_eq!(external_calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn prepared_failure_before_or_after_routing_never_returns_a_provider() {
        for allowed_calls in [0, 1] {
            let manager = AuthManager::from_auth_for_testing(CodexAuth::create_dummy_chatgpt_auth_for_testing());
            let routing_calls = Arc::new(AtomicUsize::new(0));
            let resolver: Arc<dyn WorkspaceRoutingResolver> = Arc::new(FixedRouting {
                calls: Arc::clone(&routing_calls),
            });
            manager.set_workspace_routing_resolver(Arc::downgrade(&resolver));
            let provider = RequestModelProvider::new(manager, prepared_spy(allowed_calls)).unwrap();
            let result = resolve_checked_provider(&provider, &bootstrap()).await;
            assert_eq!(result.unwrap_err().status(), "authentication_unavailable");
            assert_eq!(routing_calls.load(Ordering::SeqCst), allowed_calls);
        }
    }

    fn entry(backend: &str, route: &str) -> AccountEntry {
        serde_json::from_value(json!({"id":"fixture-account", "workspace_backend_origin":backend,
            "account_routing_override":route})).unwrap()
    }

    fn bootstrap() -> Url { Url::parse("https://chatgpt.com/backend-api").unwrap() }

    #[test]
    fn metadata_paths_match_official_backend_conventions() {
        assert_eq!(metadata_url(&Url::parse("https://chatgpt.com").unwrap(), "accounts/check").unwrap().as_str(),
            "https://chatgpt.com/backend-api/wham/accounts/check");
        assert_eq!(metadata_url(&Url::parse("https://backend.example.invalid/").unwrap(), "config/bundle").unwrap().as_str(),
            "https://backend.example.invalid/api/codex/config/bundle");
        for value in ["http://chatgpt.com", "https://user:secret@chatgpt.com", "https://chatgpt.com/?query=1"] {
            assert!(metadata_url(&Url::parse(value).unwrap(), "accounts/check").is_err());
        }
    }

    #[test]
    fn selected_workspace_must_exist_exactly_once() {
        let response = |accounts| AccountsCheckResponse { accounts, account_ordering: vec![], default_account_id: Some("other".into()) };
        assert_eq!(selected_entry(response(vec![]), "fixture-account").unwrap_err().status(), "workspace_missing");
        assert_eq!(selected_entry(response(vec![entry("NO_CONSTRAINT", "us"), entry("NO_CONSTRAINT", "us")]), "fixture-account")
            .unwrap_err().status(), "workspace_duplicated");
        assert!(selected_entry(response(vec![entry("NO_CONSTRAINT", "us")]), "fixture-account").is_ok());
    }

    #[test]
    fn discovered_origin_must_be_secure_and_cannot_conflict_with_requirement() {
        let required = Url::parse("https://region.example.invalid/backend-api").unwrap();
        for invalid in ["http://region.example.invalid", "https://u:p@region.example.invalid", "https://region.example.invalid/path",
            "https://region.example.invalid/?q=1", "https://region.example.invalid/#fragment", " https://region.example.invalid"] {
            assert!(routing_from_entry(entry(invalid, "us"), None, &bootstrap()).is_err());
        }
        assert_eq!(routing_from_entry(entry("https://other.example.invalid", "us"), Some(&required), &bootstrap())
            .unwrap_err().status(), "workspace_backend_conflict");
        let routing = routing_from_entry(entry("https://region.example.invalid", "us_cr"), Some(&required), &bootstrap()).unwrap();
        assert_eq!(routing.backend_origin, "https://region.example.invalid");
        assert_eq!(routing.account_routing_override, "us_cr");
    }

    #[test]
    fn no_constraint_uses_required_then_effective_origin_and_rejects_unknown_routes() {
        let required = Url::parse("https://required.example.invalid/backend-api").unwrap();
        assert_eq!(routing_from_entry(entry("NO_CONSTRAINT", "NO_CONSTRAINT"), Some(&required), &bootstrap()).unwrap()
            .backend_origin, "https://required.example.invalid");
        assert_eq!(routing_from_entry(entry("NO_CONSTRAINT", "NO_CONSTRAINT"), None, &bootstrap()).unwrap()
            .backend_origin, "https://chatgpt.com");
        assert!(routing_from_entry(entry("NO_CONSTRAINT", "future-route"), None, &bootstrap()).is_err());
    }

    #[test]
    fn session_origin_changes_fail_for_previously_routed_requests() {
        let routing = routing_from_entry(entry("NO_CONSTRAINT", "NO_CONSTRAINT"), None, &bootstrap()).unwrap();
        let mut request = WorkspaceRoutingRequest { provider_base_url: "https://independent.example.invalid/v1".into(),
            chatgpt_base_url: bootstrap().into(), previously_routed: false, session: None };
        assert!(!is_workspace_bound(&request, &bootstrap(), &routing).unwrap());
        request.previously_routed = true;
        request.chatgpt_base_url = "https://changed.example.invalid".into();
        assert_eq!(is_workspace_bound(&request, &bootstrap(), &routing).unwrap_err().status(), "workspace_bootstrap_changed");
    }

    #[test]
    fn bundle_mapping_preserves_order_and_separate_config_and_requirements() {
        let response: ConfigBundleResponse = serde_json::from_value(json!({
            "config_toml":{"enterprise_managed":[{"id":"c1","name":"C1","contents":"model='fixture'"}]},
            "requirements_toml":{"enterprise_managed":[
                {"id":"r1","name":"R1","contents":"allowed_login_methods=['chatgpt']"},
                {"id":"r2","name":"R2","contents":"[application.network]"}]}
        })).unwrap();
        let bundle = bundle_from_response(response);
        assert_eq!(bundle.config_toml.enterprise_managed[0].id, "c1");
        assert_eq!(bundle.requirements_toml.enterprise_managed.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(), vec!["r1", "r2"]);
        assert!(bundle_from_response(serde_json::from_value(json!({"config_toml":null})).unwrap()).is_empty());
    }

    #[test]
    fn cloud_eligibility_distinguishes_known_plans_from_unknown_metadata() {
        for plan in [PlanType::Business, PlanType::Enterprise, PlanType::Ent26, PlanType::Edu,
            PlanType::EduPlus, PlanType::EduPro, PlanType::EnterpriseCbpUsageBased] {
            assert_eq!(plan_bundle_eligibility(Some(plan)).unwrap(), CloudBundleEligibility::Required);
        }
        for plan in [PlanType::Free, PlanType::Go, PlanType::Plus, PlanType::Pro, PlanType::ProLite,
            PlanType::Team, PlanType::SelfServeBusinessProLite, PlanType::SelfServeBusinessUsageBased] {
            assert_eq!(plan_bundle_eligibility(Some(plan)).unwrap(), CloudBundleEligibility::NotRequired);
        }
        assert!(plan_bundle_eligibility(None).is_err());
        assert!(plan_bundle_eligibility(Some(PlanType::Unknown)).is_err());
    }
}

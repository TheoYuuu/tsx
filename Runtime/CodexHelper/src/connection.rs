//! One leased, already-registered TranslateX identity connected to official account
//! metadata and a single text response. The native owner supplies a clean
//! environment and owns worker cancellation/reaping. Only QA suppresses Keychain UI.
//! No user Codex configuration, catalog fallback, or text persistence is used.

use crate::account_request::{AccountRequestOptions, prepare_account_request};
use crate::network::StrictTransport;
use crate::policy::{self, ModelConstraints};
use crate::protocol::{ModelSummary, Operation, Request};
use crate::routing::{self, CloudBundleEligibility, WorkspaceResolver};
use crate::translation::{self, TranslationInput};
use codex_api::SharedAuthProvider;
use codex_file_system::{
    CopyOptions, CreateDirectoryOptions, ExecutorFileSystem, ExecutorFileSystemFuture,
    FileMetadata, FileSystemReadStream, FileSystemSandboxContext, GetMetadataOptions,
    ReadDirectoryEntry, ReadFileOptions, RemoveOptions, WalkOptions, WalkOutcome,
    WriteFileOptions,
};
use codex_http_client::{
    DestinationPolicy, HttpClientFactory, NetworkPolicyController, OutboundProxyPolicy,
};
use codex_login::{AuthManager, AuthRouteConfig, CodexAuth};
use codex_model_provider_info::{ModelProviderInfo, set_managed_residency_requirement};
use codex_protocol::config_types::{SERVICE_TIER_DEFAULT_REQUEST_VALUE, ServiceTier};
use codex_protocol::openai_models::{
    InputModality, ModelInfo, ModelPreset, ModelsResponse, ReasoningEffort,
};
use codex_utils_path_uri::PathUri;
use http::{Method, header::AUTHORIZATION};
use std::collections::BTreeSet;
use std::fs::OpenOptions;
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use url::Url;

const TOTAL_DEADLINE: Duration = Duration::from_secs(80);
const METADATA_DEADLINE: Duration = Duration::from_secs(20);
const MAX_POLICY_BYTES: usize = 1024 * 1024;
const MAX_MODELS: usize = 256;
const MAX_REASONING_EFFORTS: usize = 16;
const BOOTSTRAP_URL: &str = "https://chatgpt.com/backend-api";

/// The official policy-only loader currently needs only these two files on
/// macOS. Forced managed preferences remain the official loader's own source.
/// All other filesystem operations fail explicitly instead of widening access.
pub(crate) struct TrustedPolicyFileSystem;

fn allowed_policy_path(path: &Path) -> bool {
    path == Path::new("/etc/codex/requirements.toml")
        || path == Path::new("/etc/codex/managed_config.toml")
}

fn unsupported<'a, T: Send + 'a>() -> ExecutorFileSystemFuture<'a, T> {
    Box::pin(async {
        Err(io::Error::new(io::ErrorKind::PermissionDenied, "policy filesystem operation denied"))
    })
}

impl ExecutorFileSystem for TrustedPolicyFileSystem {
    fn read_file<'a>(
        &'a self, path: &'a PathUri, options: ReadFileOptions,
        sandbox: Option<&'a FileSystemSandboxContext>,
    ) -> ExecutorFileSystemFuture<'a, Vec<u8>> {
        Box::pin(async move {
            let path = path.to_abs_path()?;
            if sandbox.is_some() || !allowed_policy_path(path.as_path()) {
                return Err(io::Error::new(io::ErrorKind::PermissionDenied, "policy path denied"));
            }
            let flags = libc::O_CLOEXEC | libc::O_NONBLOCK
                | if options.follow_symlinks { 0 } else { libc::O_NOFOLLOW };
            let file = OpenOptions::new().read(true).custom_flags(flags).open(path.as_path())?;
            if !file.metadata()?.is_file() {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "policy source is not a regular file"));
            }
            let mut bytes = Vec::new();
            file.take((MAX_POLICY_BYTES + 1) as u64).read_to_end(&mut bytes)?;
            if bytes.len() > MAX_POLICY_BYTES {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "policy source exceeds limit"));
            }
            Ok(bytes)
        })
    }

    fn canonicalize<'a>(&'a self, _: &'a PathUri, _: Option<&'a FileSystemSandboxContext>)
        -> ExecutorFileSystemFuture<'a, PathUri> { unsupported() }
    fn read_file_stream<'a>(&'a self, _: &'a PathUri, _: Option<&'a FileSystemSandboxContext>)
        -> ExecutorFileSystemFuture<'a, FileSystemReadStream> { unsupported() }
    fn write_file<'a>(&'a self, _: &'a PathUri, _: Vec<u8>, _: WriteFileOptions, _: Option<&'a FileSystemSandboxContext>)
        -> ExecutorFileSystemFuture<'a, ()> { unsupported() }
    fn create_directory<'a>(&'a self, _: &'a PathUri, _: CreateDirectoryOptions, _: Option<&'a FileSystemSandboxContext>)
        -> ExecutorFileSystemFuture<'a, ()> { unsupported() }
    fn get_metadata<'a>(&'a self, _: &'a PathUri, _: GetMetadataOptions, _: Option<&'a FileSystemSandboxContext>)
        -> ExecutorFileSystemFuture<'a, FileMetadata> { unsupported() }
    fn read_directory<'a>(&'a self, _: &'a PathUri, _: Option<&'a FileSystemSandboxContext>)
        -> ExecutorFileSystemFuture<'a, Vec<ReadDirectoryEntry>> { unsupported() }
    fn walk<'a>(&'a self, _: &'a PathUri, _: WalkOptions, _: Option<&'a FileSystemSandboxContext>)
        -> ExecutorFileSystemFuture<'a, WalkOutcome> { unsupported() }
    fn remove<'a>(&'a self, _: &'a PathUri, _: RemoveOptions, _: Option<&'a FileSystemSandboxContext>)
        -> ExecutorFileSystemFuture<'a, ()> { unsupported() }
    fn copy<'a>(&'a self, _: &'a PathUri, _: &'a PathUri, _: CopyOptions, _: Option<&'a FileSystemSandboxContext>)
        -> ExecutorFileSystemFuture<'a, ()> { unsupported() }
}

struct PolicyOwners {
    bootstrap: NetworkPolicyController,
    content: NetworkPolicyController,
}

impl PolicyOwners {
    fn new() -> Self {
        let value = Self {
            bootstrap: NetworkPolicyController::default(),
            content: NetworkPolicyController::default(),
        };
        // No content request may begin before the final cloud/local composition.
        let policy = value.content.policy();
        assert!(value.content.publish(policy.revision(), DestinationPolicy::Restricted {
            allowed_hosts: BTreeSet::new(),
        }));
        value
    }
}

impl Drop for PolicyOwners {
    fn drop(&mut self) {
        self.bootstrap.policy().invalidate();
        self.content.policy().invalidate();
    }
}

struct AuthorizedConnection {
    manager: Arc<AuthManager>,
    prepared: SharedAuthProvider,
    resolver: Arc<WorkspaceResolver>,
    constraints: ModelConstraints,
    account_plan: Option<String>,
    _policies: PolicyOwners,
}

async fn require_prepared(prepared: &SharedAuthProvider) -> Result<(), &'static str> {
    let headers = prepared.resolve_auth_headers().await.map_err(|_| "authentication_unavailable")?;
    if !headers.contains_key(AUTHORIZATION) {
        return Err("authentication_unavailable");
    }
    Ok(())
}

async fn authorize(home: &Path) -> Result<AuthorizedConnection, &'static str> {
    let policies = PolicyOwners::new();
    // Capture both revisions before loading either policy source.
    let bootstrap_revision = policies.bootstrap.policy().revision();
    let content_revision = policies.content.policy().revision();
    let local = policy::load_local_trusted(&TrustedPolicyFileSystem, home).await
        .map_err(|error| error.status())?;
    let bootstrap_policy = local.snapshot.publish(&policies.bootstrap, bootstrap_revision)
        .map_err(|error| error.status())?;
    let bootstrap_factory = HttpClientFactory::new(OutboundProxyPolicy::RespectSystemProxy)
        .with_network_policy(bootstrap_policy.for_current_account());
    let content_factory = HttpClientFactory::new(OutboundProxyPolicy::RespectSystemProxy)
        .with_network_policy(policies.content.policy());
    let route = AuthRouteConfig::from_http_client_factory(content_factory)
        .with_local_bootstrap_factory(bootstrap_factory.clone());
    let local_config = local.snapshot.auth_config(home.to_path_buf(), route.clone())
        .map_err(|error| error.status())?;
    // The shared-manager constructor intentionally swallows store-load errors.
    // Preflight the same strict config so storage failure cannot become signout.
    let loaded = local_config.load_auth(false).await
        .map_err(|_| "authentication_unavailable")?.ok_or("signed_out")?;
    if !matches!(loaded, CodexAuth::Chatgpt(_)) {
        return Err("unexpected_auth_method");
    }
    if !local_config.allows_auth(&loaded) {
        return Err("managed_auth_denied");
    }
    let manager = AuthManager::shared_from_auth_config(local_config, false).await
        .map_err(|_| "authentication_unavailable")?;
    let expected = manager.auth_cached().ok_or("authentication_unavailable")?;
    if loaded.get_token_data().ok() != expected.get_token_data().ok() {
        return Err("identity_inconsistent");
    }
    let mut changes = manager.auth_change_state_receiver();
    let owner_generation = changes.borrow().owner_generation;
    let operation = async {
        let prepared = prepare_account_request(Arc::clone(&manager), expected, AccountRequestOptions::default())
            .await.map_err(|error| error.status())?.provider;
        require_prepared(&prepared).await?;
        let current = manager.auth_cached().ok_or("signed_out")?;
        let bootstrap = Url::parse(BOOTSTRAP_URL).map_err(|_| "invalid_bootstrap_url")?;
        let bundle = match routing::cloud_bundle_eligibility(&current).map_err(|error| error.status())? {
            CloudBundleEligibility::NotRequired => None,
            CloudBundleEligibility::Required => Some(routing::fetch_cloud_bundle(
                bootstrap_factory, &bootstrap, Arc::clone(&prepared), METADATA_DEADLINE,
            ).await.map_err(|error| error.status())?),
        };
        let final_policy = policy::complete_trusted(&TrustedPolicyFileSystem, home, &local, Ok(bundle))
            .await.map_err(|error| error.status())?;
        let final_config = final_policy.auth_config(home.to_path_buf(), route)
            .map_err(|error| error.status())?;
        let current = manager.auth_cached().ok_or("signed_out")?;
        if !final_config.allows_auth(&current) {
            return Err("managed_auth_denied");
        }
        require_prepared(&prepared).await?;
        validate_constraints(&final_policy.model)?;
        final_policy.publish(&policies.content, content_revision).map_err(|error| error.status())?;
        // The native contract runs one operation per worker, so this official
        // process-wide setting cannot race another request or survive reuse.
        set_managed_residency_requirement(final_policy.model.enforce_residency);
        let resolver = WorkspaceResolver::install(
            Arc::clone(&manager), bootstrap, None, Arc::clone(&prepared), METADATA_DEADLINE,
        ).map_err(|error| error.status())?;
        let account_plan = current.account_plan_type()
            .and_then(|plan| serde_json::to_value(plan).ok())
            .and_then(|value| value.as_str().map(str::to_owned));
        Ok(AuthorizedConnection {
            manager: Arc::clone(&manager), prepared, resolver,
            constraints: final_policy.model, account_plan, _policies: policies,
        })
    };
    tokio::select! {
        biased;
        _ = changes.wait_for(|state| state.owner_generation != owner_generation) => Err("identity_changed"),
        result = operation => result,
    }
}

impl AuthorizedConnection {
    async fn catalog(&self) -> Result<ModelsResponse, &'static str> {
        require_prepared(&self.prepared).await?;
        let current = self.manager.auth_cached().ok_or("signed_out")?;
        let bootstrap_provider = ModelProviderInfo::create_openai_provider(None)
            .to_api_provider(Some(current.auth_mode())).map_err(|_| "model_provider_unavailable")?;
        let response = routing::fetch_models(
            self.manager.http_client_factory(), &bootstrap_provider,
            Arc::clone(&self.prepared), METADATA_DEADLINE,
        ).await.map_err(|error| error.status())?;
        require_prepared(&self.prepared).await?;
        validate_catalog(&response)?;
        Ok(response)
    }
}

/// Validates the freshly stored login against local/cloud management rules.
/// It never fetches a model catalog or submits a model request.
pub(crate) async fn validate_login(home: &Path) -> Result<Option<String>, &'static str> {
    tokio::time::timeout(TOTAL_DEADLINE, async {
        Ok(authorize(home).await?.account_plan)
    }).await.map_err(|_| "timeout")?
}

pub async fn models(home: &Path) -> Result<Vec<ModelSummary>, &'static str> {
    tokio::time::timeout(TOTAL_DEADLINE, async {
        let connection = authorize(home).await?;
        let catalog = connection.catalog().await?;
        summarize_catalog(&catalog, &connection.constraints)
    }).await.map_err(|_| "timeout")?
}

pub async fn translate(home: &Path, request: &Request) -> Result<String, &'static str> {
    if request.operation != Operation::Translate || !request.valid() {
        return Err("invalid_input");
    }
    tokio::time::timeout(TOTAL_DEADLINE, async {
        let connection = authorize(home).await?;
        let catalog = connection.catalog().await?;
        let model = select_model(&catalog, request.model.as_deref().ok_or("invalid_input")?, &connection.constraints)?;
        let selected = model_options(model, &connection.constraints)?;
        let input = TranslationInput {
            model: model.slug.clone(),
            text: request.text.clone().ok_or("invalid_input")?,
            source_language: request.source_language.clone(),
            target_language: request.target_language.clone().ok_or("invalid_input")?,
            reasoning: selected.reasoning,
            service_tier: selected.service_tier,
            managed_instructions: connection.constraints.additional_developer_instructions.clone(),
        };
        input.body().map_err(|error| error.0)?;
        let resolved = routing::resolve_responses_provider(&connection.resolver).await
            .map_err(|error| error.status())?;
        require_prepared(&connection.prepared).await?;
        let endpoint = Url::parse(&resolved.provider.url_for_path("responses"))
            .map_err(|_| "model_provider_unavailable")?;
        let transport = StrictTransport::new(
            connection.manager.http_client_factory(), endpoint, Method::POST,
            translation::DEADLINE, 4 * 1024 * 1024,
        ).map_err(|error| error.status())?;
        translation::translate(transport, resolved.provider, Arc::clone(&connection.prepared), &input)
            .await.map_err(|error| error.0)
    }).await.map_err(|_| "timeout")?
}

fn safe_catalog_text(value: &str, limit: usize) -> bool {
    !value.is_empty() && value.len() <= limit && value.trim() == value
        && !value.chars().any(|character| character.is_control()
            || matches!(character, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'))
}

fn validate_constraints(constraints: &ModelConstraints) -> Result<(), &'static str> {
    if constraints.model.as_ref().is_some_and(|value| !safe_catalog_text(value, 256))
        || constraints.reasoning_effort.as_ref().is_some_and(|value| !safe_catalog_text(value.as_str(), 128))
        || constraints.additional_developer_instructions.as_ref().is_some_and(|value| value.len() > 16 * 1024)
        || constraints.service_tier.as_deref().is_some_and(|value| {
            value != SERVICE_TIER_DEFAULT_REQUEST_VALUE && ServiceTier::from_request_value(value).is_none()
        })
    {
        return Err("unsupported_managed_policy");
    }
    Ok(())
}

fn validate_catalog(catalog: &ModelsResponse) -> Result<(), &'static str> {
    if catalog.models.is_empty() || catalog.models.len() > MAX_MODELS {
        return Err("catalog_invalid");
    }
    let mut identifiers = BTreeSet::new();
    for model in &catalog.models {
        if !safe_catalog_text(&model.slug, 256) || !safe_catalog_text(&model.display_name, 256)
            || !identifiers.insert(model.slug.as_str()) || model.used_fallback_model_metadata
            || model.supported_reasoning_levels.len() > MAX_REASONING_EFFORTS
        {
            return Err("catalog_invalid");
        }
        let mut efforts = BTreeSet::new();
        for preset in &model.supported_reasoning_levels {
            if !safe_catalog_text(preset.effort.as_str(), 128) || !efforts.insert(preset.effort.as_str()) {
                return Err("catalog_invalid");
            }
        }
        if let Some(default) = &model.default_reasoning_level {
            if !safe_catalog_text(default.as_str(), 128)
                || (!efforts.contains(default.as_str())
                    && !(efforts.is_empty() && *default == ReasoningEffort::None))
            {
                return Err("catalog_invalid");
            }
        }
    }
    Ok(())
}

fn selectable(model: &ModelInfo) -> bool {
    let preset = ModelPreset::from(model.clone());
    preset.show_in_picker && preset.input_modalities.contains(&InputModality::Text)
}

fn select_model<'a>(
    catalog: &'a ModelsResponse, requested: &str, constraints: &ModelConstraints,
) -> Result<&'a ModelInfo, &'static str> {
    validate_catalog(catalog)?;
    validate_constraints(constraints)?;
    if constraints.model.as_deref().is_some_and(|required| required != requested) {
        return Err("managed_model_mismatch");
    }
    catalog.models.iter().find(|model| model.slug == requested && selectable(model))
        .ok_or("model_unavailable")
}

struct ModelOptions {
    reasoning: Option<ReasoningEffort>,
    service_tier: Option<ServiceTier>,
}

fn model_options(model: &ModelInfo, constraints: &ModelConstraints) -> Result<ModelOptions, &'static str> {
    let supports = |effort: &ReasoningEffort| model.supported_reasoning_levels.iter()
        .any(|preset| &preset.effort == effort);
    let reasoning = if let Some(required) = &constraints.reasoning_effort {
        if *required == ReasoningEffort::None && model.supported_reasoning_levels.is_empty() {
            None
        } else {
            if !supports(required) { return Err("managed_reasoning_unavailable"); }
            Some(required.clone())
        }
    } else if model.supported_reasoning_levels.is_empty() {
        None
    } else {
        // Prefer the least intensive advertised known effort. A future custom
        // effort is selected only when the catalog explicitly marks it default.
        [ReasoningEffort::None, ReasoningEffort::Minimal, ReasoningEffort::Low,
            ReasoningEffort::Medium, ReasoningEffort::High, ReasoningEffort::XHigh,
            ReasoningEffort::Max, ReasoningEffort::Ultra, ReasoningEffort::Persistent]
            .into_iter().find(supports)
            .or_else(|| model.default_reasoning_level.clone().filter(supports))
            .map(Some).ok_or("model_reasoning_unavailable")?
    };
    let service_tier = match constraints.service_tier.as_deref() {
        None | Some(SERVICE_TIER_DEFAULT_REQUEST_VALUE) => None,
        Some(value) => {
            let tier = ServiceTier::from_request_value(value).ok_or("unsupported_managed_policy")?;
            if !model.supports_service_tier(tier.request_value()) {
                return Err("managed_service_tier_unavailable");
            }
            Some(tier)
        }
    };
    Ok(ModelOptions { reasoning, service_tier })
}

fn summarize_catalog(catalog: &ModelsResponse, constraints: &ModelConstraints) -> Result<Vec<ModelSummary>, &'static str> {
    validate_catalog(catalog)?;
    validate_constraints(constraints)?;
    let mut summaries = Vec::new();
    for model in catalog.models.iter().filter(|model| selectable(model)) {
        if constraints.model.as_deref().is_some_and(|required| required != model.slug) {
            continue;
        }
        let selected = match model_options(model, constraints) {
            Ok(selected) => selected,
            Err(_) if constraints.model.is_none() => continue,
            Err(error) => return Err(error),
        };
        summaries.push(ModelSummary {
            id: model.slug.clone(), name: model.display_name.clone(),
            reasoning_efforts: model.supported_reasoning_levels.iter()
                .map(|preset| preset.effort.as_str().to_owned()).collect(),
            default_reasoning_effort: selected.reasoning.as_ref().map(|effort| effort.as_str().to_owned()),
        });
    }
    if summaries.is_empty() { return Err("model_unavailable"); }
    Ok(summaries)
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_protocol::openai_models::{ModelServiceTier, ModelVisibility, ReasoningEffortPreset};
    use serde_json::json;

    fn model(id: &str) -> ModelInfo {
        serde_json::from_value(json!({
            "slug":id,"display_name":"Constructed model","description":null,
            "supported_reasoning_levels":[
                {"effort":"high","description":"Constructed high"},
                {"effort":"low","description":"Constructed low"}],
            "default_reasoning_level":"high","shell_type":"unified_exec",
            "visibility":"list","supported_in_api":false,"priority":1,
            "upgrade":null,"model_messages":null,"support_verbosity":false,
            "default_verbosity":null,"apply_patch_tool_type":null,
            "truncation_policy":{"mode":"bytes","limit":10000},
            "experimental_supported_tools":[],"input_modalities":["text"]
        })).unwrap()
    }

    fn catalog(models: Vec<ModelInfo>) -> ModelsResponse { ModelsResponse { models } }

    #[test]
    fn catalog_selection_requires_visible_text_and_never_uses_an_alias_or_fallback() {
        let mut hidden = model("hidden");
        hidden.visibility = ModelVisibility::Hide;
        let mut image = model("image-only");
        image.input_modalities = vec![InputModality::Image];
        let values = catalog(vec![model("exact"), hidden, image]);
        let constraints = ModelConstraints::default();
        let summaries = summarize_catalog(&values, &constraints).unwrap();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].id, "exact");
        // supported_in_api=false is valid for the authenticated ChatGPT catalog.
        assert!(select_model(&values, "exact", &constraints).is_ok());
        for missing in ["", "EXACT", "latest", "hidden", "image-only", "unknown"] {
            assert_eq!(select_model(&values, missing, &constraints).unwrap_err(), "model_unavailable");
        }
    }

    #[test]
    fn managed_model_is_filtered_in_picker_and_not_substituted_during_translation() {
        let values = catalog(vec![model("chosen"), model("other")]);
        let mut constraints = ModelConstraints { model: Some("chosen".into()), ..Default::default() };
        let summaries = summarize_catalog(&values, &constraints).unwrap();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].id, "chosen");
        assert_eq!(select_model(&values, "other", &constraints).unwrap_err(), "managed_model_mismatch");
        constraints.model = Some("not-in-catalog".into());
        assert!(summarize_catalog(&values, &constraints).is_err());
        assert_eq!(select_model(&values, "not-in-catalog", &constraints).unwrap_err(), "model_unavailable");
    }

    #[test]
    fn catalog_duplicate_empty_control_and_oversized_metadata_fail_without_truncation() {
        let mut invalid = Vec::new();
        invalid.push(catalog(vec![]));
        invalid.push(catalog(vec![model("same"), model("same")]));
        invalid.push(catalog((0..=MAX_MODELS).map(|index| model(&format!("fixture-{index}"))).collect()));
        for id in ["", " ", "model\n", "model\u{202e}"] {
            invalid.push(catalog(vec![model(id)]));
        }
        let mut long = model("valid");
        long.display_name = "汉".repeat(86);
        invalid.push(catalog(vec![long]));
        let mut control = model("valid");
        control.display_name = "Hidden\tcontrol".into();
        invalid.push(catalog(vec![control]));
        let mut fallback = model("valid");
        fallback.used_fallback_model_metadata = true;
        invalid.push(catalog(vec![fallback]));
        for value in invalid { assert_eq!(validate_catalog(&value), Err("catalog_invalid")); }
    }

    #[test]
    fn reasoning_catalog_limits_duplicates_and_contradictory_defaults_are_rejected() {
        let mut invalid = Vec::new();
        let mut duplicate = model("valid");
        duplicate.supported_reasoning_levels.push(duplicate.supported_reasoning_levels[0].clone());
        invalid.push(duplicate);
        let mut many = model("valid");
        many.supported_reasoning_levels = (0..=MAX_REASONING_EFFORTS).map(|index| ReasoningEffortPreset {
            effort: ReasoningEffort::Custom(format!("future-{index}")), description: String::new(),
        }).collect();
        invalid.push(many);
        for value in ["".to_owned(), "bad\nvalue".into(), "x".repeat(129)] {
            let mut bad = model("valid");
            bad.supported_reasoning_levels[0].effort = ReasoningEffort::Custom(value);
            invalid.push(bad);
        }
        let mut contradictory = model("valid");
        contradictory.default_reasoning_level = Some(ReasoningEffort::Medium);
        invalid.push(contradictory);
        for value in invalid {
            assert_eq!(validate_catalog(&catalog(vec![value])), Err("catalog_invalid"));
        }
    }

    #[test]
    fn default_effort_is_the_least_intensive_advertised_known_value() {
        let model = model("valid");
        let selected = model_options(&model, &ModelConstraints::default()).unwrap();
        assert_eq!(selected.reasoning, Some(ReasoningEffort::Low));
        let summary = summarize_catalog(&catalog(vec![model]), &ModelConstraints::default()).unwrap();
        assert_eq!(summary[0].reasoning_efforts, vec!["high", "low"]);
        assert_eq!(summary[0].default_reasoning_effort.as_deref(), Some("low"));
    }

    #[test]
    fn required_reasoning_must_be_supported_and_custom_defaults_are_explicit() {
        let mut value = model("valid");
        let mut constraints = ModelConstraints { reasoning_effort: Some(ReasoningEffort::High), ..Default::default() };
        assert_eq!(model_options(&value, &constraints).unwrap().reasoning, Some(ReasoningEffort::High));
        constraints.reasoning_effort = Some(ReasoningEffort::Ultra);
        assert!(matches!(model_options(&value, &constraints), Err("managed_reasoning_unavailable")));
        value.supported_reasoning_levels = vec![ReasoningEffortPreset {
            effort: ReasoningEffort::Custom("future-effort".into()), description: String::new(),
        }];
        value.default_reasoning_level = None;
        assert!(matches!(model_options(&value, &ModelConstraints::default()), Err("model_reasoning_unavailable")));
        value.default_reasoning_level = Some(ReasoningEffort::Custom("future-effort".into()));
        assert_eq!(model_options(&value, &ModelConstraints::default()).unwrap().reasoning, value.default_reasoning_level);
    }

    #[test]
    fn models_without_reasoning_omit_the_parameter_and_satisfy_managed_none() {
        let mut value = model("no-reasoning");
        value.supported_reasoning_levels.clear();
        value.default_reasoning_level = None;
        assert!(validate_catalog(&catalog(vec![value.clone()])).is_ok());
        assert_eq!(model_options(&value, &ModelConstraints::default()).unwrap().reasoning, None);
        let constraints = ModelConstraints { reasoning_effort: Some(ReasoningEffort::None), ..Default::default() };
        assert_eq!(model_options(&value, &constraints).unwrap().reasoning, None);
    }

    #[test]
    fn managed_service_tier_uses_official_support_and_catalog_defaults_are_not_upsold() {
        let mut value = model("valid");
        value.default_service_tier = Some("priority".into());
        assert_eq!(model_options(&value, &ModelConstraints::default()).unwrap().service_tier, None);
        let mut constraints = ModelConstraints { service_tier: Some("fast".into()), ..Default::default() };
        assert!(matches!(model_options(&value, &constraints), Err("managed_service_tier_unavailable")));
        value.service_tiers.push(ModelServiceTier {
            id: "priority".into(), name: "Constructed".into(), description: String::new(),
        });
        assert_eq!(model_options(&value, &constraints).unwrap().service_tier, Some(ServiceTier::Fast));
        constraints.service_tier = Some("default".into());
        assert_eq!(model_options(&value, &constraints).unwrap().service_tier, None);
        constraints.service_tier = Some("future-tier".into());
        assert_eq!(validate_constraints(&constraints), Err("unsupported_managed_policy"));
        constraints.service_tier = Some("flex".into());
        value.service_tiers.clear();
        // Pinned official ModelInfo explicitly supports Flex without listing it.
        assert_eq!(model_options(&value, &constraints).unwrap().service_tier, Some(ServiceTier::Flex));
    }

    #[test]
    fn picker_excludes_models_incompatible_with_managed_effort() {
        let first = model("supports-high");
        let mut second = model("only-low");
        second.supported_reasoning_levels.retain(|preset| preset.effort == ReasoningEffort::Low);
        second.default_reasoning_level = Some(ReasoningEffort::Low);
        let constraints = ModelConstraints { reasoning_effort: Some(ReasoningEffort::High), ..Default::default() };
        let summaries = summarize_catalog(&catalog(vec![first, second]), &constraints).unwrap();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].id, "supports-high");
    }

    #[test]
    fn policy_adapter_never_accepts_default_identity_or_project_paths() {
        assert!(allowed_policy_path(Path::new("/etc/codex/requirements.toml")));
        assert!(allowed_policy_path(Path::new("/etc/codex/managed_config.toml")));
        for path in ["/Users/constructed/.codex/config.toml", "/tmp/config.toml",
            "/etc/codex/../auth.json", "/etc/codex/auth.json"] {
            assert!(!allowed_policy_path(Path::new(path)));
        }
    }

    #[test]
    fn content_policy_starts_denied_and_scope_drop_revokes_both_owners() {
        let owners = PolicyOwners::new();
        let destination: Url = "https://constructed.invalid".parse().unwrap();
        let content = owners.content.policy();
        assert!(content.acquire(&destination).is_err());
        assert!(owners.bootstrap.publish(owners.bootstrap.policy().revision(), DestinationPolicy::Unrestricted));
        assert!(owners.content.publish(content.revision(), DestinationPolicy::Unrestricted));
        let bootstrap = owners.bootstrap.policy();
        assert!(bootstrap.acquire(&destination).is_ok());
        assert!(content.acquire(&destination).is_ok());
        drop(owners);
        assert!(bootstrap.for_current_account().acquire(&destination).is_err());
        assert!(content.for_current_account().acquire(&destination).is_err());
    }
}

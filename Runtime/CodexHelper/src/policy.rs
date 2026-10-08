//! Trusted management-policy assembly for the standalone translation helper.
//!
//! Production uses the pinned official policy-only loader: system requirements,
//! legacy system managed config, and forced macOS preferences. It never loads
//! user/project configuration or takes policy overrides from IPC/environment.
//! The caller owns cloud authentication, deadlines, identity generations, and
//! NetworkPolicyController invalidation; no auth/network/storage work occurs here.
use codex_config::loader::{load_local_application_requirements, load_managed_requirements_state, LocalApplicationRequirements};
use codex_config::{
    CloudConfigBundle, CloudConfigBundleLayers, CloudConfigBundleLoadError,
    CloudConfigBundleLoader, ConfigLoadOptions, ConfigRequirements,
    ConfigRequirementsToml, ConfigRequirementsWithSources, LoaderOverrides,
    ManagedAuthPolicy, NetworkDomainPermissionToml, RequirementSource, ResidencyRequirement,
};
use codex_file_system::ExecutorFileSystem;
use codex_http_client::{DestinationPolicy, NetworkPolicy, NetworkPolicyController, NetworkPolicyRevision};
use codex_login::{AuthConfig, AuthCredentialsStoreMode, AuthKeyringBackendKind, AuthRouteConfig};
use codex_protocol::config_types::ForcedLoginMethod;
use codex_protocol::openai_models::ReasoningEffort;
use std::fmt;
use std::path::{Component, Path, PathBuf};
use tracing::instrument::WithSubscriber;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PolicyError {
    InvalidIdentityHome,
    Unavailable,
    CloudUnavailable,
    Unsupported,
    Superseded,
    AuthenticationDenied,
}

impl PolicyError {
    pub const fn status(self) -> &'static str {
        match self {
            Self::InvalidIdentityHome => "invalid_identity_home",
            Self::Unavailable => "managed_policy_unavailable",
            Self::CloudUnavailable => "managed_cloud_policy_unavailable",
            Self::Unsupported => "unsupported_managed_policy",
            Self::Superseded => "managed_policy_superseded",
            Self::AuthenticationDenied => "managed_auth_denied",
        }
    }
}

impl fmt::Display for PolicyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { f.write_str(self.status()) }
}
impl std::error::Error for PolicyError {}

/// Requirements that the caller must apply to its actual model request. In
/// particular residency is not satisfied merely by storing this value: routing
/// and headers must apply it. No Debug implementation may expose managed text.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct ModelConstraints {
    pub model: Option<String>,
    pub reasoning_effort: Option<ReasoningEffort>,
    pub service_tier: Option<String>,
    pub enforce_residency: Option<ResidencyRequirement>,
    pub additional_developer_instructions: Option<String>,
}
impl fmt::Debug for ModelConstraints {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ModelConstraints").finish_non_exhaustive()
    }
}

#[derive(Clone)]
pub struct PolicySnapshot {
    pub managed_auth_policy: ManagedAuthPolicy,
    pub destinations: DestinationPolicy,
    pub model: ModelConstraints,
}
impl fmt::Debug for PolicySnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PolicySnapshot").finish_non_exhaustive()
    }
}

impl PolicySnapshot {
    /// No caller-supplied issuer, environment auth, file fallback, or default
    /// Codex identity. The caller chooses the Lumax-owned home before this call.
    pub fn auth_config(&self, home: PathBuf, route: AuthRouteConfig) -> Result<AuthConfig, PolicyError> {
        validate_home(&home)?;
        let config = AuthConfig {
            codex_home: home,
            auth_credentials_store_mode: AuthCredentialsStoreMode::Keyring,
            keyring_backend_kind: AuthKeyringBackendKind::Direct,
            forced_login_method: Some(ForcedLoginMethod::Chatgpt),
            chatgpt_base_url: None,
            forced_chatgpt_workspace_id: None,
            managed_auth_policy: self.managed_auth_policy.clone(),
            auth_route_config: route,
        };
        config.validate().map_err(|_| PolicyError::AuthenticationDenied)?;
        Ok(config)
    }

    /// The revision must be captured BEFORE loading. Do not fetch a new revision
    /// after an account switch to authorize a policy loaded for the old owner.
    pub fn publish(&self, controller: &NetworkPolicyController, revision: NetworkPolicyRevision)
        -> Result<NetworkPolicy, PolicyError>
    {
        if !controller.publish(revision, self.destinations.clone()) {
            return Err(PolicyError::Superseded);
        }
        Ok(controller.policy())
    }
}

pub struct LocalPolicy {
    pub snapshot: PolicySnapshot,
    home: PathBuf,
    local_application: LocalApplicationRequirements,
    overrides: LoaderOverrides,
}
impl fmt::Debug for LocalPolicy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LocalPolicy").finish_non_exhaustive()
    }
}

fn validate_home(home: &Path) -> Result<(), PolicyError> {
    if !home.is_absolute() || home.components().any(|part| matches!(part, Component::ParentDir | Component::CurDir)) {
        return Err(PolicyError::InvalidIdentityHome);
    }
    Ok(())
}

fn trusted_overrides() -> LoaderOverrides {
    // None preserves BOTH forced MDM inputs and the fixed /etc/codex sources.
    // Some("") is only appropriate in tests, where it disables a real MDM read.
    LoaderOverrides {
        ignore_managed_requirements: false,
        ignore_login_requirements: false,
        ignore_user_config: true,
        ignore_project_config: true,
        ignore_user_and_project_exec_policy_rules: true,
        ..Default::default()
    }
}

/// Loads and validates local policy before auth/cloud bootstrap. The official
/// application loader first synchronizes forced macOS preferences. Pass an
/// actual filesystem implementation in production; tests call the private
/// override entry point with their in-memory sources instead.
pub async fn load_local_trusted(fs: &dyn ExecutorFileSystem, home: &Path) -> Result<LocalPolicy, PolicyError> {
    load_local_with_overrides(fs, home, trusted_overrides()).await
}

async fn load_local_with_overrides(
    fs: &dyn ExecutorFileSystem,
    home: &Path,
    overrides: LoaderOverrides,
) -> Result<LocalPolicy, PolicyError> {
    validate_home(home)?;
    let local_application = load_local_application_requirements(fs, &overrides)
        .with_subscriber(tracing::subscriber::NoSubscriber::default())
        .await.map_err(|_| PolicyError::Unavailable)?;
    let requirements = load_requirements(fs, home, overrides.clone(), None).await?;
    let snapshot = assemble(requirements)?;
    // Detect a source update between the bootstrap read and the full local read.
    // Never publish a looser bootstrap than the snapshot we are returning.
    let application = quietly(|| local_application.compose(Default::default()))
        .map_err(|_| PolicyError::Unavailable)?;
    if destinations(application.as_ref()) != snapshot.destinations {
        return Err(PolicyError::Superseded);
    }
    Ok(LocalPolicy { snapshot, home: home.to_path_buf(), local_application, overrides })
}

/// A cloud fetch failure is an error, never an empty bundle. The caller is
/// responsible for official plan eligibility and fetching under local bootstrap
/// policy; None means verified absence/ineligibility, not a skipped fetch.
pub async fn complete_trusted(
    fs: &dyn ExecutorFileSystem,
    home: &Path,
    local: &LocalPolicy,
    cloud: Result<Option<CloudConfigBundle>, CloudConfigBundleLoadError>,
) -> Result<PolicySnapshot, PolicyError> {
    validate_home(home)?;
    if home != local.home { return Err(PolicyError::Superseded); }
    let bundle = cloud.map_err(|_| PolicyError::CloudUnavailable)?;
    if let Some(bundle) = &bundle {
        // Validate both delivered buckets through official parsing, even though
        // config defaults do not become requirements in this policy-only helper.
        let base = codex_config::AbsolutePathBuf::from_absolute_path(home).map_err(|_| PolicyError::InvalidIdentityHome)?;
        quietly(|| CloudConfigBundleLayers::from_bundle(bundle.clone(), &base))
            .map_err(|_| PolicyError::Unavailable)?;
    }
    let expected_application = quietly(|| local.local_application.compose(
        bundle.as_ref().map(|value| value.requirements_toml.clone()).unwrap_or_default(),
    )).map_err(|_| PolicyError::Unavailable)?;
    let requirements = load_requirements(fs, home, local.overrides.clone(), bundle).await?;
    let snapshot = assemble(requirements)?;
    if destinations(expected_application.as_ref()) != snapshot.destinations {
        return Err(PolicyError::Superseded);
    }
    Ok(snapshot)
}

async fn load_requirements(
    fs: &dyn ExecutorFileSystem,
    home: &Path,
    overrides: LoaderOverrides,
    bundle: Option<CloudConfigBundle>,
) -> Result<ConfigRequirementsToml, PolicyError> {
    load_managed_requirements_state(fs, home, ConfigLoadOptions {
        loader_overrides: overrides,
        strict_config: true,
        cloud_config_bundle: CloudConfigBundleLoader::new(async move { Ok(bundle) }),
    })
    .with_subscriber(tracing::subscriber::NoSubscriber::default())
    .await.map_err(|_| PolicyError::Unavailable)
}

fn destinations(application: Option<&codex_config::ApplicationRequirementsToml>) -> DestinationPolicy {
    match application.and_then(|value| value.network.as_ref()) {
        Some(network) if network.enabled => DestinationPolicy::Restricted {
            allowed_hosts: network.domains.iter()
                .filter(|(_, permission)| **permission == NetworkDomainPermissionToml::Allow)
                .map(|(host, _)| host.clone()).collect(),
        },
        _ => DestinationPolicy::Unrestricted,
    }
}

fn quietly<T>(operation: impl FnOnce() -> T) -> T {
    tracing::subscriber::with_default(tracing::subscriber::NoSubscriber::default(), operation)
}

fn assemble(requirements: ConfigRequirementsToml) -> Result<PolicySnapshot, PolicyError> {
    // This helper cannot silently substitute another provider, auth issuer,
    // storage backend, catalog, feature protocol, or guardian policy. Fail before
    // any model request when the installed requirements demand one of these.
    if requirements.cli_auth_credentials_store.is_some_and(|mode| mode != AuthCredentialsStoreMode::Keyring)
        || requirements.chatgpt_base_url.is_some()
        || requirements.model_provider.as_deref().is_some_and(|provider| provider != "openai")
        || requirements.model_providers.as_ref().is_some_and(|providers| !providers.is_empty())
        || requirements.model_catalog_json.is_some()
        || requirements.feature_requirements.as_ref().is_some_and(|features| !features.entries.is_empty())
        || requirements.guardian_policy_config.is_some()
        || requirements.guardian_extra_policy.is_some()
        || requirements.auto_review.as_ref().and_then(|review| review.required_on_models.as_ref()).is_some_and(|models| !models.is_empty())
    {
        return Err(PolicyError::Unsupported);
    }
    // No agent/tools are started: shell, permissions, approval, exec rules,
    // sandbox/agent-network, hooks, MCP/apps/plugins, browser/computer/remote use,
    // SQLite/log/update/feedback settings have no operation to configure here.
    // Application.network is distinct from agent-network and IS enforced below.
    let new_thread = requirements.models.as_ref().and_then(|models| models.new_thread.as_ref());
    let model = ModelConstraints {
        model: new_thread.and_then(|value| value.model.clone()),
        reasoning_effort: new_thread.and_then(|value| value.model_reasoning_effort.clone()),
        service_tier: new_thread.and_then(|value| value.service_tier.clone()),
        enforce_residency: requirements.enforce_residency,
        additional_developer_instructions: requirements.additional_developer_instructions.clone(),
    };
    let destinations = destinations(requirements.application.as_ref());
    // Official normalization trims workspace IDs and preserves deny-all lists.
    let mut sourced = ConfigRequirementsWithSources::default();
    sourced.merge_unset_fields(RequirementSource::Unknown, requirements);
    let typed: ConfigRequirements = quietly(|| sourced.try_into()).map_err(|_| PolicyError::Unavailable)?;
    Ok(PolicySnapshot { managed_auth_policy: typed.managed_auth_policy(), destinations, model })
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use codex_config::{CloudRequirementsFragment, CloudConfigBundleLoadErrorCode};
    use codex_file_system::{
        CopyOptions, CreateDirectoryOptions, ExecutorFileSystemFuture, FileMetadata,
        FileSystemReadStream, FileSystemSandboxContext, GetMetadataOptions, ReadDirectoryEntry,
        ReadFileOptions, RemoveOptions, WalkOptions, WalkOutcome, WriteFileOptions,
    };
    use codex_utils_path_uri::PathUri;
    use std::collections::BTreeMap;
    use std::io;
    use std::sync::Mutex;

    fn home() -> PathBuf { PathBuf::from("/lumax-constructed-policy-only") }

    struct MemoryFileSystem {
        system: PathBuf,
        legacy: PathBuf,
        files: BTreeMap<PathBuf, Vec<u8>>,
        reads: Mutex<Vec<PathBuf>>,
        unreadable: bool,
    }
    impl MemoryFileSystem {
        fn new(system: &str) -> Self {
            let system_path = home().join("requirements.toml");
            Self {
                system: system_path.clone(), legacy: home().join("managed_config.toml"),
                files: BTreeMap::from([(system_path, system.as_bytes().to_vec())]),
                reads: Mutex::new(Vec::new()), unreadable: false,
            }
        }
        fn overrides(&self, mdm: &str) -> LoaderOverrides {
            LoaderOverrides {
                system_requirements_path: Some(self.system.clone()),
                managed_config_path: Some(self.legacy.clone()),
                #[cfg(target_os = "macos")]
                managed_preferences_base64: Some(String::new()),
                macos_managed_config_requirements_base64: Some(base64::engine::general_purpose::STANDARD.encode(mdm)),
                ..trusted_overrides()
            }
        }
    }
fn unsupported<'a, T: Send + 'a>() -> ExecutorFileSystemFuture<'a, T> {
    Box::pin(async { Err(io::Error::new(io::ErrorKind::PermissionDenied, "fixture filesystem operation denied")) })
}

impl ExecutorFileSystem for MemoryFileSystem {
    fn canonicalize<'a>(&'a self, _path: &'a PathUri, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, PathUri> { unsupported() }
    fn read_file<'a>(&'a self, path: &'a PathUri, _options: ReadFileOptions, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, Vec<u8>> {
        Box::pin(async move {
            let path = path.to_abs_path()?;
            self.reads.lock().unwrap().push(path.as_path().to_path_buf());
            if path.as_path() != self.system && path.as_path() != self.legacy {
                return Err(io::Error::new(io::ErrorKind::PermissionDenied, "unregistered fixture path"));
            }
            if self.unreadable { return Err(io::Error::new(io::ErrorKind::PermissionDenied, "private constructed error")); }
            self.files.get(path.as_path()).cloned().ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
        })
    }
    fn read_file_stream<'a>(&'a self, _path: &'a PathUri, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, FileSystemReadStream> { unsupported() }
    fn write_file<'a>(&'a self, _path: &'a PathUri, _contents: Vec<u8>, _options: WriteFileOptions, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, ()> { unsupported() }
    fn create_directory<'a>(&'a self, _path: &'a PathUri, _options: CreateDirectoryOptions, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, ()> { unsupported() }
    fn get_metadata<'a>(&'a self, _path: &'a PathUri, _options: GetMetadataOptions, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, FileMetadata> { unsupported() }
    fn read_directory<'a>(&'a self, _path: &'a PathUri, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, Vec<ReadDirectoryEntry>> { unsupported() }
    fn walk<'a>(&'a self, _path: &'a PathUri, _options: WalkOptions, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, WalkOutcome> { unsupported() }
    fn remove<'a>(&'a self, _path: &'a PathUri, _options: RemoveOptions, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, ()> { unsupported() }
    fn copy<'a>(&'a self, _source: &'a PathUri, _destination: &'a PathUri, _options: CopyOptions, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, ()> { unsupported() }
}

    async fn local(fs: &MemoryFileSystem, mdm: &str) -> Result<LocalPolicy, PolicyError> {
        load_local_with_overrides(fs, &home(), fs.overrides(mdm)).await
    }
    fn bundle(requirements: &str) -> CloudConfigBundle {
        let mut result = CloudConfigBundle::default();
        result.requirements_toml.enterprise_managed.push(CloudRequirementsFragment {
            id: "constructed".into(), name: "constructed".into(), contents: requirements.into(),
        });
        result
    }
    fn auth(snapshot: &PolicySnapshot) -> Result<AuthConfig, PolicyError> {
        snapshot.auth_config(home(), AuthRouteConfig::from_http_client_factory(
            codex_http_client::HttpClientFactory::new(codex_http_client::OutboundProxyPolicy::ReqwestDefault),
        ))
    }

    #[test]
    fn production_overrides_preserve_real_managed_sources() {
        let options = trusted_overrides();
        assert!(!options.ignore_managed_requirements && !options.ignore_login_requirements);
        assert!(options.ignore_user_config && options.ignore_project_config);
        assert!(options.system_requirements_path.is_none() && options.managed_config_path.is_none());
        #[cfg(target_os = "macos")]
        assert!(options.managed_preferences_base64.is_none());
        assert!(options.macos_managed_config_requirements_base64.is_none());
    }

    #[tokio::test]
    async fn strict_auth_configuration_preserves_denials_and_normalizes_workspaces() {
        for source in ["allowed_login_methods=['api']", "allowed_login_methods=[]"] {
            let snapshot = local(&MemoryFileSystem::new(source), "").await.unwrap().snapshot;
            assert_eq!(auth(&snapshot).unwrap_err(), PolicyError::AuthenticationDenied);
        }
        let loaded = local(&MemoryFileSystem::new("allowed_chatgpt_workspaces=['  workspace  ', '']"), "").await.unwrap();
        let config = auth(&loaded.snapshot).unwrap();
        assert_eq!(config.auth_credentials_store_mode, AuthCredentialsStoreMode::Keyring);
        assert_eq!(config.keyring_backend_kind, AuthKeyringBackendKind::Direct);
        assert!(config.chatgpt_base_url.is_none());
        assert_eq!(config.effective_chatgpt_workspaces(), Some(vec!["workspace".into()]));
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn forced_mdm_overrides_system_and_cloud_cannot_replace_local_auth() {
        let fs = MemoryFileSystem::new("allowed_login_methods=['api']");
        let loaded = local(&fs, "allowed_login_methods=['chatgpt']\nallowed_chatgpt_workspaces=['managed']").await.unwrap();
        let final_policy = complete_trusted(&fs, &home(), &loaded, Ok(Some(bundle(
            "allowed_login_methods=['api']\nallowed_chatgpt_workspaces=['other']\ncli_auth_credentials_store='file'\nchatgpt_base_url='https://not-used.invalid'"
        )))).await.unwrap();
        let config = auth(&final_policy).unwrap();
        assert_eq!(config.effective_chatgpt_workspaces(), Some(vec!["managed".into()]));
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn malformed_forced_mdm_fails_and_cloud_cannot_loosen_mdm_network() {
        let fs = MemoryFileSystem::new("");
        let mut invalid = fs.overrides("");
        invalid.macos_managed_config_requirements_base64 = Some("invalid-base64!".into());
        assert_eq!(load_local_with_overrides(&fs, &home(), invalid).await.unwrap_err(), PolicyError::Unavailable);
        let loaded = local(&fs, "[application.network]\nenabled=true").await.unwrap();
        let final_policy = complete_trusted(&fs, &home(), &loaded, Ok(Some(bundle(
            "[application.network]\nenabled=false"
        )))).await.unwrap();
        let controller = NetworkPolicyController::default();
        let policy = final_policy.publish(&controller, controller.policy().revision()).unwrap();
        assert!(policy.acquire(&"https://allowed.example".parse().unwrap()).is_err());
    }

    #[tokio::test]
    async fn cloud_network_is_composed_before_final_publication() {
        let fs = MemoryFileSystem::new("");
        let loaded = local(&fs, "").await.unwrap();
        let final_policy = complete_trusted(&fs, &home(), &loaded, Ok(Some(bundle(
            "[application.network]\nenabled=true\n[application.network.domains]\n'Allowed.Example.'='allow'\n'blocked.example'='deny'"
        )))).await.unwrap();
        let controller = NetworkPolicyController::default();
        let revision = controller.policy().revision();
        assert!(controller.policy().acquire(&"https://allowed.example".parse().unwrap()).is_err());
        let policy = final_policy.publish(&controller, revision).unwrap();
        for (url, expected) in [("https://allowed.example", true), ("http://allowed.example", false),
                                ("https://blocked.example", false), ("https://other.example", false)] {
            assert_eq!(policy.acquire(&url.parse().unwrap()).is_ok(), expected);
        }
        policy.invalidate();
        assert_eq!(final_policy.publish(&controller, revision).unwrap_err(), PolicyError::Superseded);
    }

    #[tokio::test]
    async fn model_residency_and_managed_instructions_are_retained_and_debug_is_safe() {
        let fs = MemoryFileSystem::new("enforce_residency='us'\nadditional_developer_instructions='constructed-private-instruction'\n[models.new_thread]\nmodel='required-model'\nmodel_reasoning_effort='low'\nservice_tier='fast'");
        let loaded = local(&fs, "").await.unwrap();
        let final_policy = complete_trusted(&fs, &home(), &loaded, Ok(None)).await.unwrap();
        assert_eq!(final_policy.model.model.as_deref(), Some("required-model"));
        assert_eq!(final_policy.model.reasoning_effort, Some(ReasoningEffort::Low));
        assert_eq!(final_policy.model.service_tier.as_deref(), Some("fast"));
        assert_eq!(final_policy.model.enforce_residency, Some(ResidencyRequirement::Us));
        assert_eq!(final_policy.model.additional_developer_instructions.as_deref(), Some("constructed-private-instruction"));
        assert!(!format!("{final_policy:?} {:?}", final_policy.model).contains("constructed-private"));
    }

    #[tokio::test]
    async fn unsupported_material_requirements_fail_instead_of_being_dropped() {
        for source in ["cli_auth_credentials_store='file'", "chatgpt_base_url='https://private.invalid'",
                       "model_provider='custom'", "model_catalog_json='/private/catalog.json'",
                       "guardian_policy_config='constructed-private-policy'"] {
            assert_eq!(local(&MemoryFileSystem::new(source), "").await.unwrap_err(), PolicyError::Unsupported);
        }
        assert!(local(&MemoryFileSystem::new("model_provider='openai'"), "").await.is_ok());
    }

    #[tokio::test]
    async fn tool_only_restrictions_do_not_require_starting_an_agent() {
        let fs = MemoryFileSystem::new("allowed_approval_policies=['never']\nallowed_sandbox_modes=['read-only']\nallow_browser_and_computer_use=false\nallow_remote_control=false");
        assert!(local(&fs, "").await.is_ok());
    }

    #[tokio::test]
    async fn absent_sources_are_distinct_from_read_or_parse_failures() {
        let mut missing = MemoryFileSystem::new("");
        missing.files.clear();
        assert!(local(&missing, "").await.is_ok());
        missing.unreadable = true;
        assert_eq!(local(&missing, "").await.unwrap_err(), PolicyError::Unavailable);
        let invalid = MemoryFileSystem::new("allowed_login_methods=[private-invalid");
        assert_eq!(local(&invalid, "").await.unwrap_err(), PolicyError::Unavailable);
        let error = local(&invalid, "").await.unwrap_err();
        assert!(!format!("{error:?} {error}").contains("private-invalid"));
    }

    #[tokio::test]
    async fn cloud_failure_or_bad_bundle_does_not_publish_empty_policy() {
        let fs = MemoryFileSystem::new("");
        let loaded = local(&fs, "").await.unwrap();
        let failure = CloudConfigBundleLoadError::new(CloudConfigBundleLoadErrorCode::RequestFailed, Some(500), "private-response");
        assert_eq!(complete_trusted(&fs, &home(), &loaded, Err(failure)).await.unwrap_err(), PolicyError::CloudUnavailable);
        assert_eq!(complete_trusted(&fs, &home(), &loaded, Ok(Some(bundle("[invalid-private")))).await.unwrap_err(), PolicyError::Unavailable);
        assert_eq!(complete_trusted(&fs, Path::new("/other-home"), &loaded, Ok(None)).await.unwrap_err(), PolicyError::Superseded);
    }

    #[tokio::test]
    async fn changed_local_network_between_bootstrap_and_completion_is_rejected() {
        let mut fs = MemoryFileSystem::new("");
        let loaded = local(&fs, "").await.unwrap();
        fs.files.insert(fs.system.clone(), b"[application.network]\nenabled=true".to_vec());
        assert_eq!(complete_trusted(&fs, &home(), &loaded, Ok(None)).await.unwrap_err(), PolicyError::Superseded);
    }

    #[tokio::test]
    async fn reads_are_limited_to_registered_managed_sources() {
        let fs = MemoryFileSystem::new("");
        let loaded = local(&fs, "").await.unwrap();
        complete_trusted(&fs, &home(), &loaded, Ok(None)).await.unwrap();
        let reads = fs.reads.lock().unwrap();
        assert!(!reads.is_empty());
        assert!(reads.iter().all(|path| path == &fs.system || path == &fs.legacy));
        assert!(!reads.iter().any(|path| path.ends_with("auth.json") || path.ends_with("config.toml")));
    }
}

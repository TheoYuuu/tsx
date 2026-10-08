//! Fixture-only assembly through the pinned official managed-requirements loader.
//! No entry point here reads a host file, MDM preferences, auth, or Keychain.
//! Production must supply real trusted sources and own reload/account invalidation;
//! successful fixtures are not evidence that those production sources are wired.

use base64::Engine;
use codex_config::loader::load_managed_requirements_state;
use codex_config::{
    CloudConfigBundle, CloudConfigBundleLoadError, CloudConfigBundleLoadErrorCode,
    CloudConfigBundleLoader, CloudRequirementsFragment, ConfigLoadOptions, ConfigRequirements,
    ConfigRequirementsToml, ConfigRequirementsWithSources, LoaderOverrides, ManagedAuthPolicy,
    NetworkDomainPermissionToml, RequirementSource,
};
use codex_file_system::{
    CopyOptions, CreateDirectoryOptions, ExecutorFileSystem, ExecutorFileSystemFuture,
    FileMetadata, FileSystemReadStream, FileSystemSandboxContext, GetMetadataOptions,
    ReadDirectoryEntry, ReadFileOptions, RemoveOptions, WalkOptions, WalkOutcome, WriteFileOptions,
};
use codex_http_client::{DestinationPolicy, NetworkPolicy, NetworkPolicyController};
use codex_login::{AuthConfig, AuthCredentialsStoreMode, AuthKeyringBackendKind, AuthRouteConfig};
use codex_protocol::config_types::ForcedLoginMethod;
use codex_utils_path_uri::PathUri;
use std::collections::BTreeMap;
use std::fmt;
use std::io;
use std::path::{Component, Path, PathBuf};
use tracing::instrument::WithSubscriber;

pub struct PolicySnapshot {
    managed_auth_policy: ManagedAuthPolicy,
    destinations: DestinationPolicy,
}

impl fmt::Debug for PolicySnapshot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("PolicySnapshot").finish_non_exhaustive()
    }
}

impl PolicySnapshot {
    /// Assembly only: the caller must validate this config before login and use
    /// its restrictions again when accepting an authenticated identity.
    pub fn auth_config(
        &self,
        home: PathBuf,
        issuer: Option<String>,
        route: AuthRouteConfig,
    ) -> AuthConfig {
        AuthConfig {
            codex_home: home,
            auth_credentials_store_mode: AuthCredentialsStoreMode::Keyring,
            keyring_backend_kind: AuthKeyringBackendKind::Direct,
            forced_login_method: Some(ForcedLoginMethod::Chatgpt),
            chatgpt_base_url: issuer,
            forced_chatgpt_workspace_id: None,
            managed_auth_policy: self.managed_auth_policy.clone(),
            auth_route_config: route,
        }
    }

    /// The returned official policy can be narrowed with restrict_to_endpoints
    /// and passed to HttpClientFactory::with_network_policy. The owner retains
    /// the controller and invalidates policy on account change/load failure.
    pub fn install_network_policy(
        &self,
        controller: &NetworkPolicyController,
    ) -> Result<NetworkPolicy, &'static str> {
        let policy = controller.policy();
        if !controller.publish(policy.revision(), self.destinations.clone()) {
            return Err("managed_policy_superseded");
        }
        Ok(policy)
    }
}

/// All policy documents are constructed in memory. `home` is a path namespace,
/// not a filesystem to inspect; no environment-derived defaults are used.
pub async fn load_fixture(
    case: &str,
    home: &Path,
    workspace: Option<&str>,
) -> Result<PolicySnapshot, &'static str> {
    if !home.is_absolute()
        || home.components().any(|part| matches!(part, Component::ParentDir | Component::CurDir))
    {
        return Err("invalid_policy_fixture_home");
    }
    let mut system = String::new();
    let mut mdm = String::new();
    let mut cloud = CloudConfigBundle::default();
    let mut cloud_failure = false;
    match case {
        "default" => {}
        "api_only" => system = "allowed_login_methods = ['api']".into(),
        "chatgpt_only" => system = "allowed_login_methods = ['chatgpt']".into(),
        "denied" => system = "allowed_login_methods = []".into(),
        "workspace_allowed" | "workspace_mismatch" => {
            let workspace = workspace.filter(|value| !value.is_empty() && value.len() <= 256
                && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte)))
                .ok_or("invalid_policy_fixture_workspace")?;
            let expected = if case == "workspace_mismatch" {
                format!("other-{workspace}")
            } else {
                workspace.to_string()
            };
            system = format!("allowed_login_methods = ['chatgpt']\nallowed_chatgpt_workspaces = ['  {expected}  ']");
        }
        "malformed" => system = "allowed_login_methods = [".into(),
        "malformed_mdm" => mdm = "invalid-base64!".into(),
        "mdm_overrides_system" => {
            system = "allowed_login_methods = ['api']".into();
            mdm = encode_mdm("allowed_login_methods = ['chatgpt']");
        }
        "mdm_denies_system" => {
            system = "allowed_login_methods = ['chatgpt']".into();
            mdm = encode_mdm("allowed_login_methods = []");
        }
        "cloud_auth_ignored" => {
            system = "allowed_login_methods = ['chatgpt']".into();
            cloud.requirements_toml.enterprise_managed.push(cloud_fragment(
                "allowed_login_methods = ['api']\nallowed_chatgpt_workspaces = []"));
        }
        "network_restricted" => system = restricted_network(),
        "network_deny_all" => system = "[application.network]\nenabled = true".into(),
        "network_disabled" => system = "[application.network]\nenabled = false".into(),
        "cloud_network" => cloud.requirements_toml.enterprise_managed.push(cloud_fragment(&restricted_network())),
        "malformed_network" => system = "[application.network.domains]\n'https://private.invalid/' = 'allow'".into(),
        "cloud_error" => cloud_failure = true,
        "unsupported_file_store" => system = "cli_auth_credentials_store = 'file'".into(),
        _ => return Err("unknown_policy_fixture"),
    }
    let fs = FixtureFileSystem::new(home, system.into_bytes());
    // Some("") is significant: None would read real macOS managed preferences.
    let overrides = LoaderOverrides {
        system_requirements_path: Some(fs.system.clone()),
        managed_config_path: Some(fs.legacy.clone()),
        system_config_path: Some(home.join("unused-system-config.toml")),
        ignore_managed_requirements: false,
        ignore_login_requirements: false,
        ignore_user_config: true,
        ignore_project_config: true,
        #[cfg(target_os = "macos")]
        managed_preferences_base64: Some(String::new()),
        macos_managed_config_requirements_base64: Some(mdm),
        ..Default::default()
    };
    let options = ConfigLoadOptions {
        loader_overrides: overrides,
        strict_config: true,
        cloud_config_bundle: CloudConfigBundleLoader::new(async move {
            if cloud_failure {
                Err(CloudConfigBundleLoadError::new(
                    CloudConfigBundleLoadErrorCode::RequestFailed, None,
                    "constructed-private-policy-error"))
            } else {
                Ok(Some(cloud))
            }
        }),
    };
    // Upstream parse diagnostics may contain source text. Never install a global
    // subscriber; suppress diagnostics only while polling this loader future.
    let requirements = load_managed_requirements_state(&fs, home, options)
        .with_subscriber(tracing::subscriber::NoSubscriber::default())
        .await
        .map_err(|_| "managed_policy_unavailable")?;
    assemble(requirements)
}

fn assemble(requirements: ConfigRequirementsToml) -> Result<PolicySnapshot, &'static str> {
    // This QA component always uses Keyring/Direct. Fail instead of ignoring a
    // conflicting required store; other production requirements need explicit
    // integration before exposing a general host-policy loader.
    if requirements.cli_auth_credentials_store.is_some_and(|mode| mode != AuthCredentialsStoreMode::Keyring)
        || requirements.chatgpt_base_url.is_some()
        || requirements.model_provider.is_some()
        || requirements.model_providers.is_some()
        || requirements.feature_requirements.is_some()
    {
        return Err("unsupported_managed_policy");
    }
    let destinations = match requirements.application.as_ref().and_then(|value| value.network.as_ref()) {
        Some(network) if network.enabled => DestinationPolicy::Restricted {
            allowed_hosts: network.domains.iter()
                .filter(|(_, permission)| **permission == NetworkDomainPermissionToml::Allow)
                .map(|(host, _)| host.clone()).collect(),
        },
        _ => DestinationPolicy::Unrestricted,
    };
    // Use the official conversion and normalization, including trimming and
    // removal of blank workspace IDs. Do not reimplement its matching rules.
    let mut sourced = ConfigRequirementsWithSources::default();
    sourced.merge_unset_fields(RequirementSource::Unknown, requirements);
    let typed: ConfigRequirements = sourced.try_into().map_err(|_| "managed_policy_unavailable")?;
    Ok(PolicySnapshot { managed_auth_policy: typed.managed_auth_policy(), destinations })
}

fn encode_mdm(contents: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(contents)
}

fn cloud_fragment(contents: &str) -> CloudRequirementsFragment {
    CloudRequirementsFragment { id: "fixture".into(), name: "fixture".into(), contents: contents.into() }
}

fn restricted_network() -> String {
    "[application.network]\nenabled = true\n[application.network.domains]\n'Allowed.Example.' = 'allow'\n'blocked.example' = 'deny'".into()
}

struct FixtureFileSystem {
    system: PathBuf,
    legacy: PathBuf,
    files: BTreeMap<PathBuf, Vec<u8>>,
}

impl FixtureFileSystem {
    fn new(home: &Path, requirements: Vec<u8>) -> Self {
        let system = home.join("fixture-requirements.toml");
        let legacy = home.join("fixture-managed-config.toml");
        Self { files: BTreeMap::from([(system.clone(), requirements), (legacy.clone(), Vec::new())]), system, legacy }
    }
}

fn unsupported<'a, T: Send + 'a>() -> ExecutorFileSystemFuture<'a, T> {
    Box::pin(async { Err(io::Error::new(io::ErrorKind::PermissionDenied, "fixture filesystem operation denied")) })
}

impl ExecutorFileSystem for FixtureFileSystem {
    fn canonicalize<'a>(&'a self, _path: &'a PathUri, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, PathUri> { unsupported() }
    fn read_file<'a>(&'a self, path: &'a PathUri, _options: ReadFileOptions, _sandbox: Option<&'a FileSystemSandboxContext>) -> ExecutorFileSystemFuture<'a, Vec<u8>> {
        Box::pin(async move {
            let path = path.to_abs_path()?;
            self.files.get(path.as_path()).cloned().ok_or_else(|| io::Error::new(io::ErrorKind::PermissionDenied, "fixture path denied"))
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

#[cfg(test)]
mod tests {
    use super::*;
    use url::Url;

    fn home() -> PathBuf { PathBuf::from("/translatex-in-memory-policy-fixture") }
    fn auth(snapshot: &PolicySnapshot) -> AuthConfig {
        let factory = codex_http_client::HttpClientFactory::new(codex_http_client::OutboundProxyPolicy::ReqwestDefault);
        snapshot.auth_config(home(), None, AuthRouteConfig::from_http_client_factory(factory))
    }

    #[tokio::test]
    async fn official_loader_enforces_login_methods() {
        for (case, allowed) in [("default", true), ("chatgpt_only", true), ("api_only", false), ("denied", false)] {
            let snapshot = load_fixture(case, &home(), None).await.unwrap();
            assert_eq!(auth(&snapshot).validate().is_ok(), allowed, "{case}");
        }
    }

    #[tokio::test]
    async fn official_workspace_normalization_and_mismatch_are_preserved() {
        let allowed = load_fixture("workspace_allowed", &home(), Some("fixture-workspace")).await.unwrap();
        assert_eq!(auth(&allowed).effective_chatgpt_workspaces(), Some(vec!["fixture-workspace".into()]));
        let different = load_fixture("workspace_mismatch", &home(), Some("fixture-workspace")).await.unwrap();
        assert_eq!(auth(&different).effective_chatgpt_workspaces(), Some(vec!["other-fixture-workspace".into()]));
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn official_mdm_fixture_precedence_is_applied_without_host_reads() {
        assert!(auth(&load_fixture("mdm_overrides_system", &home(), None).await.unwrap()).validate().is_ok());
        assert!(auth(&load_fixture("mdm_denies_system", &home(), None).await.unwrap()).validate().is_err());
    }

    #[tokio::test]
    async fn official_cloud_layer_cannot_replace_local_auth_constraints() {
        let snapshot = load_fixture("cloud_auth_ignored", &home(), None).await.unwrap();
        assert!(auth(&snapshot).validate().is_ok());
        assert_eq!(auth(&snapshot).effective_chatgpt_workspaces(), None);
    }

    #[tokio::test]
    async fn official_network_permits_require_allowed_https_destinations() {
        for case in ["network_restricted", "cloud_network"] {
            let snapshot = load_fixture(case, &home(), None).await.unwrap();
            let controller = NetworkPolicyController::default();
            let policy = snapshot.install_network_policy(&controller).unwrap();
            for (url, allowed) in [("https://allowed.example/path", true), ("https://blocked.example", false),
                ("https://unlisted.example", false), ("http://allowed.example", false)] {
                assert_eq!(policy.acquire(&Url::parse(url).unwrap()).is_ok(), allowed);
            }
            let permit = policy.acquire(&Url::parse("https://allowed.example").unwrap()).unwrap();
            policy.invalidate();
            assert!(permit.check().is_err());
        }
    }

    #[tokio::test]
    async fn enabled_empty_network_denies_and_disabled_network_allows() {
        for (case, allowed) in [("network_deny_all", false), ("network_disabled", true)] {
            let snapshot = load_fixture(case, &home(), None).await.unwrap();
            let policy = snapshot.install_network_policy(&NetworkPolicyController::default()).unwrap();
            assert_eq!(policy.acquire(&Url::parse("https://unlisted.example").unwrap()).is_ok(), allowed);
        }
    }

    #[tokio::test]
    async fn errors_are_fixed_and_never_return_policy_contents() {
        for case in ["malformed", "malformed_network", "cloud_error"] {
            assert_eq!(load_fixture(case, &home(), None).await.unwrap_err(), "managed_policy_unavailable");
        }
        #[cfg(target_os = "macos")]
        assert_eq!(load_fixture("malformed_mdm", &home(), None).await.unwrap_err(), "managed_policy_unavailable");
        assert_eq!(load_fixture("unsupported_file_store", &home(), None).await.unwrap_err(), "unsupported_managed_policy");
        assert_eq!(load_fixture("unrecognized", &home(), None).await.unwrap_err(), "unknown_policy_fixture");
    }

    #[tokio::test]
    async fn fixture_filesystem_rejects_every_unregistered_read_and_write() {
        let fs = FixtureFileSystem::new(&home(), Vec::new());
        let path = PathUri::from_abs_path(&codex_config::AbsolutePathBuf::from_absolute_path(home().join("auth.json")).unwrap());
        assert_eq!(fs.read_file(&path, Default::default(), None).await.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(fs.write_file(&path, Vec::new(), Default::default(), None).await.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
    }
}

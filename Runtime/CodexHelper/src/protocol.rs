//! Bounded, credential-free stdio protocol for one native operation.
use serde::{Deserialize, Serialize};
use std::io::{self, BufRead};
use std::path::PathBuf;
use uuid::Uuid;

pub const VERSION: u8 = 1;
pub const MAX_INPUT_LINE: usize = 512 * 1024;
pub const MAX_CONTROL_LINE: usize = 4096;
pub const MAX_OUTPUT: usize = 4 * 1024 * 1024;
pub const VERIFICATION_URL: &str = "https://auth.openai.com/codex/device";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation { Status, Login, Logout, Models, Translate }

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub protocol_version: u8,
    pub request_id: String,
    pub operation: Operation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_generation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_language: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_language: Option<String>,
}

pub fn canonical_uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|uuid| !uuid.is_nil() && uuid.to_string() == value)
}

impl Request {
    pub fn valid(&self) -> bool {
        if self.protocol_version != VERSION || !canonical_uuid(&self.request_id) { return false; }
        match self.operation {
            Operation::Models | Operation::Translate => {
                if !self.expected_generation.as_ref().is_some_and(|value| canonical_uuid(value)) { return false; }
            }
            Operation::Logout => {
                if self.expected_generation.as_ref().is_some_and(|value| !canonical_uuid(value)) { return false; }
            }
            Operation::Status | Operation::Login => if self.expected_generation.is_some() { return false; },
        }
        if self.operation != Operation::Translate {
            return self.model.is_none() && self.text.is_none()
                && self.source_language.is_none() && self.target_language.is_none();
        }
        self.model.as_ref().is_some_and(|value| safe_label(value, 256))
            && self.text.as_ref().is_some_and(|value| !value.trim().is_empty() && value.len() <= crate::translation::MAX_INPUT)
            && self.target_language.as_ref().is_some_and(|value| language(value))
            && self.source_language.as_ref().is_none_or(|value| language(value))
    }
}

fn language(value: &str) -> bool {
    !value.is_empty() && value.len() <= 63 && value.split('-')
        .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_alphanumeric()))
}
pub fn safe_label(value: &str, limit: usize) -> bool {
    !value.trim().is_empty() && value.len() <= limit && !value.chars().any(char::is_control)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Control { pub protocol_version: u8, pub request_id: String, pub action: String }
impl Control {
    pub fn cancels(&self, request: &Request) -> bool {
        self.protocol_version == VERSION && self.request_id == request.request_id && self.action == "cancel"
    }
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ModelSummary {
    pub id: String,
    pub name: String,
    pub reasoning_efforts: Vec<String>,
    pub default_reasoning_effort: Option<String>,
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Outcome {
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub models: Option<Vec<ModelSummary>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_plan: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_revocation: Option<String>,
}

pub const TERMINAL_STATUSES: &[&str] = &[
    "ok", "signed_in", "signed_out", "cancelled", "timeout", "invalid_input",
    "environment_rejected", "storage_unavailable", "invalid_account_storage", "busy",
    "already_signed_in", "recovery_required", "cleanup_required", "login_unavailable",
    "login_failed", "authentication_failed", "network_unavailable", "managed_policy_denied",
    "model_unavailable", "request_failed", "rate_limited", "access_denied", "redirect_rejected", "account_changed",
];

impl Outcome {
    pub fn new(status: &str) -> Self { Self { status: status.to_string(), ..Default::default() } }
    /// Only known static codes cross the boundary. Never forward Display/debug
    /// strings from an upstream network, credential, parser, or filesystem error.
    pub fn error(code: &str) -> Self {
        let status = match code {
            value if TERMINAL_STATUSES.contains(&value) => value,
            "identity_busy" => "busy",
            "invalid_identity_home" | "invalid_operation" => "invalid_account_storage",
            "managed_policy_unavailable" | "managed_cloud_policy_unavailable" |
            "unsupported_managed_policy" | "managed_policy_superseded" | "managed_auth_denied" |
            "network_policy_denied" | "managed_network_denied" | "managed_model_mismatch" |
            "managed_reasoning_unavailable" | "managed_service_tier_unavailable" => "managed_policy_denied",
            "device_code_failed" => "login_unavailable",
            value if value.starts_with("refresh_") || value.starts_with("identity_")
                || value.starts_with("workspace_") || value.starts_with("authentication_")
                || value == "unexpected_auth_method" || value == "account_plan_unavailable" => "authentication_failed",
            value if value.starts_with("model_") || value.starts_with("catalog_") => "model_unavailable",
            "network_timeout" => "timeout",
            "network_failed" | "service_unavailable" | "unavailable" => "network_unavailable",
            "unauthorized" => "authentication_failed",
            _ => "request_failed",
        };
        Self::new(status)
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Event {
    pub protocol_version: u8,
    pub request_id: String,
    pub event: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verification_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Outcome>,
}
impl Event {
    pub fn ready(request: &Request, user_code: String, verification_url: String) -> Self {
        Self { protocol_version: VERSION, request_id: request.request_id.clone(), event: "ready".into(),
            user_code: Some(user_code), verification_url: Some(verification_url), result: None }
    }
    pub fn committing(request: &Request) -> Self {
        Self { protocol_version: VERSION, request_id: request.request_id.clone(), event: "committing".into(),
            user_code: None, verification_url: None, result: None }
    }
    pub fn terminal(request: &Request, result: Outcome) -> Self {
        Self { protocol_version: VERSION, request_id: request.request_id.clone(), event: "terminal".into(),
            user_code: None, verification_url: None, result: Some(result) }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerCommand { Status, Login, Logout, Cleanup, Models, Translate }
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WorkerInput {
    pub request: Request,
    pub identity_home: PathBuf,
    pub command: WorkerCommand,
}

/// Keeps the same reader alive so bytes buffered after the initial line remain
/// available to the control reader. EOF before LF is a truncated frame.
pub fn read_bounded_line(reader: &mut impl BufRead, limit: usize) -> io::Result<Option<Vec<u8>>> {
    let mut bytes = Vec::new();
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return if bytes.is_empty() { Ok(None) } else { Err(io::Error::other("truncated_frame")) };
        }
        let count = available.iter().position(|byte| *byte == b'\n').map_or(available.len(), |at| at + 1);
        if count > limit.saturating_sub(bytes.len()) { return Err(io::Error::other("frame_too_large")); }
        bytes.extend_from_slice(&available[..count]); reader.consume(count);
        if bytes.last() == Some(&b'\n') { bytes.pop(); return Ok(Some(bytes)); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn truncated_and_oversized_frames_fail_without_consuming_next_control() {
        let mut input = io::Cursor::new(b"first\nsecond\n");
        assert_eq!(read_bounded_line(&mut input, 6).unwrap().unwrap(), b"first");
        assert_eq!(read_bounded_line(&mut input, 7).unwrap().unwrap(), b"second");
        assert!(read_bounded_line(&mut io::Cursor::new(b"partial"), 20).is_err());
        assert!(read_bounded_line(&mut io::Cursor::new(b"longer\n"), 6).is_err());
    }
    #[test]
    fn unknown_fields_and_unrelated_text_are_not_accepted() {
        let base = serde_json::json!({"protocol_version":1,"request_id":Uuid::new_v4().to_string(),"operation":"status"});
        let mut value = base.clone(); value["issuer"] = "https://constructed.invalid".into();
        assert!(serde_json::from_value::<Request>(value).is_err());
        let mut value = base; value["text"] = "unrequested text".into();
        assert!(!serde_json::from_value::<Request>(value).unwrap().valid());
    }
    #[test]
    fn error_details_cannot_cross_the_wire() {
        let result = Outcome::error("private-body-token-example");
        assert_eq!(serde_json::to_value(result).unwrap(), serde_json::json!({"status":"request_failed"}));
    }
    #[test]
    fn content_requests_require_a_canonical_account_generation() {
        let mut value = serde_json::json!({"protocol_version":1,"request_id":Uuid::new_v4().to_string(),"operation":"models"});
        assert!(!serde_json::from_value::<Request>(value.clone()).unwrap().valid());
        value["expected_generation"] = Uuid::new_v4().to_string().into();
        assert!(serde_json::from_value::<Request>(value.clone()).unwrap().valid());
        value["operation"] = "status".into();
        assert!(!serde_json::from_value::<Request>(value.clone()).unwrap().valid());
        value["operation"] = "logout".into();
        assert!(serde_json::from_value::<Request>(value.clone()).unwrap().valid());
        value["expected_generation"] = Uuid::nil().to_string().into();
        assert!(!serde_json::from_value::<Request>(value).unwrap().valid());
    }
}

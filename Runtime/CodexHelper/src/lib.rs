//! TranslateX-owned account and single-request runtime over pinned official Codex libraries.
//! No agent loop, global subscriber, user Codex home, or implicit API-key fallback.
//! The native supervisor owns process cancellation and identity-generation leases.
pub mod account_request;
pub mod account_storage;
pub mod connection;
pub mod host;
pub mod network;
pub mod policy;
pub mod protocol;
pub mod routing;
pub mod supervisor;
pub mod translation;
pub mod worker;
mod sse_guard;

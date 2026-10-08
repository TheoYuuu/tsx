//! Original no-account, loopback-only translation probe. Not a product runtime.
mod translation;
mod sse_guard;
use codex_api::AuthProvider;
use http::HeaderMap;
use serde_json::json;
use std::{io::Read, sync::Arc};

struct NoAuth;
impl AuthProvider for NoAuth { fn add_auth_headers(&self, _: &mut HeaderMap) {} }

#[tokio::main]
async fn main() {
    let mut bytes=Vec::new(); std::io::stdin().take(65537).read_to_end(&mut bytes).unwrap();
    let result=if bytes.len()>65536 {json!({"status":"invalid_input"})} else {match serde_json::from_slice(&bytes) {Ok(value)=>translation::run(value, Arc::new(NoAuth)).await,Err(_)=>json!({"status":"invalid_input"})}};
    println!("{}",result);
}

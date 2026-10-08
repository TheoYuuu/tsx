//! One-shot HTTP operations using the pinned official proxy resolver and policy.
//! No request, response, URL, credential, or upstream error is logged here.

use codex_api::SharedAuthProvider;
use codex_http_client::{
    ByteStream, HttpClient, HttpClientFactory, HttpTransport, NetworkPermit,
    OutboundProxyRoute, Request, ReqwestTransport, Response, StreamResponse,
    TransportError, build_reqwest_client_with_custom_ca,
};
use futures::{StreamExt, stream};
use http::{HeaderMap, Method, header::AUTHORIZATION};
use serde::de::DeserializeOwned;
use std::{fmt, sync::{Arc, atomic::{AtomicUsize, Ordering}}, time::Duration};
use tokio::time::{Instant, timeout_at};
use url::Url;

const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const MAX_DEADLINE: Duration = Duration::from_secs(120);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NetworkError(&'static str);

impl NetworkError {
    pub fn status(self) -> &'static str { self.0 }
}

impl fmt::Display for NetworkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for NetworkError {}

fn safe_error(error: TransportError) -> NetworkError {
    NetworkError(match error {
        TransportError::Policy(_) => "network_policy_denied",
        TransportError::Timeout => "network_timeout",
        TransportError::ResponseTooLarge { .. } => "response_too_large",
        TransportError::RetryLimit => "request_already_attempted",
        TransportError::Http { status, .. } => match status.as_u16() {
            401 => "authentication_failed",
            403 => "access_denied",
            429 => "rate_limited",
            300..=399 => "redirect_rejected",
            500..=599 => "service_unavailable",
            _ => "http_error",
        },
        _ => "network_failed",
    })
}

fn sanitized(error: TransportError) -> TransportError {
    match error {
        TransportError::Policy(_)
        | TransportError::Timeout
        | TransportError::RetryLimit
        | TransportError::ResponseTooLarge { .. } => error,
        TransportError::Http { status, .. } => TransportError::Http {
            status, url: None, headers: None, body: None,
        },
        _ => TransportError::Network("network_failed".into()),
    }
}

fn valid_destination(url: &Url) -> bool {
    let secure = url.scheme() == "https";
    #[cfg(any(test, feature = "qa-fixtures"))]
    let loopback = url.scheme() == "http" && url.host_str() == Some("127.0.0.1")
        && url.port().is_some();
    #[cfg(not(any(test, feature = "qa-fixtures")))]
    let loopback = false;
    (secure || loopback) && url.host_str().is_some() && url.username().is_empty()
        && url.password().is_none() && url.fragment().is_none()
}

/// Each instance and all its clones share one attempt, including failed attempts.
/// A fresh instance is required for a separate metadata GET or model POST.
#[derive(Clone)]
pub struct StrictTransport {
    factory: HttpClientFactory,
    url: Url,
    method: Method,
    deadline: Duration,
    max_body: usize,
    attempts: Arc<AtomicUsize>,
}

impl StrictTransport {
    pub fn new(
        factory: HttpClientFactory,
        url: Url,
        method: Method,
        deadline: Duration,
        max_body: usize,
    ) -> Result<Self, NetworkError> {
        if !valid_destination(&url) || !matches!(method, Method::GET | Method::POST)
            || deadline.is_zero() || deadline > MAX_DEADLINE
            || max_body == 0 || max_body > MAX_RESPONSE_BYTES
        {
            return Err(NetworkError("invalid_network_request"));
        }
        if !factory.network_policy().is_managed() {
            return Err(NetworkError("network_policy_required"));
        }
        Ok(Self { factory, url, method, deadline, max_body,
            attempts: Arc::new(AtomicUsize::new(0)) })
    }

    pub fn attempts(&self) -> usize { self.attempts.load(Ordering::SeqCst) }

    fn prepare(&self, request: &mut Request) -> Result<(NetworkPermit, Instant), TransportError> {
        if request.url != self.url.as_str() || request.method != self.method {
            return Err(TransportError::Build("unexpected_request_destination".into()));
        }
        if self.attempts.compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst).is_err() {
            return Err(TransportError::RetryLimit);
        }
        let permit = self.factory.network_policy().acquire(&self.url)?;
        request.response_body_limit_bytes = Some(self.max_body);
        request.timeout = Some(self.deadline);
        Ok((permit, Instant::now() + self.deadline))
    }

    async fn transport(&self) -> Result<ReqwestTransport, TransportError> {
        // The native owner must supply a clean environment. TransportDefault
        // deliberately follows the official factory's selected proxy policy;
        // this module must not silently force direct connections in production.
        let route = self.factory.resolve_proxy_route_async(self.url.to_string()).await
            .map_err(|_| TransportError::Network("proxy_resolution_failed".into()))?;
        let builder = reqwest::Client::builder()
            .retry(reqwest::retry::never())
            .redirect(reqwest::redirect::Policy::none())
            .http1_only()
            .pool_max_idle_per_host(0)
            .connect_timeout(self.deadline)
            .default_headers(codex_login::default_client::default_headers());
        let builder = match route {
            OutboundProxyRoute::TransportDefault => builder,
            OutboundProxyRoute::Direct => builder.no_proxy(),
            OutboundProxyRoute::Proxy { url, no_proxy } => {
                let proxy = reqwest::Proxy::all(url)
                    .map_err(|_| TransportError::Build("invalid_proxy_configuration".into()))?
                    .no_proxy(no_proxy.as_deref().and_then(reqwest::NoProxy::from_string));
                builder.proxy(proxy)
            }
        };
        let client = build_reqwest_client_with_custom_ca(builder)
            .map_err(|_| TransportError::Build("tls_configuration_failed".into()))?;
        Ok(ReqwestTransport::from_http_client(HttpClient::new_without_request_logging(client)))
    }
}

fn guarded_stream(
    bytes: ByteStream,
    permit: NetworkPermit,
    deadline: Instant,
    max_body: usize,
) -> ByteStream {
    stream::unfold((bytes, permit, 0usize, false), move |(mut bytes, permit, total, ended)| async move {
        if ended { return None; }
        let next = timeout_at(deadline, permit.run(bytes.next())).await;
        let item = match next {
            Err(_) => Err(TransportError::Timeout),
            Ok(Err(error)) => Err(error.into()),
            Ok(Ok(None)) => return None,
            Ok(Ok(Some(Err(error)))) => Err(sanitized(error)),
            Ok(Ok(Some(Ok(chunk)))) => match total.checked_add(chunk.len()) {
                Some(next_total) if next_total <= max_body => {
                    return Some((Ok(chunk), (bytes, permit, next_total, false)));
                }
                _ => Err(TransportError::ResponseTooLarge { max_bytes: max_body }),
            },
        };
        // Drop the underlying connection immediately at failure, even if a
        // consumer does not poll again after receiving the error.
        drop(bytes);
        Some((item, (stream::empty().boxed(), permit, total, true)))
    }).boxed()
}

impl HttpTransport for StrictTransport {
    async fn execute(&self, mut request: Request) -> Result<Response, TransportError> {
        let (permit, deadline) = self.prepare(&mut request)?;
        timeout_at(deadline, permit.run(async {
            self.transport().await?.execute(request).await.map_err(sanitized)
        })).await.map_err(|_| TransportError::Timeout)?
            .map_err(TransportError::from)?
    }

    async fn stream(&self, mut request: Request) -> Result<StreamResponse, TransportError> {
        let (permit, deadline) = self.prepare(&mut request)?;
        let response = timeout_at(deadline, permit.run(async {
            self.transport().await?.stream(request).await.map_err(sanitized)
        })).await.map_err(|_| TransportError::Timeout)?
            .map_err(TransportError::from)??;
        Ok(StreamResponse {
            status: response.status,
            headers: response.headers,
            bytes: guarded_stream(response.bytes, permit, deadline, self.max_body),
        })
    }
}

pub async fn get_json<T: DeserializeOwned>(
    factory: HttpClientFactory,
    url: Url,
    auth: SharedAuthProvider,
    deadline: Duration,
    max_body: usize,
) -> Result<T, NetworkError> {
    get_json_with_headers(factory, url, auth, HeaderMap::new(), deadline, max_body).await
}

/// Extra headers carry the official provider's version/routing metadata. Auth
/// headers always take precedence and cannot be omitted after auth failure.
pub async fn get_json_with_headers<T: DeserializeOwned>(
    factory: HttpClientFactory,
    url: Url,
    auth: SharedAuthProvider,
    mut headers: HeaderMap,
    deadline: Duration,
    max_body: usize,
) -> Result<T, NetworkError> {
    let transport = StrictTransport::new(factory.clone(), url.clone(), Method::GET, deadline, max_body)?;
    let permit = factory.network_policy().acquire(&url)
        .map_err(|_| NetworkError("network_policy_denied"))?;
    let work = async {
        let prepared = auth.resolve_auth_headers().await
            .map_err(|_| NetworkError("authentication_unavailable"))?;
        if !prepared.contains_key(AUTHORIZATION) {
            return Err(NetworkError("authentication_unavailable"));
        }
        headers.extend(prepared);
        headers.insert(http::header::ACCEPT, http::HeaderValue::from_static("application/json"));
        let mut request = Request::new(Method::GET, url.to_string());
        request.headers = headers;
        let response = transport.execute(request).await.map_err(safe_error)?;
        serde_json::from_slice(&response.body).map_err(|_| NetworkError("invalid_metadata_response"))
    };
    timeout_at(Instant::now() + deadline, permit.run(work)).await
        .map_err(|_| NetworkError("network_timeout"))?
        .map_err(|_| NetworkError("network_policy_denied"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_api::{AuthHeadersFuture, AuthProvider};
    use codex_http_client::{DestinationPolicy, NetworkPolicyController, OutboundProxyPolicy};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    fn policy_factory() -> (NetworkPolicyController, HttpClientFactory) {
        let controller = NetworkPolicyController::default();
        let policy = controller.policy();
        assert!(controller.publish(policy.revision(), DestinationPolicy::Unrestricted));
        let factory = HttpClientFactory::new(OutboundProxyPolicy::RespectSystemProxy)
            .with_network_policy(policy.for_current_account());
        (controller, factory)
    }

    async fn read_fixture_request(socket: &mut TcpStream) {
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            assert!(request.len() < 8192);
            request.push(socket.read_u8().await.unwrap());
        }
        assert!(request.starts_with(b"GET "));
    }

    async fn wire_listener() -> (TcpListener, Url) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = Url::parse(&format!("http://{}/metadata", listener.local_addr().unwrap())).unwrap();
        // Prime the official public integration-test seam. No real proxy
        // settings, PAC evaluation, external DNS, or environment mutation.
        codex_http_client::cache_system_proxy_route_for_test(url.as_str(), url.origin().ascii_serialization());
        (listener, url)
    }

    struct FixtureAuth;
    impl AuthProvider for FixtureAuth {
        fn add_auth_headers(&self, headers: &mut HeaderMap) {
            headers.insert(AUTHORIZATION, http::HeaderValue::from_static("Bearer constructed-fixture"));
        }
    }

    #[tokio::test]
    async fn wire_metadata_success_and_http_failures_are_single_requests() {
        for (response, expected) in [
            ("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}", "ok"),
            ("HTTP/1.1 401 Unauthorized\r\nContent-Length: 7\r\nConnection: close\r\n\r\nprivate", "authentication_failed"),
            ("HTTP/1.1 500 Failure\r\nContent-Length: 7\r\nConnection: close\r\n\r\nprivate", "service_unavailable"),
            ("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:9/forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", "redirect_rejected"),
        ] {
            let (listener, url) = wire_listener().await;
            let count = Arc::new(AtomicUsize::new(0));
            let observed = Arc::clone(&count);
            let server = tokio::spawn(async move {
                while let Ok((mut socket, _)) = listener.accept().await {
                    observed.fetch_add(1, Ordering::SeqCst);
                    read_fixture_request(&mut socket).await;
                    socket.write_all(response.as_bytes()).await.unwrap();
                }
            });
            let (_, factory) = policy_factory();
            let result = get_json::<serde_json::Value>(factory, url, Arc::new(FixtureAuth), Duration::from_secs(2), 1024).await;
            match result {
                Ok(value) => {
                    assert_eq!(expected, "ok");
                    assert_eq!(value["ok"], true);
                }
                Err(error) => assert_eq!(error.status(), expected),
            }
            assert_eq!(count.load(Ordering::SeqCst), 1);
            server.abort();
            assert!(server.await.unwrap_err().is_cancelled());
        }
    }

    #[tokio::test]
    async fn wire_clone_cannot_send_a_second_request() {
        let (listener, url) = wire_listener().await;
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            read_fixture_request(&mut socket).await;
            socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}").await.unwrap();
            assert!(tokio::time::timeout(Duration::from_millis(150), listener.accept()).await.is_err());
        });
        let (_, factory) = policy_factory();
        let transport = StrictTransport::new(factory, url.clone(), Method::GET, Duration::from_secs(2), 100).unwrap();
        assert!(transport.execute(Request::new(Method::GET, url.to_string())).await.is_ok());
        assert!(matches!(transport.clone().execute(Request::new(Method::GET, url.to_string())).await,
            Err(TransportError::RetryLimit)));
        assert_eq!(transport.attempts(), 1);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn wire_trickling_body_obeys_total_deadline_and_closes_socket() {
        let (listener, url) = wire_listener().await;
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            read_fixture_request(&mut socket).await;
            socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n").await.unwrap();
            let mut interval = tokio::time::interval(Duration::from_millis(10));
            let mut scratch = [0u8; 1];
            tokio::time::timeout(Duration::from_secs(2), async {
                loop {
                    tokio::select! {
                        result = socket.read(&mut scratch) => {
                            assert!(matches!(result, Ok(0) | Err(_)));
                            break;
                        }
                        _ = interval.tick() => {
                            if socket.write_all(b"1\r\nx\r\n").await.is_err() { break; }
                        }
                    }
                }
            }).await.expect("timed-out body must close its connection");
        });
        let (_, factory) = policy_factory();
        let transport = StrictTransport::new(factory, url.clone(), Method::GET, Duration::from_millis(150), 1024).unwrap();
        let mut response = transport.stream(Request::new(Method::GET, url.to_string())).await.unwrap();
        let mut chunks = 0;
        loop {
            match response.bytes.next().await {
                Some(Ok(_)) => chunks += 1,
                Some(Err(TransportError::Timeout)) => break,
                other => panic!("unexpected body termination: {other:?}"),
            }
        }
        assert!(chunks > 0);
        assert!(response.bytes.next().await.is_none());
        server.await.unwrap();
    }

    #[test]
    fn clones_share_attempt_budget_and_enforce_exact_destination() {
        let (_, factory) = policy_factory();
        let url = Url::parse("https://example.invalid/responses").unwrap();
        let transport = StrictTransport::new(factory, url.clone(), Method::POST, Duration::from_secs(1), 100).unwrap();
        let mut wrong = Request::new(Method::POST, "https://other.invalid/responses".into());
        assert!(transport.prepare(&mut wrong).is_err());
        assert_eq!(transport.attempts(), 0);
        let mut request = Request::new(Method::POST, url.to_string());
        assert!(transport.prepare(&mut request).is_ok());
        assert!(matches!(transport.clone().prepare(&mut request), Err(TransportError::RetryLimit)));
        assert_eq!(request.response_body_limit_bytes, Some(100));
    }

    #[tokio::test]
    async fn stream_enforces_cumulative_limit_without_content_length() {
        let (_, factory) = policy_factory();
        let permit = factory.network_policy().acquire(&Url::parse("https://example.invalid").unwrap()).unwrap();
        let chunks = stream::iter(vec![Ok(vec![0u8; 6].into()), Ok(vec![0u8; 6].into())]).boxed();
        let mut stream = guarded_stream(chunks, permit, Instant::now() + Duration::from_secs(1), 10);
        assert!(stream.next().await.unwrap().is_ok());
        assert!(matches!(stream.next().await.unwrap(), Err(TransportError::ResponseTooLarge { max_bytes: 10 })));
        assert!(stream.next().await.is_none());
    }

    #[tokio::test]
    async fn stream_revocation_and_total_deadline_stop_pending_body() {
        let (controller, factory) = policy_factory();
        let url = Url::parse("https://example.invalid").unwrap();
        let permit = factory.network_policy().acquire(&url).unwrap();
        let mut body = guarded_stream(stream::pending().boxed(), permit, Instant::now() + Duration::from_secs(1), 10);
        controller.policy().invalidate();
        assert!(matches!(body.next().await.unwrap(), Err(TransportError::Policy(_))));
        let (_, factory) = policy_factory();
        let permit = factory.network_policy().acquire(&url).unwrap();
        let mut body = guarded_stream(stream::pending().boxed(), permit, Instant::now(), 10);
        assert!(matches!(body.next().await.unwrap(), Err(TransportError::Timeout)));
    }

    struct NoAuth;
    impl AuthProvider for NoAuth {
        fn add_auth_headers(&self, _: &mut HeaderMap) {}
        fn resolve_auth_headers(&self) -> AuthHeadersFuture<'_> {
            Box::pin(async { Err(codex_api::AuthError::Transient("private-fixture".into())) })
        }
    }

    #[tokio::test]
    async fn policy_and_auth_reject_before_any_client_is_built() {
        let (controller, factory) = policy_factory();
        let url = Url::parse("https://example.invalid").unwrap();
        let result = get_json::<serde_json::Value>(factory.clone(), url.clone(), Arc::new(NoAuth), Duration::from_secs(1), 100).await;
        assert_eq!(result.unwrap_err().status(), "authentication_unavailable");
        controller.policy().invalidate();
        let result = get_json::<serde_json::Value>(factory, url, Arc::new(NoAuth), Duration::from_secs(1), 100).await;
        assert_eq!(result.unwrap_err().status(), "network_policy_denied");
    }

    #[test]
    fn upstream_http_details_are_removed() {
        for (status, expected) in [(401, "authentication_failed"), (403, "access_denied"),
            (429, "rate_limited"), (500, "service_unavailable"), (307, "redirect_rejected")] {
            let error = sanitized(TransportError::Http { status: http::StatusCode::from_u16(status).unwrap(),
                url: Some("private-fixture".into()), headers: None, body: Some("private-fixture".into()) });
            assert!(!format!("{error:?}").contains("private-fixture"));
            assert_eq!(safe_error(error).status(), expected);
        }
    }
}

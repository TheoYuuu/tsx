import Foundation

enum TranslationHTTPPolicy {
    /// A fresh ephemeral session contains neither shared cookies nor persistent
    /// cache or credentials. The injected session exists only for transport tests.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        return config
    }
}

/// All redirects are refused, including same-origin redirects: this keeps the
/// explicitly selected destination and prevents POST/key forwarding surprises.
final class TranslationRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

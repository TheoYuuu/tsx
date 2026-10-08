import Foundation

/// Only fixed, local messages leave this boundary. Provider response bodies can
/// contain the input, API key or upstream infrastructure details.
enum RemoteTranslationError: String, Error, LocalizedError, Equatable, Sendable {
    case missingKey, invalidKey, authenticationFailed, forbidden, quotaExceeded, rateLimited
    case modelUnavailable, invalidRequest, timedOut, offline, connectionFailed
    case serviceUnavailable, redirected, invalidResponse, incompleteResponse
    case refused, responseTooLarge, inputTooLarge, unsupportedLanguage

    var errorDescription: String? { L10n.string("translationService.error.\(rawValue)") }

    static func http(status: Int, body: Data) -> Self {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = (error?["code"] as? String) ?? (error?["type"] as? String) ?? ""
        switch code {
        case "insufficient_quota", "quota_exceeded", "billing_hard_limit_reached", "insufficient_balance":
            return .quotaExceeded
        case "invalid_api_key", "authentication_error": return .invalidKey
        case "model_not_found", "model_not_available": return .modelUnavailable
        case "rate_limit_exceeded", "rate_limit_error": return .rateLimited
        case "server_error", "service_unavailable_error", "server_is_overloaded", "overloaded_error":
            return .serviceUnavailable
        case "context_length_exceeded": return .inputTooLarge
        case "content_filter", "content_policy_violation": return .refused
        default: break
        }
        switch status {
        case 301...399: return .redirected
        case 401: return .invalidKey
        case 402: return .quotaExceeded
        case 403: return .forbidden
        case 404: return .modelUnavailable
        case 408, 504: return .timedOut
        case 413: return .inputTooLarge
        case 429: return .rateLimited
        case 500...599: return .serviceUnavailable
        default: return .invalidRequest
        }
    }
}

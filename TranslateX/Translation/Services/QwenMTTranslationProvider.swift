import Foundation

/// Qwen-MT Flash has its own translation protocol. This implementation requests
/// one complete JSON response; it never sends the generic chat/system prompt.
@MainActor
struct QwenMTTranslationProvider: TranslationProvider {
    private let configuration: TranslationServiceConfiguration
    private let apiKey: String?
    private let session: URLSession?
    nonisolated static let supportedModel = "qwen-mt-flash"
    nonisolated static let maximumInputBytes = 65_536
    nonisolated static let maximumOutputBytes = 524_288

    init(configuration: TranslationServiceConfiguration, apiKey: String?, session: URLSession? = nil) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.session = session
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try Task.checkCancellation()
        let http = try Self.makeRequest(configuration: configuration, apiKey: apiKey, request: request)
        let response = try await BoundedTranslationHTTPTransport.send(http, session: session)
        try Task.checkCancellation()
        guard (200...299).contains(response.status) else { throw Self.failure(status: response.status, body: response.data) }
        return try Self.parse(response.data, request: request)
    }

    static func makeRequest(configuration: TranslationServiceConfiguration, apiKey: String?, request: TranslationRequest) throws -> URLRequest {
        let config = try configuration.validated()
        guard config.kind == .qwenMT, config.model == supportedModel else { throw RemoteTranslationError.modelUnavailable }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteTranslationError.invalidRequest }
        guard request.text.utf8.count <= maximumInputBytes else { throw RemoteTranslationError.inputTooLarge }
        guard let target = QwenMTTranslationLanguages.code(for: request.target) else { throw RemoteTranslationError.unsupportedLanguage }
        let source: String
        if let identifier = request.source {
            guard let code = QwenMTTranslationLanguages.code(for: identifier, asTarget: false) else { throw RemoteTranslationError.unsupportedLanguage }
            source = code
        } else { source = "auto" }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw RemoteTranslationError.missingKey }
        guard key.utf8.count <= 8_192,
              !key.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw RemoteTranslationError.invalidKey
        }
        let body: [String: Any] = [
            "model": supportedModel, "stream": false,
            "messages": [["role": "user", "content": request.text]],
            "translation_options": ["source_lang": source, "target_lang": target]
        ]
        var http = URLRequest(url: try config.endpointURL(appending: "chat/completions"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        http.httpMethod = "POST"
        http.httpShouldHandleCookies = false
        http.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return http
    }

    nonisolated static func parse(_ data: Data, request: TranslationRequest) throws -> TranslationResult {
        guard data.count <= BoundedTranslationHTTPTransport.maximumResponseBytes else { throw RemoteTranslationError.responseTooLarge }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw RemoteTranslationError.invalidResponse }
        if object["error"] != nil || object["code"] != nil { throw failure(status: 200, body: data) }
        // Decode numeric/string fields strictly: NSNumber bridges JSON false
        // to Int(0), which must not pass the completion-index contract.
        guard let completion = try? JSONDecoder().decode(QwenMTCompletion.self, from: data),
              completion.choices.count == 1, let choice = completion.choices.first,
              choice.index == 0, choice.message.role == "assistant",
              let rawChoices = object["choices"] as? [[String: Any]],
              let message = rawChoices.first?["message"] as? [String: Any] else { throw RemoteTranslationError.invalidResponse }
        if let refusal = message["refusal"], !(refusal is NSNull) { throw RemoteTranslationError.refused }
        if let tools = message["tool_calls"], !(tools is NSNull) {
            guard let tools = tools as? [Any], tools.isEmpty else { throw RemoteTranslationError.invalidResponse }
        }
        if let call = message["function_call"], !(call is NSNull) { throw RemoteTranslationError.invalidResponse }
        switch choice.finish_reason {
        case "stop": break
        case "content_filter", "sensitive": throw RemoteTranslationError.refused
        default: throw RemoteTranslationError.incompleteResponse
        }
        guard let text = choice.message.content,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteTranslationError.invalidResponse }
        guard text.utf8.count <= maximumOutputBytes else { throw RemoteTranslationError.responseTooLarge }
        return TranslationResult(text: text, source: request.source.map(LanguageCatalog.canonicalIdentifier),
                                 target: LanguageCatalog.canonicalIdentifier(request.target),
                                 usage: TranslationUsage.reportedTokens(object["usage"]))
    }

    nonisolated static func failure(status: Int, body: Data) -> RemoteTranslationError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = (error?["code"] as? String) ?? (error?["type"] as? String) ?? (object?["code"] as? String) ?? ""
        // Alibaba's insufficient_quota is also the documented TPS/TPM throttle,
        // so the generic OpenAI billing mapper must not be used here.
        switch code {
        case "InvalidApiKey", "invalid_api_key": return .invalidKey
        case "AccessDenied", "access_denied": return .forbidden
        case "Arrearage", "arrearage", "isv.OUT_OF_SERVICE": return .quotaExceeded
        case "Throttling", "Throttling.RateQuota", "Throttling.AllocationQuota", "Throttling.BurstRate", "Throttling.Concurrency",
             "rate_limit_exceeded", "limit_requests", "limit_burst_rate", "insufficient_quota": return .rateLimited
        case "ModelNotFound", "model_not_found": return .modelUnavailable
        case "DataInspectionFailed", "data_inspection_failed": return .refused
        case "context_length_exceeded", "InputTooLong": return .inputTooLarge
        case "InternalError", "internal_error", "ServiceUnavailable", "service_unavailable_error": return .serviceUnavailable
        default: break
        }
        switch status {
        case 300...399: return .redirected
        case 401: return .invalidKey
        case 402: return .quotaExceeded
        case 403: return .forbidden
        case 404: return .modelUnavailable
        case 408, 504: return .timedOut
        case 413: return .inputTooLarge
        case 429: return .rateLimited
        case 500...599: return .serviceUnavailable
        case 200: return .invalidResponse
        default: return .invalidRequest
        }
    }
}

nonisolated private struct QwenMTCompletion: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let index: Int
        let finish_reason: String?
        let message: Message
    }
    struct Message: Decodable {
        let role: String
        let content: String?
    }
}

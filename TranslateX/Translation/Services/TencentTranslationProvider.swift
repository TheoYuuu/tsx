import Foundation

/// TokenHub's dedicated translation operation, not its prompted chat protocol.
/// https://cloud.tencent.com/document/product/1823/132252 (2026-09-26)
@MainActor
struct TencentTranslationProvider: TranslationProvider {
    private let configuration: TranslationServiceConfiguration
    private let apiKey: String?
    private let session: URLSession?
    nonisolated static let supportedModel = "hy-mt2-plus"
    // Product limits, not an estimate or guarantee of the model's 4k input tokens.
    nonisolated static let maximumInputBytes = 8_192
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
        guard (200...299).contains(response.status) else {
            throw Self.failure(status: response.status, body: response.data)
        }
        return try Self.parse(response.data, request: request)
    }

    static func makeRequest(configuration: TranslationServiceConfiguration, apiKey: String?, request: TranslationRequest) throws -> URLRequest {
        let config = try configuration.validated()
        guard config.kind == .tencentTranslation, config.model == supportedModel else {
            throw RemoteTranslationError.modelUnavailable
        }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteTranslationError.invalidRequest
        }
        guard request.text.utf8.count <= maximumInputBytes else { throw RemoteTranslationError.inputTooLarge }
        guard let target = TencentTranslationLanguages.code(for: request.target) else {
            throw RemoteTranslationError.unsupportedLanguage
        }
        let source = try request.source.map { identifier in
            guard let code = TencentTranslationLanguages.code(for: identifier, asTarget: false) else {
                throw RemoteTranslationError.unsupportedLanguage
            }
            return code
        }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw RemoteTranslationError.missingKey }
        guard key.utf8.count <= 8_192,
              !key.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw RemoteTranslationError.invalidKey
        }
        var body: [String: Any] = ["model": supportedModel, "text": request.text, "target": target, "stream": false]
        if let source { body["source"] = source }
        var http = URLRequest(url: try config.endpointURL(appending: "v1/api/translations"),
                              cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        http.httpMethod = "POST"
        http.httpShouldHandleCookies = false
        http.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return http
    }

    nonisolated static func parse(_ data: Data, request: TranslationRequest) throws -> TranslationResult {
        guard data.count <= BoundedTranslationHTTPTransport.maximumResponseBytes else {
            throw RemoteTranslationError.responseTooLarge
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RemoteTranslationError.invalidResponse
        }
        if object["error"] != nil || object["code"] != nil { throw failure(status: 200, body: data) }
        // Strict Decodable fields reject bool-as-zero indices and nontext content.
        guard let response = try? JSONDecoder().decode(TencentTranslationCompletion.self, from: data),
              response.choices.count == 1, let choice = response.choices.first,
              choice.index == 0, choice.message.role == "assistant",
              let expectedTarget = TencentTranslationLanguages.code(for: request.target),
              response.target == expectedTarget,
              let rawChoices = object["choices"] as? [[String: Any]],
              let message = rawChoices.first?["message"] as? [String: Any] else {
            throw RemoteTranslationError.invalidResponse
        }
        if let refusal = message["refusal"], !(refusal is NSNull) { throw RemoteTranslationError.refused }
        if let calls = message["tool_calls"], !(calls is NSNull) {
            guard let calls = calls as? [Any], calls.isEmpty else { throw RemoteTranslationError.invalidResponse }
        }
        if let call = message["function_call"], !(call is NSNull) { throw RemoteTranslationError.invalidResponse }
        switch choice.finish_reason {
        case "stop": break
        case "sensitive", "content_filter": throw RemoteTranslationError.refused
        default: throw RemoteTranslationError.incompleteResponse
        }
        guard let text = choice.message.content,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteTranslationError.invalidResponse
        }
        guard text.utf8.count <= maximumOutputBytes else { throw RemoteTranslationError.responseTooLarge }
        // The response calls this the request source, not a guaranteed detection.
        // Only a recognized value may populate an otherwise unknown source.
        let detectedSource = response.source.flatMap(TencentTranslationLanguages.detectedSourceIdentifier)
        return TranslationResult(text: text,
                                 source: request.source.map(LanguageCatalog.canonicalIdentifier) ?? detectedSource,
                                 target: LanguageCatalog.canonicalIdentifier(request.target),
                                 usage: TranslationUsage.reportedTokens(object["usage"]))
    }

    nonisolated static func failure(status: Int, body: Data) -> RemoteTranslationError {
        // These are the published gateway codes for Chat/Responses. Their exact
        // coverage on /translations is not credential-verified; unknown bodies
        // retain a safe HTTP fallback instead of displaying upstream messages.
        // https://cloud.tencent.com/document/product/1823/131595
        let envelope = try? JSONDecoder().decode(TencentTranslationFailure.self, from: body)
        let code = envelope?.error?.code?.value ?? envelope?.code?.value ?? ""
        switch code {
        case "400003", "413001": return .inputTooLarge
        case "400004", "400005", "401006": return .modelUnavailable
        case "401001", "401002", "401003", "401004", "401005": return .invalidKey
        case "401007", "401008", "403004": return .quotaExceeded
        case "403001", "403002", "403003", "403005", "403006": return .forbidden
        case "429001", "429002", "429003", "429004", "429005", "429006": return .rateLimited
        case "451001": return .refused
        case "500001", "502001", "503001": return .serviceUnavailable
        case "504001": return .timedOut
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
        case 451: return .refused
        case 500...599: return .serviceUnavailable
        case 200...299: return .invalidResponse
        default: return .invalidRequest
        }
    }
}

nonisolated private struct TencentTranslationCompletion: Decodable {
    let choices: [Choice]
    let source: String?
    let target: String
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

nonisolated private struct TencentTranslationFailure: Decodable {
    let error: Details?
    let code: Code?
    struct Details: Decodable { let code: Code? }
    struct Code: Decodable {
        let value: String
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) { value = string }
            else { value = String(try container.decode(Int.self)) }
        }
    }
}

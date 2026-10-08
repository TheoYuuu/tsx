import Foundation

/// Cloud Translation Basic v2: one NMT plain-text request, no ADC discovery,
/// HTML interpretation, retries, splitting, or streaming simulation.
@MainActor
struct GoogleCloudTranslationProvider: TranslationProvider {
    private let configuration: TranslationServiceConfiguration
    private let apiKey: String?
    private let session: URLSession?
    nonisolated static let maximumInputBytes = 65_536
    nonisolated static let maximumBodyBytes = 100_000
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
        guard config.kind == .googleCloud else { throw RemoteTranslationError.invalidRequest }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteTranslationError.invalidRequest }
        guard request.text.utf8.count <= maximumInputBytes else { throw RemoteTranslationError.inputTooLarge }
        guard let target = GoogleTranslationLanguages.code(for: request.target) else { throw RemoteTranslationError.unsupportedLanguage }
        var parameters: [String: Any] = ["q": request.text, "target": target, "format": "text", "model": "nmt"]
        if let source = request.source {
            guard let code = GoogleTranslationLanguages.code(for: source, asTarget: false) else { throw RemoteTranslationError.unsupportedLanguage }
            parameters["source"] = code
        }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw RemoteTranslationError.missingKey }
        guard key.utf8.count <= 8_192,
              !key.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw RemoteTranslationError.invalidKey
        }
        let data = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
        // Google Basic's limit is for the encoded request, not character count.
        guard data.count <= maximumBodyBytes else { throw RemoteTranslationError.inputTooLarge }
        // This setting is the complete v2 translate URL; never append a suffix.
        var http = URLRequest(url: try config.validatedEndpoint(), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        http.httpMethod = "POST"
        http.httpShouldHandleCookies = false
        http.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        http.httpBody = data
        return http
    }

    nonisolated static func parse(_ data: Data, request: TranslationRequest) throws -> TranslationResult {
        guard data.count <= BoundedTranslationHTTPTransport.maximumResponseBytes else { throw RemoteTranslationError.responseTooLarge }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["error"] != nil {
            throw failure(status: 200, body: data)
        }
        let response: GoogleTranslationResponse
        do { response = try JSONDecoder().decode(GoogleTranslationResponse.self, from: data) }
        catch { throw RemoteTranslationError.invalidResponse }
        guard response.data.translations.count == 1, let entry = response.data.translations.first,
              entry.model == nil || entry.model == "nmt",
              !entry.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteTranslationError.invalidResponse
        }
        guard entry.translatedText.utf8.count <= maximumOutputBytes else { throw RemoteTranslationError.responseTooLarge }
        return TranslationResult(
            text: entry.translatedText,
            source: request.source.map(LanguageCatalog.canonicalIdentifier)
                ?? entry.detectedSourceLanguage.flatMap(GoogleTranslationLanguages.detectedSourceIdentifier),
            target: LanguageCatalog.canonicalIdentifier(request.target)
        )
    }

    nonisolated static func failure(status: Int, body: Data) -> RemoteTranslationError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let reasons = ((error?["errors"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
            + ((error?["details"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
        if reasons.contains(where: ["keyInvalid", "API_KEY_INVALID", "API_KEY_EXPIRED"].contains) { return .invalidKey }
        if reasons.contains(where: ["dailyLimitExceeded", "quotaExceeded", "DAILY_LIMIT_EXCEEDED"].contains) { return .quotaExceeded }
        if reasons.contains(where: ["userRateLimitExceeded", "rateLimitExceeded", "RATE_LIMIT_EXCEEDED"].contains) { return .rateLimited }
        // Official v2 troubleshooting also documents these exact messages when
        // structured reasons are absent. Never echo or substring-match bodies.
        switch error?["message"] as? String {
        case "Daily Limit Exceeded": return .quotaExceeded
        case "User Rate Limit Exceeded": return .rateLimited
        default: break
        }
        let status = status == 200 ? (error?["code"] as? Int ?? 200) : status
        switch status {
        case 300...399: return .redirected
        case 401: return .invalidKey
        case 403: return .forbidden
        case 408, 504: return .timedOut
        case 413: return .inputTooLarge
        case 429: return .rateLimited
        case 500...599: return .serviceUnavailable
        case 200: return .invalidResponse
        default: return .invalidRequest
        }
    }
}

nonisolated private struct GoogleTranslationResponse: Decodable {
    let data: Payload
    struct Payload: Decodable { let translations: [Entry] }
    struct Entry: Decodable {
        let translatedText: String
        let detectedSourceLanguage: String?
        let model: String?
    }
}

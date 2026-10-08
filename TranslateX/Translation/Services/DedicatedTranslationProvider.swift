import Foundation

/// Official text-translation protocols. These APIs return a complete JSON
/// response; the UI must not present simulated streaming or unused LLM settings.
@MainActor
struct DedicatedTranslationProvider: TranslationProvider {
    private let configuration: TranslationServiceConfiguration
    private let apiKey: String?
    private let session: URLSession?
    nonisolated static let maximumInputBytes = 65_536
    nonisolated static let maximumDeepLBodyBytes = 131_072
    nonisolated static let maximumAzureUTF16Units = 50_000
    nonisolated static let maximumOutputBytes = 524_288

    init(configuration: TranslationServiceConfiguration, apiKey: String?, session: URLSession? = nil) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.session = session
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try Task.checkCancellation()
        let httpRequest = try Self.makeRequest(configuration: configuration, apiKey: apiKey, request: request)
        let payload = try await BoundedTranslationHTTPTransport.send(httpRequest, session: session)
        try Task.checkCancellation()
        guard (200...299).contains(payload.status) else {
            throw Self.failure(kind: configuration.kind, status: payload.status, body: payload.data)
        }
        return try Self.parse(payload.data, kind: configuration.kind, request: request)
    }

    static func makeRequest(
        configuration: TranslationServiceConfiguration, apiKey: String?, request: TranslationRequest
    ) throws -> URLRequest {
        let config = try configuration.validated()
        guard config.kind == .deepL || config.kind == .azureTranslator else { throw RemoteTranslationError.invalidRequest }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteTranslationError.invalidRequest
        }
        guard request.text.utf8.count <= maximumInputBytes else { throw RemoteTranslationError.inputTooLarge }
        let target = try languageCode(request.target, kind: config.kind, asTarget: true)
        let source = try request.source.map { try languageCode($0, kind: config.kind, asTarget: false) }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw RemoteTranslationError.missingKey }
        guard key.utf8.count <= 8_192,
              !key.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw RemoteTranslationError.invalidKey
        }
        var url = try config.validatedEndpoint()
        let body: Data
        if config.kind == .deepL {
            url.appendPathComponent("v2")
            url.appendPathComponent("translate")
            var parameters: [String: Any] = [
                "text": [request.text], "target_lang": target,
                "preserve_formatting": true
            ]
            if let source { parameters["source_lang"] = source }
            body = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
            // Count the encoded JSON, not just the source string: control
            // characters can expand to six-byte Unicode escapes.
            guard body.count <= maximumDeepLBodyBytes else { throw RemoteTranslationError.inputTooLarge }
        } else {
            // The service documents a 50,000-character ceiling. UTF-16 units
            // conservatively bound code points and avoid Swift grapheme counts
            // undercounting composed text. This is not a billing estimate.
            guard request.text.utf16.count <= maximumAzureUTF16Units else { throw RemoteTranslationError.inputTooLarge }
            if url.path.isEmpty || url.path == "/" {
                if url.host?.lowercased().hasSuffix(".cognitiveservices.azure.com") == true {
                    url.appendPathComponent("translator/text/v3.0")
                }
            }
            url.appendPathComponent("translate")
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw RemoteTranslationError.invalidRequest
            }
            components.queryItems = [
                URLQueryItem(name: "api-version", value: "3.0"),
                URLQueryItem(name: "to", value: target),
                URLQueryItem(name: "textType", value: "plain")
            ]
            if let source { components.queryItems?.append(URLQueryItem(name: "from", value: source)) }
            guard let queryURL = components.url else { throw RemoteTranslationError.invalidRequest }
            url = queryURL
            body = try JSONSerialization.data(withJSONObject: [["Text": request.text]], options: [.sortedKeys])
        }
        var result = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        result.httpMethod = "POST"
        result.httpShouldHandleCookies = false
        result.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        if config.kind == .deepL {
            result.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        } else {
            result.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            if !config.region.isEmpty { result.setValue(config.region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region") }
        }
        result.httpBody = body
        return result
    }

    nonisolated static func parse(_ data: Data, kind: TranslationServiceKind, request: TranslationRequest) throws -> TranslationResult {
        guard data.count <= BoundedTranslationHTTPTransport.maximumResponseBytes else { throw RemoteTranslationError.responseTooLarge }
        let text: String
        let detectedSource: String?
        var usage: TranslationUsage?
        do {
            switch kind {
            case .deepL:
                let response = try JSONDecoder().decode(DeepLResponse.self, from: data)
                guard response.translations.count == 1, let translation = response.translations.first else {
                    throw RemoteTranslationError.invalidResponse
                }
                text = translation.text
                detectedSource = translation.detected_source_language.flatMap {
                    DedicatedTranslationLanguages.detectedSourceIdentifier(from: $0, kind: kind)
                }
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let entries = object?["translations"] as? [[String: Any]]
                usage = TranslationUsage(characters: TranslationUsage.reportedCount(entries?.first?["billed_characters"])).nonempty
            case .azureTranslator:
                let response = try JSONDecoder().decode([AzureResponse].self, from: data)
                guard response.count == 1, let first = response.first,
                      first.translations.count == 1, let translation = first.translations.first,
                      let expected = DedicatedTranslationLanguages.code(for: request.target, kind: kind, asTarget: true),
                      translation.to.caseInsensitiveCompare(expected) == .orderedSame else {
                    throw RemoteTranslationError.invalidResponse
                }
                text = translation.text
                if let detection = first.detectedLanguage, let score = detection.score,
                   score.isFinite, (0...1).contains(score), score > 0 {
                    detectedSource = DedicatedTranslationLanguages.detectedSourceIdentifier(from: detection.language, kind: kind)
                } else {
                    detectedSource = nil
                }
            default:
                throw RemoteTranslationError.invalidRequest
            }
        } catch let error as RemoteTranslationError {
            throw error
        } catch {
            // Decoding descriptions can contain source or translated text.
            throw RemoteTranslationError.invalidResponse
        }
        guard text.utf8.count <= maximumOutputBytes else { throw RemoteTranslationError.responseTooLarge }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteTranslationError.invalidResponse }
        return TranslationResult(
            text: text,
            source: request.source.map(LanguageCatalog.canonicalIdentifier) ?? detectedSource,
            target: LanguageCatalog.canonicalIdentifier(request.target),
            usage: usage
        )
    }

    nonisolated static func failure(kind: TranslationServiceKind, status: Int, body: Data) -> RemoteTranslationError {
        if kind == .deepL {
            switch status {
            // DeepL uses 403 for invalid/inactive keys as well as missing
            // endpoint scopes. Do not diagnose one cause from that status.
            case 401, 403: return .authenticationFailed
            case 413: return .inputTooLarge
            case 429, 529: return .rateLimited
            case 456: return .quotaExceeded
            case 408, 504: return .timedOut
            case 500...599: return .serviceUnavailable
            case 300...399: return .redirected
            default: return .invalidRequest
            }
        }
        if kind == .azureTranslator {
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let code = (error?["code"] as? Int) ?? (error?["code"] as? String).flatMap(Int.init)
            switch code {
            case 403001: return .quotaExceeded
            case 401000, 401015: return .invalidKey
            case 400003, 400019, 400023, 400035, 400036, 400075: return .unsupportedLanguage
            case 400050, 400077: return .inputTooLarge
            case 429000, 429001, 429002: return .rateLimited
            case 408001: return .serviceUnavailable
            case 408002: return .timedOut
            case 500000, 503000: return .serviceUnavailable
            default: break
            }
            switch status {
            case 401: return .invalidKey
            case 403: return .forbidden
            case 408, 504: return .timedOut
            case 413: return .inputTooLarge
            case 429: return .rateLimited
            case 500...599: return .serviceUnavailable
            case 300...399: return .redirected
            default: return .invalidRequest
            }
        }
        return .invalidRequest
    }

    private static func languageCode(_ identifier: String, kind: TranslationServiceKind, asTarget: Bool) throws -> String {
        guard let code = DedicatedTranslationLanguages.code(for: identifier, kind: kind, asTarget: asTarget) else {
            throw RemoteTranslationError.unsupportedLanguage
        }
        return code
    }
}

nonisolated private struct DeepLResponse: Decodable {
    let translations: [DeepLTranslation]
}

nonisolated private struct DeepLTranslation: Decodable {
    let text: String
    let detected_source_language: String?
}

nonisolated private struct AzureResponse: Decodable {
    let translations: [AzureTranslation]
    let detectedLanguage: AzureDetectedLanguage?
}

nonisolated private struct AzureTranslation: Decodable {
    let text: String
    let to: String
}

nonisolated private struct AzureDetectedLanguage: Decodable {
    let language: String
    let score: Double?
}

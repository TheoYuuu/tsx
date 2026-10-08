import Foundation

/// A directory entry is a candidate, not proof that a model can translate.
nonisolated struct TranslationServiceModel: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
}

nonisolated protocol TranslationServiceModelLoading: Sendable {
    func models(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> [TranslationServiceModel]
}

nonisolated enum TranslationServiceModelCatalogError: String, Error, LocalizedError, Sendable {
    case unsupportedService, catalogUnavailable, invalidCatalog, catalogTooLarge

    var errorDescription: String? { L10n.string("translationService.catalogError.\(rawValue)") }
}

/// Explicit, read-only discovery at the user's configured destination. There is
/// no fallback host, model selection, generated text, cache, or automatic retry.
/// OpenAI / DeepSeek / Ollama use their documented `models` operation; compatible
/// services may omit it. Claude uses its native paginated Models API:
/// https://developers.openai.com/api/reference/resources/models/methods/list
/// https://api-docs.deepseek.com/api/list-models/
/// https://docs.ollama.com/api/openai-compatibility
/// https://platform.claude.com/docs/en/api/models/list
nonisolated struct TranslationServiceModelCatalog: TranslationServiceModelLoading {
    static let maximumModels = 1_000
    static let maximumPages = 10
    static let maximumResponseBytes = 4_194_304
    static let maximumIdentifierBytes = 256

    private let session: URLSession?
    private let timeout: Duration

    /// Shorter deadlines are injectable for cancellation/deadline tests. The
    /// complete operation, including every Claude page, never gets over 20 s.
    init(session: URLSession? = nil, timeout: Duration = .seconds(20)) {
        self.session = session
        self.timeout = max(.milliseconds(1), min(timeout, .seconds(20)))
    }

    static func supports(_ kind: TranslationServiceKind) -> Bool {
        switch kind {
        case .openAI, .deepSeek, .claude, .openAICompatible, .ollama: true
        case .deepL, .azureTranslator, .qwenMT, .googleCloud, .tencentTranslation, .codex: false
        }
    }

    func models(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> [TranslationServiceModel] {
        try Task.checkCancellation()
        // Discovery must work before the user has chosen a model or named the
        // draft. Do not call configuration.validated(), which validates both.
        let firstRequest = try Self.makeRequest(configuration: configuration, apiKey: apiKey)
        do {
            return try await withThrowingTaskGroup(of: [TranslationServiceModel].self) { group in
                group.addTask { try await load(firstRequest, kind: configuration.kind) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw RemoteTranslationError.timedOut
                }
                defer { group.cancelAll() }
                guard let models = try await group.next() else { throw CancellationError() }
                try Task.checkCancellation()
                return models
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            switch error as? RemoteTranslationError {
            case .responseTooLarge: throw TranslationServiceModelCatalogError.catalogTooLarge
            case .invalidResponse: throw TranslationServiceModelCatalogError.invalidCatalog
            default: throw error
            }
        }
    }

    static func makeRequest(configuration: TranslationServiceConfiguration, apiKey: String?) throws -> URLRequest {
        guard supports(configuration.kind) else { throw TranslationServiceModelCatalogError.unsupportedService }
        let endpoint = try configuration.endpointURL(appending: "models")
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configuration.kind.requiresAPIKey && key.isEmpty { throw RemoteTranslationError.missingKey }
        guard key.utf8.count <= 8_192,
              !key.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw RemoteTranslationError.invalidKey
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if configuration.kind == .claude {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request = try pageRequest(from: request, after: nil)
        } else if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func load(_ firstRequest: URLRequest, kind: TranslationServiceKind) async throws -> [TranslationServiceModel] {
        let activeSession = session ?? URLSession(configuration: TranslationHTTPPolicy.sessionConfiguration())
        defer { if session == nil { activeSession.invalidateAndCancel() } }
        var request = firstRequest
        var models: [TranslationServiceModel] = []
        var identifiers = Set<String>()
        var cursors = Set<String>()
        var remainingBytes = Self.maximumResponseBytes

        for pageNumber in 0..<Self.maximumPages {
            try Task.checkCancellation()
            guard remainingBytes > 0 else { throw TranslationServiceModelCatalogError.catalogTooLarge }
            let payload = try await BoundedTranslationHTTPTransport.send(
                request, session: activeSession, maximumResponseBytes: remainingBytes
            )
            try Task.checkCancellation()
            guard (200...299).contains(payload.status) else { throw Self.failure(status: payload.status, body: payload.data) }
            remainingBytes -= payload.data.count
            let page = try Self.parse(payload.data, kind: kind)
            guard models.count + page.models.count <= Self.maximumModels else {
                throw TranslationServiceModelCatalogError.catalogTooLarge
            }
            for model in page.models {
                guard identifiers.insert(model.id).inserted else { throw TranslationServiceModelCatalogError.invalidCatalog }
                models.append(model)
            }
            guard let next = page.nextCursor else { return models }
            guard pageNumber + 1 < Self.maximumPages else { throw TranslationServiceModelCatalogError.catalogTooLarge }
            guard cursors.insert(next).inserted else { throw TranslationServiceModelCatalogError.invalidCatalog }
            // Treat a cursor as a query value, never as a URL supplied by the
            // service. Every page retains the exact endpoint and authentication.
            request = try Self.pageRequest(from: firstRequest, after: next)
        }
        throw TranslationServiceModelCatalogError.catalogTooLarge
    }

    private static func pageRequest(from original: URLRequest, after: String?) throws -> URLRequest {
        guard let url = original.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TranslationServiceModelCatalogError.invalidCatalog
        }
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        if let after { components.queryItems?.append(URLQueryItem(name: "after_id", value: after)) }
        guard let pageURL = components.url else { throw TranslationServiceModelCatalogError.invalidCatalog }
        var request = original
        request.url = pageURL
        return request
    }

    private struct Page {
        let models: [TranslationServiceModel]
        let nextCursor: String?
    }

    private static func parse(_ data: Data, kind: TranslationServiceKind) throws -> Page {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.error == nil, envelope.object == nil || envelope.object == "list" else {
            throw TranslationServiceModelCatalogError.invalidCatalog
        }
        guard envelope.data.count <= maximumModels else { throw TranslationServiceModelCatalogError.catalogTooLarge }
        let models = try envelope.data.map { entry in
            guard validIdentifier(entry.id), entry.object == nil || entry.object == "model",
                  entry.type == nil || entry.type == "model" else {
                throw TranslationServiceModelCatalogError.invalidCatalog
            }
            let name = (kind == .claude ? entry.displayName : entry.name) ?? entry.id
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= maximumIdentifierBytes,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw TranslationServiceModelCatalogError.invalidCatalog
            }
            return TranslationServiceModel(id: entry.id, name: name)
        }
        if kind == .claude {
            guard let hasMore = envelope.hasMore else { throw TranslationServiceModelCatalogError.invalidCatalog }
            if hasMore {
                guard let cursor = envelope.lastID, validIdentifier(cursor), models.last?.id == cursor else {
                    throw TranslationServiceModelCatalogError.invalidCatalog
                }
                return Page(models: models, nextCursor: cursor)
            }
        }
        return Page(models: models, nextCursor: nil)
    }

    private static func validIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maximumIdentifierBytes
            && !id.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains)
    }

    static func failure(status: Int, body: Data) -> any Error {
        // A missing directory says nothing about the user's chosen model.
        if status == 404 || status == 405 { return TranslationServiceModelCatalogError.catalogUnavailable }
        return RemoteTranslationError.http(status: status, body: body)
    }

    private struct Envelope: Decodable {
        let data: [Entry]
        let object: String?
        let hasMore: Bool?
        let lastID: String?
        let error: NonNullError?
        enum CodingKeys: String, CodingKey {
            case data, object, error
            case hasMore = "has_more"
            case lastID = "last_id"
        }
    }

    /// Retain only presence, never a vendor's raw message or other error fields.
    private struct NonNullError: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    private struct Entry: Decodable {
        let id: String
        let name: String?
        let displayName: String?
        let object: String?
        let type: String?
        enum CodingKeys: String, CodingKey {
            case id, name, object, type
            case displayName = "display_name"
        }
    }
}

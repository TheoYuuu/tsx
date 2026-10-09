import Foundation

/// Account data is fetched manually or on an explicitly configured schedule,
/// at verified official destinations. It is not a local spending estimate.
/// https://api-docs.deepseek.com/zh-cn/api/get-user-balance/
/// https://developers.deepl.com/api-reference/usage-and-quota/check-usage-and-limits
nonisolated struct TranslationAccountUsageLoader: TranslationAccountUsageLoading {
    static let maximumResponseBytes = 65_536
    private let session: URLSession?
    private let timeout: Duration

    init(session: URLSession? = nil, timeout: Duration = .seconds(20)) {
        self.session = session
        self.timeout = max(.milliseconds(1), min(timeout, .seconds(120)))
    }

    static func supports(_ configuration: TranslationServiceConfiguration) -> Bool {
        (try? queryURL(for: configuration)) != nil
    }

    func usage(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> TranslationAccountUsageSnapshot {
        try await usage(configuration: configuration, apiKey: apiKey, timeout: timeout)
    }

    func usage(configuration: TranslationServiceConfiguration, apiKey: String?, timeout: Duration) async throws -> TranslationAccountUsageSnapshot {
        try Task.checkCancellation()
        let deadline = max(.milliseconds(1), min(timeout, .seconds(120)))
        let components = deadline.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let request = try Self.makeRequest(configuration: configuration, apiKey: apiKey, timeout: seconds)
        do {
            return try await withThrowingTaskGroup(of: TranslationAccountUsageSnapshot.self) { group in
                group.addTask {
                    let payload = try await BoundedTranslationHTTPTransport.send(
                        request, session: session, maximumResponseBytes: Self.maximumResponseBytes
                    )
                    try Task.checkCancellation()
                    guard (200...299).contains(payload.status) else {
                        if payload.status == 404 || payload.status == 405 {
                            throw TranslationAccountUsageError.unavailable
                        }
                        if configuration.kind == .deepL && payload.status == 456 {
                            throw RemoteTranslationError.quotaExceeded
                        }
                        throw RemoteTranslationError.http(status: payload.status, body: payload.data)
                    }
                    return try Self.parse(payload.data, kind: configuration.kind)
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    throw RemoteTranslationError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                try Task.checkCancellation()
                return result
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let remote = error as? RemoteTranslationError,
               remote == .invalidResponse || remote == .responseTooLarge {
                throw TranslationAccountUsageError.invalidResponse
            }
            throw error
        }
    }

    static func makeRequest(configuration: TranslationServiceConfiguration, apiKey: String?, timeout: TimeInterval = 20) throws -> URLRequest {
        // Check the destination before reading or placing a key in a request.
        let url = try queryURL(for: configuration)
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw RemoteTranslationError.missingKey }
        guard key.utf8.count <= 8_192,
              !key.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw RemoteTranslationError.invalidKey
        }
        let seconds = timeout.isFinite ? max(0.001, min(timeout, 120)) : 20
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: seconds)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let scheme = configuration.kind == .deepL ? "DeepL-Auth-Key" : "Bearer"
        request.setValue("\(scheme) \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func queryURL(for configuration: TranslationServiceConfiguration) throws -> URL {
        guard let base = try? configuration.validatedEndpoint(),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.port == nil || components.port == 443 else {
            throw TranslationAccountUsageError.unsupportedService
        }
        switch configuration.kind {
        case .deepSeek:
            guard components.host == "api.deepseek.com",
                  ["", "/v1"].contains(components.percentEncodedPath) else {
                throw TranslationAccountUsageError.unsupportedService
            }
            // The balance operation is documented outside the optional v1
            // compatibility prefix; keep the exact approved origin.
            components.path = "/user/balance"
        case .deepL:
            guard ["api.deepl.com", "api-free.deepl.com"].contains(components.host ?? ""),
                  components.percentEncodedPath.isEmpty else {
                throw TranslationAccountUsageError.unsupportedService
            }
            components.path = "/v2/usage"
        default:
            throw TranslationAccountUsageError.unsupportedService
        }
        guard let url = components.url else { throw TranslationAccountUsageError.unsupportedService }
        return url
    }

    static func parse(_ data: Data, kind: TranslationServiceKind, fetchedAt: Date = Date()) throws -> TranslationAccountUsageSnapshot {
        guard data.count <= maximumResponseBytes, fetchedAt.timeIntervalSince1970.isFinite else {
            throw TranslationAccountUsageError.invalidResponse
        }
        do {
            switch kind {
            case .deepSeek:
                let envelope = try JSONDecoder().decode(DeepSeekEnvelope.self, from: data)
                guard envelope.error == nil, !envelope.balanceInfos.isEmpty, envelope.balanceInfos.count <= 2,
                      Set(envelope.balanceInfos.map(\.currency)).count == envelope.balanceInfos.count else {
                    throw TranslationAccountUsageError.invalidResponse
                }
                let balances = try envelope.balanceInfos.map { entry in
                    guard ["CNY", "USD"].contains(entry.currency) else { throw TranslationAccountUsageError.invalidResponse }
                    return TranslationAccountUsageSnapshot.Balance(
                        currency: entry.currency, total: try amount(entry.totalBalance),
                        granted: try entry.grantedBalance.map(amount), toppedUp: try entry.toppedUpBalance.map(amount)
                    )
                }
                return .init(fetchedAt: fetchedAt, balances: balances)
            case .deepL:
                let envelope = try JSONDecoder().decode(DeepLEnvelope.self, from: data)
                guard envelope.error == nil, envelope.characterCount >= 0, envelope.characterLimit >= 0 else {
                    throw TranslationAccountUsageError.invalidResponse
                }
                let unlimited = envelope.characterLimit == 1_000_000_000_000
                return .init(fetchedAt: fetchedAt, usedCharacters: envelope.characterCount,
                             characterLimit: unlimited ? nil : envelope.characterLimit, hasUnlimitedCharacters: unlimited)
            default:
                throw TranslationAccountUsageError.unsupportedService
            }
        } catch let error as TranslationAccountUsageError {
            throw error
        } catch {
            // Never expose decoding errors or vendor-provided response text.
            throw TranslationAccountUsageError.invalidResponse
        }
    }

    private static func amount(_ text: String) throws -> Decimal {
        guard text.range(of: #"^-?[0-9]{1,20}(?:\.[0-9]{1,12})?$"#, options: .regularExpression) == text.startIndex..<text.endIndex,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
            throw TranslationAccountUsageError.invalidResponse
        }
        return value
    }

    private struct NonNullError: Decodable { init(from decoder: any Decoder) throws {} }
    private struct DeepSeekEnvelope: Decodable {
        let isAvailable: Bool
        let balanceInfos: [Entry]
        let error: NonNullError?
        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available", balanceInfos = "balance_infos", error
        }
        struct Entry: Decodable {
            let currency: String
            let totalBalance: String
            let grantedBalance: String?
            let toppedUpBalance: String?
            enum CodingKeys: String, CodingKey {
                case currency, totalBalance = "total_balance", grantedBalance = "granted_balance", toppedUpBalance = "topped_up_balance"
            }
        }
    }
    private struct DeepLEnvelope: Decodable {
        let characterCount: Int
        let characterLimit: Int
        let error: NonNullError?
        enum CodingKeys: String, CodingKey { case characterCount = "character_count", characterLimit = "character_limit", error }
    }
}

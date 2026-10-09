import Foundation
import CoreFoundation
import Observation
import Synchronization

/// Public reference rates. They are estimates, never a provider invoice.
struct TranslationModelPrice: Codable, Equatable, Identifiable, Sendable {
    let provider: String
    let model: String
    let currency: String
    let input: Decimal
    let output: Decimal
    let cacheRead: Decimal?
    let cacheWrite: Decimal?
    let fetchedAt: Date
    let source: String
    var id: String { provider + "/" + model }

    var isValid: Bool {
        ["USD", "CNY"].contains(currency) && !provider.isEmpty && provider.count <= 64
            && !model.isEmpty && model.count <= 256 && source == "models.dev"
            && fetchedAt.timeIntervalSince1970.isFinite
            && [Optional(input), output, cacheRead, cacheWrite].allSatisfy {
                $0.map { !$0.isNaN && $0 >= 0 && $0 <= 1_000_000 } ?? true
            }
    }

    func estimate(_ usage: TranslationUsage?) -> Decimal? {
        guard isValid, let usage, let inputTokens = usage.inputTokens, let outputTokens = usage.outputTokens else { return nil }
        // A discounted cache rate cannot be applied without reported cache counts.
        guard cacheRead == nil || usage.cacheReadTokens != nil,
              cacheWrite == nil || usage.cacheWriteTokens != nil else { return nil }
        let read = usage.cacheReadTokens ?? 0, write = usage.cacheWriteTokens ?? 0
        guard read + write <= inputTokens,
              read == 0 || cacheRead != nil, write == 0 || cacheWrite != nil else { return nil }
        return (Decimal(inputTokens - read - write) * input + Decimal(outputTokens) * output
            + Decimal(read) * (cacheRead ?? 0) + Decimal(write) * (cacheWrite ?? 0)) / 1_000_000
    }
}

enum TranslationPricingError: Error { case unavailable, invalidData, tooLarge }

/// A translation price list is not a directory of every reseller of a model.
/// Select one official catalog per family; retain exact model IDs for billing.
nonisolated enum TranslationPriceCatalogScope {
    static let providers = ["deepseek", "openai", "anthropic", "google", "xai", "alibaba",
                            "moonshotai", "zai", "minimax-cn", "mistral", "xiaomi", "longcat"]
    private static let nonTextMarkers = ["audio", "deprecated", "embedding", "image", "moderation",
                                         "realtime", "transcribe", "tts", "video"]

    static func isTextModel(_ model: String, metadata: [String: Any] = [:]) -> Bool {
        guard (metadata["status"] as? String)?.lowercased() != "deprecated" else { return false }
        if let modalities = metadata["modalities"] as? [String: Any],
           let output = modalities["output"] as? [String], !output.isEmpty {
            let kinds = Set(output.map { $0.lowercased() })
            guard kinds.contains("text"), kinds.isDisjoint(with: ["audio", "image", "video"]) else { return false }
        }
        let name = (model + " " + (metadata["name"] as? String ?? "")).lowercased()
        return !nonTextMarkers.contains(where: name.contains)
    }

    /// Also migrate old caches, which included thousands of gateway duplicates.
    /// Historical request snapshots are separate and must never be rewritten here.
    static func select(_ prices: [TranslationModelPrice]) -> [TranslationModelPrice] {
        var unique: [String: TranslationModelPrice] = [:]
        for price in prices where price.isValid && price.currency == "USD"
            && providers.contains(price.provider) && isTextModel(price.model) {
            if let previous = unique[price.id], previous.fetchedAt >= price.fetchedAt { continue }
            unique[price.id] = price
        }
        return unique.values.sorted {
            let left = providers.firstIndex(of: $0.provider)!, right = providers.firstIndex(of: $1.provider)!
            return left == right ? $0.model < $1.model : left < right
        }
    }
}

/// An explicit, unauthenticated fetch to one fixed public catalog. No accounts,
/// configured endpoints, request text, or credentials are sent to this host.
nonisolated struct TranslationPriceCatalogLoader: Sendable {
    static let endpoint = URL(string: "https://models.dev/api.json")!
    static let maximumBytes = 16 * 1_024 * 1_024

    func load(now: Date = Date(), session injectedSession: URLSession? = nil) async throws -> [TranslationModelPrice] {
        let config = TranslationHTTPPolicy.sessionConfiguration()
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = injectedSession ?? URLSession(configuration: config)
        defer { if injectedSession == nil { session.invalidateAndCancel() } }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request, delegate: TranslationRedirectGuard())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == Self.endpoint,
              http.statusCode == 200, http.mimeType?.lowercased() == "application/json" else { throw TranslationPricingError.unavailable }
        guard http.expectedContentLength <= Self.maximumBytes else { throw TranslationPricingError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw TranslationPricingError.tooLarge }
            data.append(byte)
        }
        return try Self.decode(data, now: now)
    }

    static func decode(_ data: Data, now: Date) throws -> [TranslationModelPrice] {
        guard data.count <= maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TranslationPricingError.invalidData }
        var result: [TranslationModelPrice] = []
        // models.dev documents these rates in USD per million tokens. Do not
        // relabel them as CNY or infer regional/provider rates from a model name.
        guard root.count <= 1_000 else { throw TranslationPricingError.invalidData }
        for provider in TranslationPriceCatalogScope.providers {
            guard let entry = root[provider] as? [String: Any],
                  let models = entry["models"] as? [String: [String: Any]], models.count <= 5_000 else { continue }
            for (model, value) in models {
                guard TranslationPriceCatalogScope.isTextModel(model, metadata: value),
                      let cost = value["cost"] as? [String: Any],
                      let input = decimal(cost["input"]), let output = decimal(cost["output"]) else { continue }
                // Long-context tiered rates require additional context. Leave
                // these entries unpriced rather than silently use a base tier.
                guard !cost.keys.contains(where: { $0.hasPrefix("context_over_") }) else { continue }
                let read = decimal(cost["cache_read"]), write = decimal(cost["cache_write"])
                guard (cost["cache_read"] == nil || read != nil), (cost["cache_write"] == nil || write != nil),
                      cost["reasoning"] == nil || decimal(cost["reasoning"]) == output else { continue }
                let price = TranslationModelPrice(provider: provider, model: model, currency: "USD", input: input,
                    output: output, cacheRead: read, cacheWrite: write,
                    fetchedAt: now, source: "models.dev")
                if price.isValid { result.append(price) }
                guard result.count <= 20_000 else { throw TranslationPricingError.tooLarge }
            }
        }
        guard !result.isEmpty else { throw TranslationPricingError.invalidData }
        return TranslationPriceCatalogScope.select(result)
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 1_000_000 else { return nil }
        return value.decimalValue
    }
}

@MainActor @Observable
final class TranslationUsagePricing {
    static let storageKey = "preferences.translationUsage.prices"
    private(set) var prices: [TranslationModelPrice] = []
    private(set) var loading = false
    private(set) var failed = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), data.count <= 8 * 1_024 * 1_024,
           let saved = try? JSONDecoder().decode([TranslationModelPrice].self, from: data), saved.count <= 20_000 {
            prices = TranslationPriceCatalogScope.select(saved)
            if prices != saved, let cleaned = try? JSONEncoder().encode(prices) {
                defaults.set(cleaned, forKey: Self.storageKey)
            }
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !loading else { return false }
        loading = true; failed = false
        defer { loading = false }
        do {
            let loaded = try await TranslationPriceCatalogLoader().load()
            try Task.checkCancellation()
            guard installReferencePrices(loaded) else { throw TranslationPricingError.invalidData }
            return true
        } catch {
            if !Task.isCancelled { failed = true }
            return false
        }
    }

    /// One validated cache transaction, shared by the fetch path and isolated QA fixtures.
    @discardableResult
    func installReferencePrices(_ values: [TranslationModelPrice]) -> Bool {
        let selected = TranslationPriceCatalogScope.select(values)
        guard values.count <= 20_000, values.allSatisfy(\.isValid),
              !selected.isEmpty,
              let data = try? JSONEncoder().encode(selected), data.count <= 8 * 1_024 * 1_024 else { return false }
        prices = selected
        defaults.set(data, forKey: Self.storageKey)
        return true
    }

    func price(for configuration: TranslationServiceConfiguration, model: String) -> TranslationModelPrice? {
        guard let provider = Self.provider(for: configuration) else { return nil }
        return prices.first { $0.provider == provider && $0.model == model }
    }

    static func provider(for configuration: TranslationServiceConfiguration) -> String? {
        // A custom proxy may use an entirely different tariff even with the
        // same model ID. Only the explicitly selected official provider matches.
        let expected: (String, String)
        switch configuration.kind {
        case .openAI: expected = ("openai", "api.openai.com")
        case .deepSeek: expected = ("deepseek", "api.deepseek.com")
        case .claude: expected = ("anthropic", "api.anthropic.com")
        default: return nil
        }
        guard let url = URL(string: configuration.endpoint), url.scheme == "https", url.host == expected.1,
              url.port == nil || url.port == 443 else { return nil }
        return expected.0
    }
}

/// Task-scoped numeric response metadata survives provider error mapping without
/// wrapping errors or recording bodies. Child requests never share global state.
nonisolated final class TranslationUsageHTTPResponse: Sendable {
    private let storage = Mutex<Int?>(nil)
    func record(_ code: Int) { if (100...599).contains(code) { storage.withLock { $0 = code } } }
    var status: Int? { storage.withLock { $0 } }
}

nonisolated enum TranslationUsageHTTPContext {
    @TaskLocal static var response: TranslationUsageHTTPResponse?
    static func record(status: Int) { response?.record(status) }
}

/// Display rounding never changes persisted or accumulated Decimal amounts.
enum UsageCostFormat {
    static func compact(_ amount: Decimal?) -> String {
        guard let amount, !amount.isNaN, amount >= 0 else { return L10n.string("Unpriced") }
        if amount == 0 { return "$0.00" }
        if amount < Decimal(string: "0.0001")! { return "<$0.0001" }
        return "$" + amount.formatted(.number.precision(.fractionLength(2...(amount >= 1 ? 2 : 4))).locale(Locale(identifier: "en_US")))
    }

    static func precise(_ amount: Decimal) -> String { "$" + NSDecimalNumber(decimal: amount).stringValue }
}

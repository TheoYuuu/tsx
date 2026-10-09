import Foundation
import XCTest
@testable import TranslateX

@MainActor
final class TranslationUsageDashboardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func defaults() throws -> UserDefaults {
        let domain = "TranslateX.dashboard-tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        return try XCTUnwrap(UserDefaults(suiteName: domain))
    }
    private func price(currency: String = "USD", input: Decimal = 2, output: Decimal = 4,
                       read: Decimal? = nil, write: Decimal? = nil) -> TranslationModelPrice {
        .init(provider: "openai", model: "fixture", currency: currency, input: input, output: output,
              cacheRead: read, cacheWrite: write, fetchedAt: now, source: "models.dev")
    }
    private func record(id: UUID?, price: TranslationModelPrice? = nil, usage: TranslationUsage? = nil,
                        date: Date? = nil) -> TranslationUsageRecord {
        .init(id: UUID(), configurationID: id, model: "fixture", purpose: .translation,
              outcome: .succeeded, completedAt: date ?? now, duration: 1, usage: usage, priceSnapshot: price)
    }

    func testDailyChartMetricsPreserveExactSmallCostsAndDistinguishMissingValues() throws {
        let id = UUID()
        let measured = record(id: id, price: price(input: 2, output: 4), usage: .init(inputTokens: 1, outputTokens: 2))
        let missing = record(id: id)
        let local = record(id: nil)
        let data = TranslationUsageDashboard(records: [measured, missing, local], summaries: [], start: now, end: now)
        let day = try XCTUnwrap(data.days.first)
        XCTAssertEqual(UsageChartMetric.requests.value(in: day), 3)
        XCTAssertEqual(UsageChartMetric.tokens.value(in: day), 3)
        XCTAssertEqual(UsageChartMetric.fees.value(in: day), Decimal(string: "0.00001"))
        XCTAssertTrue(UsageChartMetric.fees.isPartial(in: day))
        XCTAssertTrue(UsageChartMetric.tokens.isPartial(in: day))
        XCTAssertFalse(UsageChartMetric.requests.isPartial(in: day))
        let unknown = TranslationUsageDashboard(records: [missing], summaries: [], start: now, end: now).days.first
        XCTAssertNil(UsageChartMetric.fees.value(in: unknown))
        XCTAssertNil(UsageChartMetric.tokens.value(in: unknown))
        let foreign = TranslationUsageDashboard(records: [record(id: id, price: price(currency: "CNY"),
            usage: .init(inputTokens: 1, outputTokens: 2))], summaries: [], start: now, end: now).days.first
        XCTAssertNil(UsageChartMetric.fees.value(in: foreign), "A fully priced non-USD day must not become zero dollars")
        let localDay = TranslationUsageDashboard(records: [local], summaries: [], start: now, end: now).days.first
        for metric in UsageChartMetric.allCases {
            XCTAssertEqual(metric.value(in: nil), 0, "An empty day is a real zero")
            XCTAssertFalse(metric.isPartial(in: localDay))
        }
        XCTAssertEqual(UsageChartMetric.fees.value(in: localDay), 0)
        XCTAssertEqual(UsageChartMetric.tokens.value(in: localDay), 0)
    }

    func testDollarFormattingPreservesSmallNonzeroAmountsAndExactDetail() {
        for (raw, displayed) in [("0", "$0.00"), ("0.00000012", "<$0.0001"), ("0.0001", "$0.0001"),
                                 ("0.001248", "$0.0012"), ("0.15", "$0.15"), ("1.23456", "$1.23"), ("16079.77", "$16,079.77")] {
            XCTAssertEqual(UsageCostFormat.compact(Decimal(string: raw)), displayed)
        }
        XCTAssertEqual(UsageCostFormat.precise(Decimal(string: "0.000056592")!), "$0.000056592")
        XCTAssertNotEqual(UsageCostFormat.compact(nil), "$0.00")
        let oldCNY = record(id: UUID(), price: price(currency: "CNY"), usage: .init(inputTokens: 100, outputTokens: 20))
        XCTAssertNotNil(oldCNY.estimatedCost)
        XCTAssertNil(oldCNY.estimatedUSD, "Never relabel a saved CNY amount as dollars without an exchange rate.")
    }

    func testRefreshingPricesBackfillsOnlyMissingEstimatesAndPersistsTheirBasis() throws {
        let defaults = try defaults(), id = UUID(), proxyID = UUID()
        let store = TranslationUsageStore(defaults: defaults, now: now)
        let config = TranslationServiceConfiguration(id: id, name: "Fixture", kind: .openAI, endpoint: "https://api.openai.com/v1", model: "fixture")
        store.registerConfigurations([config, .init(id: proxyID, name: "Proxy", kind: .openAICompatible, endpoint: "https://example.invalid/v1", model: "fixture")])
        store.finish(store.begin(configurationID: id, model: "fixture", purpose: .translation, now: now), outcome: .succeeded,
                     usage: .init(inputTokens: 1_000_000, outputTokens: 0), now: now)
        store.finish(store.begin(configurationID: id, model: "fixture", purpose: .translation, now: now), outcome: .failed, now: now)
        store.finish(store.begin(configurationID: proxyID, model: "fixture", purpose: .translation, now: now), outcome: .succeeded,
                     usage: .init(inputTokens: 100, outputTokens: 20), now: now)
        // Changing a proxy to an official endpoint must not reprice its earlier requests.
        store.registerConfigurations([config, .init(id: proxyID, name: "Changed proxy", kind: .openAI,
                                                   endpoint: "https://api.openai.com/v1", model: "fixture")])
        XCTAssertTrue(store.pricing.installReferencePrices([price(input: 2)]))
        XCTAssertEqual(store.backfillMissingCosts(), 1)
        let priced = try XCTUnwrap(store.records.first { $0.estimatedCost != nil })
        XCTAssertEqual(priced.estimatedCost, 2)
        XCTAssertEqual(priced.priceBackfilled, true)
        XCTAssertTrue(store.pricing.installReferencePrices([price(input: 20)]))
        XCTAssertEqual(store.backfillMissingCosts(), 0)
        XCTAssertEqual(store.records.first { $0.id == priced.id }?.estimatedCost, 2)
        let restored = TranslationUsageStore(defaults: defaults, now: now)
        XCTAssertEqual(restored.records.first { $0.id == priced.id }?.priceBackfilled, true)
        XCTAssertNil(restored.records.first { $0.configurationID == proxyID }?.estimatedCost)
    }

    func testLegacyBackfillRequiresUnchangedModelAndOfficialCurrentConfiguration() throws {
        let defaults = try defaults(), id = UUID(), changed = UUID()
        let rows = [record(id: id, usage: .init(inputTokens: 10, outputTokens: 20)), record(id: changed, usage: .init(inputTokens: 10, outputTokens: 20))]
        defaults.set(try JSONEncoder().encode(TranslationUsageStore.Snapshot(records: rows, summaries: [])), forKey: TranslationUsageStore.StorageKey.snapshot)
        let store = TranslationUsageStore(defaults: defaults, now: now)
        store.registerConfigurations([
            .init(id: id, name: "Fixture", kind: .openAI, endpoint: "https://api.openai.com/v1", model: "fixture"),
            .init(id: changed, name: "Changed", kind: .openAI, endpoint: "https://api.openai.com/v1", model: "different")])
        XCTAssertTrue(store.pricing.installReferencePrices([price()]))
        XCTAssertEqual(store.backfillMissingCosts(), 1)
        XCTAssertNil(store.records.first { $0.configurationID == changed }?.estimatedCost)
    }

    func testOriginalCurrenciesStaySeparateAndAppleNeverAddsAPITokens() {
        let id = UUID(), counters = TranslationUsage(inputTokens: 1_000_000, outputTokens: 0)
        let rows = [record(id: nil, usage: counters), record(id: id, price: price(), usage: counters),
                    record(id: id, price: price(currency: "CNY", input: 3), usage: counters), record(id: id)]
        let data = TranslationUsageDashboard(records: rows, summaries: [], start: now, end: now)
        XCTAssertEqual(data.all.requests, 4)
        XCTAssertEqual(data.api.requests, 3)
        XCTAssertEqual(data.api.totalTokens, 2_000_000)
        XCTAssertEqual(data.api.costs, ["USD": 2, "CNY": 3])
        XCTAssertEqual(data.unknownCosts, 1)
        XCTAssertEqual(data.unknownTokens, 1)
        XCTAssertEqual(rows.first?.estimatedCost, 0)
        XCTAssertNil(rows.last?.estimatedCost)
        XCTAssertNil(rows.last?.httpStatus, "Success is not evidence of HTTP 200.")
    }

    func testDailySummariesAndRequestDetailsAreCombinedWithoutInventingRows() {
        let id = UUID(), date = Calendar.current.startOfDay(for: now)
        let older = Calendar.current.date(byAdding: .day, value: -40, to: date)!
        var totals = TranslationUsageTotals()
        totals.add(record(id: id, price: price(), usage: .init(inputTokens: 1_000_000, outputTokens: 0), date: older))
        let summary = TranslationUsageDay(configurationID: id, model: "fixture", purpose: .translation, day: older, totals: totals)
        let data = TranslationUsageDashboard(records: [record(id: id)], summaries: [summary], start: older, end: now)
        XCTAssertEqual(data.all.requests, 2)
        XCTAssertEqual(data.records.count, 1)
        XCTAssertEqual(data.summarizedRequests, 1)
        XCTAssertEqual(data.api.costs?["USD"], 2)
        let local = TranslationUsageDashboard(records: [record(id: nil), record(id: id)], summaries: [summary], start: older, end: now, service: "apple")
        XCTAssertEqual(local.all.requests, 1)
        XCTAssertEqual(local.api.requests, 0)
        XCTAssertNil(local.api.totalTokens)
    }

    func testRangeIsInclusiveByDayAndServiceFilterIsExact() {
        let id = UUID(), other = UUID(), start = Calendar.current.startOfDay(for: now)
        let rows = [record(id: id, date: start), record(id: id, date: start.addingTimeInterval(-1)),
                    record(id: other, date: start), record(id: id, date: Calendar.current.date(byAdding: .day, value: 1, to: start)!)]
        let data = TranslationUsageDashboard(records: rows, summaries: [], start: start, end: start, service: id.uuidString)
        XCTAssertEqual(data.records.count, 1)
        XCTAssertEqual(data.all.requests, 1)
    }

    func testAnthropicCacheInputNormalizedOnceAndPricedWithCorrectSplit() throws {
        let usage = try XCTUnwrap(TranslationUsage.reportedTokens([
            "input_tokens": 100, "output_tokens": 40, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 30
        ], inputKey: "input_tokens", outputKey: "output_tokens"))
        XCTAssertEqual(usage.inputTokens, 150)
        XCTAssertEqual(usage.reportedTokenTotal, 190)
        let amount = price(input: 2, output: 4, read: 1, write: 3).estimate(usage)
        XCTAssertEqual(amount, Decimal(string: "0.00047"))
        let openAI = TranslationUsage.reportedTokens(["prompt_tokens": 150, "completion_tokens": 40, "prompt_tokens_details": ["cached_tokens": 20]])
        XCTAssertEqual(openAI?.inputTokens, 150, "OpenAI input already includes cached input.")
        XCTAssertNil(price(read: 1).estimate(.init(inputTokens: 150, outputTokens: 40)), "Absent cache metadata remains unknown.")
        XCTAssertNil(price(read: 1).estimate(.init(inputTokens: 10, outputTokens: 0, cacheReadTokens: 20)))
        XCTAssertNil(TranslationUsage.reportedTokens(["input_tokens": 100, "cache_read_input_tokens": -1], inputKey: "input_tokens")?.inputTokens)
    }

    func testAnthropicStreamKeepsCacheSplitAcrossCumulativeDeltas() throws {
        var parser = ClaudeTranslationResponseParser()
        _ = try parser.consume(Data(#"{"type":"message_start","message":{"type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":20,"cache_creation_input_tokens":30}}}"#.utf8))
        _ = try parser.consume(Data(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"fixture"}}"#.utf8))
        _ = try parser.consume(Data(#"{"type":"content_block_stop","index":0}"#.utf8))
        _ = try parser.consume(Data(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":100,"output_tokens":40}}"#.utf8))
        _ = try parser.consume(Data(#"{"type":"message_stop"}"#.utf8))
        XCTAssertEqual(parser.usage?.inputTokens, 150)
        XCTAssertEqual(parser.usage?.outputTokens, 40)
        XCTAssertEqual(parser.usage?.cacheReadTokens, 20)
        XCTAssertEqual(parser.usage?.cacheWriteTokens, 30)
    }

    func testCatalogUsesDeclaredUSDUnitsAndRejectsInvalidAndTieredRates() throws {
        let json = #"{"openai":{"models":{"good":{"cost":{"input":2,"output":4,"cache_read":0.5}},"bad":{"cost":{"input":true,"output":4}},"tiered":{"cost":{"input":2,"output":4,"context_over_200k":{"input":3}}}}},"custom":{"models":{"another":{"cost":{"input":0,"output":1}}}}}"#
        let prices = try TranslationPriceCatalogLoader.decode(Data(json.utf8), now: now)
        XCTAssertEqual(prices.count, 1)
        XCTAssertEqual(Set(prices.map(\.currency)), ["USD"])
        XCTAssertEqual(prices.first { $0.model == "good" }?.cacheRead, Decimal(string: "0.5"))
        XCTAssertNil(prices.first { $0.provider == "custom" }, "Arbitrary catalog providers are not official reference rates.")
    }

    func testCatalogExcludesResellersDeprecatedAndNonTextModelsButKeepsExactOfficialIDs() throws {
        let models: [String: Any] = [
            "chat-model": ["cost": ["input": 2, "output": 4], "modalities": ["output": ["text"]]],
            "chat-model-2026-09-01": ["cost": ["input": 3, "output": 6]],
            "old-chat": ["cost": ["input": 1, "output": 2], "status": "deprecated"],
            "render-model": ["cost": ["input": 1, "output": 2], "modalities": ["output": ["image"]]],
            "mixed-model": ["cost": ["input": 1, "output": 2], "modalities": ["output": ["text", "audio"]]],
            "text-embedding": ["cost": ["input": 1, "output": 0]],
            "named-model": ["cost": ["input": 1, "output": 2], "name": "Realtime Model"]
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "openai": ["models": models], "abacus": ["models": models], "openrouter": ["models": models]
        ])
        let prices = try TranslationPriceCatalogLoader.decode(data, now: now)
        XCTAssertEqual(prices.map(\.id), ["openai/chat-model", "openai/chat-model-2026-09-01"])
        XCTAssertEqual(prices.map(\.input), [2, 3], "Dated models and aliases can have different tariffs; never merge by fuzzy name.")
    }

    func testLegacyCatalogCacheIsPrunedAndDeduplicatedWithoutChangingRecordedCosts() throws {
        let defaults = try defaults()
        let reference = price(input: 2)
        let reseller = TranslationModelPrice(provider: "abacus", model: reference.model, currency: "USD", input: 99,
            output: 99, cacheRead: nil, cacheWrite: nil, fetchedAt: now, source: "models.dev")
        let embedding = TranslationModelPrice(provider: "openai", model: "text-embedding", currency: "USD", input: 1,
            output: 0, cacheRead: nil, cacheWrite: nil, fetchedAt: now, source: "models.dev")
        let legacy = [reseller, reference, embedding, reference, price(currency: "CNY")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: TranslationUsagePricing.storageKey)
        let pricing = TranslationUsagePricing(defaults: defaults)
        XCTAssertEqual(pricing.prices, [reference])
        let persisted = try JSONDecoder().decode([TranslationModelPrice].self, from: XCTUnwrap(defaults.data(forKey: TranslationUsagePricing.storageKey)))
        XCTAssertEqual(persisted, [reference])
        XCTAssertFalse(pricing.installReferencePrices([reseller]))
        XCTAssertEqual(pricing.prices, [reference], "An unsuitable refresh must not erase existing reference prices.")
    }

    func testOfficialMatchingDoesNotPriceAnArbitraryCompatibleProxy() throws {
        var configuration = TranslationServiceConfiguration(name: "Fixture", kind: .openAI, endpoint: "https://api.openai.com/v1", model: "fixture")
        XCTAssertEqual(TranslationUsagePricing.provider(for: configuration), "openai")
        configuration.endpoint = "https://proxy.example/v1"
        XCTAssertNil(TranslationUsagePricing.provider(for: configuration))
        configuration.endpoint = "https://api.openai.com/v1"; configuration.kind = .openAICompatible
        XCTAssertNil(TranslationUsagePricing.provider(for: configuration))
    }

    func testOldSnapshotsLoadWithoutInventingPricesOrHTTPStatus() throws {
        let defaults = try defaults()
        let store = TranslationUsageStore(defaults: defaults, now: now)
        store.finish(store.begin(configurationID: UUID(), model: "fixture", purpose: .translation, now: now), outcome: .succeeded, usage: .init(inputTokens: 1, outputTokens: 1), now: now)
        store.flush()
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: TranslationUsageStore.StorageKey.snapshot))) as? [String: Any])
        payload["version"] = 1
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: TranslationUsageStore.StorageKey.snapshot)
        let migrated = TranslationUsageStore(defaults: defaults, now: now)
        XCTAssertEqual(migrated.records.count, 1)
        XCTAssertNil(migrated.records.first?.priceSnapshot)
        XCTAssertNil(migrated.records.first?.httpStatus)
        XCTAssertNil(migrated.records.first?.estimatedCost)
    }

    func testHistoricalPriceSnapshotSurvivesNewCatalogAndPersistence() throws {
        let defaults = try defaults(), id = UUID()
        defaults.set(try JSONEncoder().encode([price(input: 2)]), forKey: TranslationUsagePricing.storageKey)
        let store = TranslationUsageStore(defaults: defaults, now: now)
        store.registerConfigurations([.init(id: id, name: "Fixture", kind: .openAI, endpoint: "https://api.openai.com/v1", model: "fixture")])
        let ticket = store.begin(configurationID: id, model: "fixture", purpose: .translation, now: now)
        store.finish(ticket, outcome: .succeeded, usage: .init(inputTokens: 1_000_000, outputTokens: 0), httpStatus: 200, now: now)
        store.flush()
        defaults.set(try JSONEncoder().encode([price(input: 20)]), forKey: TranslationUsagePricing.storageKey)
        let restored = TranslationUsageStore(defaults: defaults, now: now)
        XCTAssertEqual(restored.pricing.prices.first?.input, 20)
        XCTAssertEqual(restored.records.first?.estimatedCost, 2)
        XCTAssertEqual(restored.records.first?.httpStatus, 200)
        XCTAssertEqual(restored.records.first?.serviceName, "Fixture")
    }

    func testTaskLocalHTTPMetadataDoesNotLeakAcrossRequests() async throws {
        let store = TranslationUsageStore(defaults: try defaults()), id = UUID()
        let request = TranslationRequest(id: UUID(), text: "fixture", source: "en", target: "zh-Hans")
        let withStatus = UsageRecordingTranslationProvider(base: HTTPFixture(status: 429), store: store, configurationID: id, model: "fixture")
        _ = try? await withStatus.translate(request)
        XCTAssertEqual(store.records.last?.httpStatus, 429)
        let noStatus = UsageRecordingTranslationProvider(base: HTTPFixture(status: nil), store: store, configurationID: id, model: "fixture")
        _ = try? await noStatus.translate(request)
        XCTAssertNil(store.records.last?.httpStatus)
        XCTAssertNil(TranslationUsageHTTPContext.response)
    }
}

@MainActor
private struct HTTPFixture: TranslationProvider {
    let status: Int?
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        if let status { TranslationUsageHTTPContext.record(status: status) }
        throw URLError(.cannotConnectToHost)
    }
}

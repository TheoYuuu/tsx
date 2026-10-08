import Foundation
import XCTest
@testable import TranslateX

@MainActor
final class TranslationUsageStoreTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let domain = "TranslateX.usage-tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        return try XCTUnwrap(UserDefaults(suiteName: domain))
    }

    func testRecordsPersistWithoutTextAndMissingUsageStaysUnknown() throws {
        let defaults = try defaults(), now = Date(), id = UUID()
        let store = TranslationUsageStore(defaults: defaults)
        let ticket = store.begin(configurationID: id, model: "fixture-model", purpose: .translation, now: now.addingTimeInterval(-2))
        store.finish(ticket, outcome: .succeeded, now: now)
        store.finish(ticket, outcome: .failed, now: now)
        store.flush()
        let restored = TranslationUsageStore(defaults: defaults, now: now)
        XCTAssertEqual(restored.records.count, 1)
        XCTAssertNil(restored.records.first?.usage)
        XCTAssertEqual(restored.records.first?.duration, 2)
        XCTAssertEqual(restored.records.first?.configurationID, id)
        let data = try XCTUnwrap(defaults.data(forKey: TranslationUsageStore.StorageKey.records))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(rows.first).keys), Set(["id", "configurationID", "model", "purpose", "outcome", "completedAt", "duration"]))
    }

    func testDisableAndReenableDoNotResurrectInFlightRecords() throws {
        let defaults = try defaults(), store = TranslationUsageStore(defaults: defaults)
        let old = store.begin(configurationID: nil, model: "", purpose: .translation)
        store.setEnabled(false)
        XCTAssertNil(store.begin(configurationID: nil, model: "", purpose: .translation))
        store.setEnabled(true)
        store.finish(old, outcome: .succeeded)
        XCTAssertTrue(store.records.isEmpty)
        store.setEnabled(false)
        XCTAssertFalse(TranslationUsageStore(defaults: defaults).isEnabled)
    }

    func testClearOneServiceSuppressesOnlyItsPendingRequests() throws {
        let store = TranslationUsageStore(defaults: try defaults()), id = UUID()
        let cloud = store.begin(configurationID: id, model: "fixture", purpose: .translation)
        let apple = store.begin(configurationID: nil, model: "", purpose: .translation)
        store.clear(configurationID: id)
        store.finish(cloud, outcome: .succeeded)
        store.finish(apple, outcome: .succeeded)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertNil(store.records.first?.configurationID)
    }

    func testClearCannotBeUndoneByBackgroundPersistenceOrLateCompletion() async throws {
        let defaults = try defaults(), store = TranslationUsageStore(defaults: defaults)
        let pending = store.begin(configurationID: nil, model: "", purpose: .translation)
        store.finish(store.begin(configurationID: nil, model: "", purpose: .sampleTest), outcome: .succeeded)
        store.clearAll()
        store.finish(pending, outcome: .failed)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: TranslationUsageStore.StorageKey.records))
    }

    func testRetentionDropsExpiredInvalidDuplicateAndExcessRecords() throws {
        let defaults = try defaults(), now = Date(), id = UUID()
        let valid = TranslationUsageRecord(id: id, configurationID: nil, model: "", purpose: .translation,
            outcome: .succeeded, completedAt: now, duration: 1, usage: nil)
        let expired = TranslationUsageRecord(id: UUID(), configurationID: nil, model: "", purpose: .translation,
            outcome: .succeeded, completedAt: now.addingTimeInterval(-TranslationUsageStore.retention - 1), duration: 1, usage: nil)
        let future = TranslationUsageRecord(id: UUID(), configurationID: nil, model: "", purpose: .translation,
            outcome: .succeeded, completedAt: now.addingTimeInterval(1), duration: 1, usage: nil)
        var rows = [valid, valid, expired, future]
        rows += (0..<TranslationUsageStore.maximumRecords).map { offset in
            TranslationUsageRecord(id: UUID(), configurationID: nil, model: String(repeating: "译", count: 256), purpose: .translation,
                outcome: .succeeded, completedAt: now.addingTimeInterval(-Double(offset + 1)), duration: 1, usage: nil)
        }
        let encoded = try JSONEncoder().encode(rows)
        XCTAssertGreaterThan(encoded.count, 8 * 1_024 * 1_024, "Valid long model metadata must survive reload.")
        XCTAssertLessThan(encoded.count, TranslationUsageStore.maximumStorageBytes)
        defaults.set(encoded, forKey: TranslationUsageStore.StorageKey.records)
        let store = TranslationUsageStore(defaults: defaults, now: now)
        XCTAssertEqual(store.records.count, TranslationUsageStore.maximumRecords)
        XCTAssertEqual(store.records.filter { $0.id == id }.count, 1)
        XCTAssertFalse(store.records.contains { $0.id == expired.id || $0.id == future.id })
    }

    func testDayRangeAndConfigurationFiltersKeepSampleTestsDistinct() throws {
        let now = Date(), id = UUID(), store = TranslationUsageStore(defaults: try defaults())
        for daysAgo in [10, 3, 0] {
            let date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            store.finish(store.begin(configurationID: id, model: "fixture", purpose: daysAgo == 3 ? .sampleTest : .translation, now: date),
                outcome: .succeeded, usage: .init(totalTokens: 12), now: date)
        }
        XCTAssertEqual(store.records(for: id, days: 7, now: now).count, 2)
        XCTAssertEqual(store.records(for: id, days: 30, now: now).count, 3)
        XCTAssertEqual(store.records(for: id, days: 7, now: now).filter { $0.purpose == .sampleTest }.count, 1)
        XCTAssertTrue(store.records(for: nil, days: 30, now: now).isEmpty)
    }

    func testProviderWrapperPreservesResultAndOnlyRecordsNumericMetadata() async throws {
        let defaults = try defaults(), store = TranslationUsageStore(defaults: defaults)
        let provider = UsageFixtureProvider()
        let wrapper = UsageRecordingTranslationProvider(base: provider, store: store, configurationID: UUID(), model: "fixture")
        let request = TranslationRequest(id: UUID(), text: "constructed private source", source: "en", target: "zh-Hans")
        let result = try await wrapper.translate(request)
        XCTAssertEqual(provider.requests, [request])
        XCTAssertEqual(result.text, "constructed private result")
        XCTAssertEqual(store.records.first?.usage?.totalTokens, 12)
        store.flush()
        let serialized = String(decoding: try XCTUnwrap(defaults.data(forKey: TranslationUsageStore.StorageKey.records)), as: UTF8.self)
        XCTAssertFalse(serialized.contains("private"))
        XCTAssertEqual(store.records.first?.purpose, .translation)
    }

    func testFailureAndCancellationRemainOriginalErrorsWithUnknownCharges() async throws {
        for error in [RemoteTranslationError.quotaExceeded as any Error, CancellationError()] {
            let store = TranslationUsageStore(defaults: try defaults()), provider = UsageFixtureProvider()
            provider.failure = error
            let wrapper = UsageRecordingTranslationProvider(base: provider, store: store, configurationID: UUID(), model: "fixture", purpose: .sampleTest)
            do {
                _ = try await wrapper.translate(.init(id: UUID(), text: "sample", source: "en", target: "zh-Hans"))
                XCTFail("Expected original failure")
            } catch let received {
                XCTAssertEqual(received is CancellationError, error is CancellationError)
                if let expected = error as? RemoteTranslationError { XCTAssertEqual(received as? RemoteTranslationError, expected) }
            }
            XCTAssertNil(store.records.first?.usage)
            XCTAssertEqual(store.records.first?.outcome, error is CancellationError ? .cancelled : .failed)
            XCTAssertEqual(store.records.first?.purpose, .sampleTest)
        }
    }

    func testWebsiteValidationMigrationAndRequestIdentity() throws {
        var config = TranslationServiceConfiguration(kind: .deepSeek)
        let original = config
        config.website = "https://example.com/dashboard"
        XCTAssertTrue(TranslationServiceStore.sameRequest(config, original))
        XCTAssertEqual(try config.validated().websiteURL?.host, "example.com")
        for invalid in ["javascript:alert(1)", "file:///tmp/a", "https://secret@example.com", "https://example.com?key=secret", "https://example.com/#secret", "https://exa mple.com"] {
            config.website = invalid
            XCTAssertNil(config.websiteURL)
            XCTAssertThrowsError(try config.validated()) { XCTAssertEqual($0 as? TranslationServiceConfigurationError, .invalidWebsite) }
        }
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        oldJSON.removeValue(forKey: "website")
        let restored = try JSONDecoder().decode(TranslationServiceConfiguration.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.websiteURL?.host, "platform.deepseek.com")
    }
}

@MainActor private final class UsageFixtureProvider: TranslationProvider {
    var requests: [TranslationRequest] = []
    var failure: (any Error)?
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requests.append(request)
        if let failure { throw failure }
        return .init(text: "constructed private result", source: "en", target: "zh-Hans", usage: .init(totalTokens: 12))
    }
}

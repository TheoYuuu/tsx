import Foundation
import Synchronization
import XCTest
@testable import TranslateX

@MainActor
final class TranslationAccountUsageTests: XCTestCase {
    func testVerifiedDestinationsAndProviderSpecificAuthorization() throws {
        for endpoint in ["https://api.deepseek.com", "https://api.deepseek.com/v1", "https://api.deepseek.com/v1/"] {
            var configuration = TranslationServiceConfiguration(kind: .deepSeek)
            configuration.endpoint = endpoint
            XCTAssertTrue(TranslationAccountUsageLoader.supports(configuration))
            let request = try TranslationAccountUsageLoader.makeRequest(configuration: configuration, apiKey: " fixture-key \n")
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
        }
        for endpoint in DeepLAPIEndpoint.allCases {
            var configuration = TranslationServiceConfiguration(kind: .deepL)
            configuration.endpoint = endpoint.rawValue
            let request = try TranslationAccountUsageLoader.makeRequest(configuration: configuration, apiKey: "fixture-key")
            XCTAssertEqual(request.url?.absoluteString, endpoint.rawValue + "/v2/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "DeepL-Auth-Key fixture-key")
        }
    }

    func testCustomEndpointsCannotReceiveAccountQueryKeys() {
        for endpoint in [
            "https://proxy.example", "https://api.deepseek.com.proxy.example", "https://api.deepseek.com:444",
            "https://api.deepseek.com/custom", "https://api.deepseek.com/%76%31", "http://127.0.0.1",
            "https://api.deepseek.com?key=fixture", "https://user:password@api.deepseek.com", "https://api.deepseek.com#fragment"
        ] {
            var configuration = TranslationServiceConfiguration(kind: .deepSeek)
            configuration.endpoint = endpoint
            XCTAssertFalse(TranslationAccountUsageLoader.supports(configuration), endpoint)
            XCTAssertThrowsError(try TranslationAccountUsageLoader.makeRequest(configuration: configuration, apiKey: "fixture-key")) {
                XCTAssertEqual($0 as? TranslationAccountUsageError, .unsupportedService)
            }
        }
        for kind in TranslationServiceKind.allCases where kind != .deepSeek && kind != .deepL {
            XCTAssertFalse(TranslationAccountUsageLoader.supports(.init(kind: kind)))
        }
        var deepL = TranslationServiceConfiguration(kind: .deepL)
        deepL.endpoint += "/v2"
        XCTAssertFalse(TranslationAccountUsageLoader.supports(deepL))
        for key in ["", "contains spaces", "new\nline", String(repeating: "x", count: 8_193)] {
            XCTAssertThrowsError(try TranslationAccountUsageLoader.makeRequest(configuration: .init(kind: .deepSeek), apiKey: key))
        }
    }

    func testBalancesKeepDecimalPrecisionCurrencyAndServerValues() throws {
        let data = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"19.640000000001","granted_balance":"4.00","topped_up_balance":"15.640000000001"},{"currency":"USD","total_balance":"-0.02"}]}"#.utf8)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try TranslationAccountUsageLoader.parse(data, kind: .deepSeek, fetchedAt: date)
        XCTAssertEqual(result.fetchedAt, date)
        XCTAssertEqual(result.balances.count, 2)
        XCTAssertEqual(result.balances[0].total, Decimal(string: "19.640000000001"))
        XCTAssertEqual(result.balances[0].granted, 4)
        XCTAssertEqual(result.balances[1].currency, "USD")
        XCTAssertEqual(result.balances[1].total, Decimal(string: "-0.02"))
        XCTAssertNil(result.balances[1].granted)
        XCTAssertNil(result.usedCharacters)
    }

    func testInvalidBalancesAreUnavailableInsteadOfZeroOrRawError() throws {
        let invalid = [
            #"{"balance_infos":[]}"#,
            #"{"is_available":true,"balance_infos":[]}"#,
            #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"3.14secret"}]}"#,
            #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"3.14\n"}]}"#,
            #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":3.14}]}"#,
            #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"NaN"}]}"#,
            #"{"is_available":true,"balance_infos":[{"currency":"SECRET","total_balance":"2"}]}"#,
            #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"2"},{"currency":"CNY","total_balance":"3"}]}"#,
            #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"2"}],"error":{"message":"fixture-private-message"}}"#
        ]
        for value in invalid {
            XCTAssertThrowsError(try TranslationAccountUsageLoader.parse(Data(value.utf8), kind: .deepSeek)) {
                XCTAssertEqual($0 as? TranslationAccountUsageError, .invalidResponse)
                XCTAssertFalse($0.localizedDescription.contains("fixture-private-message"))
            }
        }
    }

    func testDeepLPeriodTotalsAndUnlimitedSentinelRemainDistinct() throws {
        let normal = try TranslationAccountUsageLoader.parse(Data(#"{"character_count":180118,"character_limit":500000}"#.utf8), kind: .deepL)
        XCTAssertEqual(normal.usedCharacters, 180_118)
        XCTAssertEqual(normal.characterLimit, 500_000)
        XCTAssertFalse(normal.hasUnlimitedCharacters)
        XCTAssertTrue(normal.balances.isEmpty)
        let unlimited = try TranslationAccountUsageLoader.parse(Data(#"{"character_count":180118,"character_limit":1000000000000,"api_key_character_count":10}"#.utf8), kind: .deepL)
        XCTAssertEqual(unlimited.usedCharacters, 180_118, "Account totals must not silently switch to key totals")
        XCTAssertNil(unlimited.characterLimit)
        XCTAssertTrue(unlimited.hasUnlimitedCharacters)
        for value in [#"{}"#, #"{"character_count":-1,"character_limit":5}"#,
                      #"{"character_count":true,"character_limit":5}"#, #"{"character_count":1.5,"character_limit":5}"#,
                      #"{"character_count":1,"character_limit":-1}"#, #"{"character_count":1,"character_limit":"5"}"#] {
            XCTAssertThrowsError(try TranslationAccountUsageLoader.parse(Data(value.utf8), kind: .deepL))
        }
    }

    func testTransportUsesSingleBoundedRequestAndFixedErrors() async throws {
        for (status, expected) in [(401, RemoteTranslationError.invalidKey), (403, .forbidden), (429, .rateLimited), (503, .serviceUnavailable)] {
            let fixture = transport(status: status, data: Data("fixture-private-message".utf8))
            defer { fixture.session.invalidateAndCancel() }
            do { _ = try await fixture.loader.usage(configuration: .init(kind: .deepSeek), apiKey: fixture.key); XCTFail("Expected failure") }
            catch {
                XCTAssertEqual(error as? RemoteTranslationError, expected)
                XCTAssertFalse(error.localizedDescription.contains("fixture-private-message"))
            }
            XCTAssertEqual(QuotaURLProtocol.states.withLock { $0[fixture.key]?.requests.count }, 1)
        }
        for fixture in [
            transport(status: 307, headers: ["Location": "https://other.example"]),
            transport(headers: ["Content-Type": "text/html"], data: Data("<html>private</html>".utf8)),
            transport(headers: ["Content-Length": "65537"]),
            transport(data: Data(repeating: 32, count: 65_537))
        ] {
            defer { fixture.session.invalidateAndCancel() }
            do { _ = try await fixture.loader.usage(configuration: .init(kind: .deepSeek), apiKey: fixture.key); XCTFail("Expected failure") }
            catch {
                XCTAssertTrue(error as? RemoteTranslationError == .redirected || error as? TranslationAccountUsageError == .invalidResponse)
            }
            XCTAssertEqual(QuotaURLProtocol.states.withLock { $0[fixture.key]?.requests.count }, 1)
        }
    }

    func testTransportCancellationAndDeadlineStopUnderlyingRequest() async throws {
        let cancelled = transport(hold: true)
        defer { cancelled.session.invalidateAndCancel() }
        let task = Task { try await cancelled.loader.usage(configuration: .init(kind: .deepSeek), apiKey: cancelled.key) }
        try await waitUntil { QuotaURLProtocol.states.withLock { $0[cancelled.key]?.requests.count == 1 } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled query succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await waitUntil { QuotaURLProtocol.states.withLock { ($0[cancelled.key]?.stops ?? 0) > 0 } }

        let timedOut = transport(hold: true, timeout: .milliseconds(50))
        defer { timedOut.session.invalidateAndCancel() }
        do { _ = try await timedOut.loader.usage(configuration: .init(kind: .deepL), apiKey: timedOut.key); XCTFail("Deadline ignored") }
        catch { XCTAssertEqual(error as? RemoteTranslationError, .timedOut) }
        try await waitUntil { QuotaURLProtocol.states.withLock { ($0[timedOut.key]?.stops ?? 0) > 0 } }
    }

    func testExplicitRefreshPreservesSnapshotOnFailureWithoutRoutingOrPersistenceChanges() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let loader = HeldQuotaLoader()
        let controller = TranslationAccountUsageController(services: fixture.services, loader: loader)
        let beforeRevision = fixture.services.revision
        let beforeBytes = fixture.defaults.data(forKey: TranslationServiceStore.StorageKey.services)
        let beforeReads = fixture.credentials.reads
        XCTAssertNil(controller.state(for: fixture.configuration.id).snapshot)
        XCTAssertEqual(fixture.credentials.reads, beforeReads)
        controller.refresh(fixture.configuration)
        try await waitForRequests(loader, count: 1)
        let snapshot = sampleSnapshot()
        await loader.complete(0, result: .success(snapshot))
        try await waitUntil { !controller.state(for: fixture.configuration.id).isLoading }
        XCTAssertEqual(controller.state(for: fixture.configuration.id).snapshot, snapshot)
        controller.refresh(fixture.configuration)
        try await waitForRequests(loader, count: 2)
        await loader.complete(1, result: .failure(RemoteTranslationError.offline))
        try await waitUntil { !controller.state(for: fixture.configuration.id).isLoading }
        XCTAssertEqual(controller.state(for: fixture.configuration.id).snapshot, snapshot)
        XCTAssertNotNil(controller.state(for: fixture.configuration.id).errorMessage)
        XCTAssertEqual(fixture.services.revision, beforeRevision)
        XCTAssertEqual(fixture.defaults.data(forKey: TranslationServiceStore.StorageKey.services), beforeBytes)
    }

    func testKeyChangeInvalidatesCachedAndLateSnapshotWithoutRequery() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let loader = HeldQuotaLoader()
        let controller = TranslationAccountUsageController(services: fixture.services, loader: loader)
        controller.refresh(fixture.configuration)
        try await waitForRequests(loader, count: 1)
        await loader.complete(0, result: .success(sampleSnapshot()))
        try await waitUntil { !controller.state(for: fixture.configuration.id).isLoading }
        controller.refresh(fixture.configuration)
        try await waitForRequests(loader, count: 2)
        try fixture.services.save(fixture.configuration, apiKey: "fixture-new-key")
        XCTAssertNil(controller.state(for: fixture.configuration.id).snapshot)
        XCTAssertFalse(controller.state(for: fixture.configuration.id).isLoading)
        await loader.complete(1, result: .success(sampleSnapshot()))
        await Task.yield()
        XCTAssertNil(controller.state(for: fixture.configuration.id).snapshot)
        let requests = await loader.requestCount
        XCTAssertEqual(requests, 2)
    }

    func testCancellationAndSupersedingRefreshIgnoreLateCompletions() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let loader = HeldQuotaLoader()
        let controller = TranslationAccountUsageController(services: fixture.services, loader: loader)
        controller.refresh(fixture.configuration)
        try await waitForRequests(loader, count: 1)
        controller.cancelAll()
        XCTAssertFalse(controller.state(for: fixture.configuration.id).isLoading)
        controller.refresh(fixture.configuration)
        try await waitForRequests(loader, count: 2)
        await loader.complete(0, result: .success(sampleSnapshot()))
        await Task.yield()
        XCTAssertTrue(controller.state(for: fixture.configuration.id).isLoading)
        XCTAssertNil(controller.state(for: fixture.configuration.id).snapshot)
        let latest = sampleSnapshot(total: 42)
        await loader.complete(1, result: .success(latest))
        try await waitUntil { !controller.state(for: fixture.configuration.id).isLoading }
        XCTAssertEqual(controller.state(for: fixture.configuration.id).snapshot, latest)
        try fixture.services.remove(fixture.configuration.id)
        XCTAssertNil(controller.state(for: fixture.configuration.id).snapshot)
    }

    func testUnsupportedSavedEndpointDoesNotReadCredentialOrStartLoader() async throws {
        let fixture = try StoreFixture(endpoint: "https://custom.example/v1")
        defer { fixture.cleanup() }
        let loader = HeldQuotaLoader()
        let controller = TranslationAccountUsageController(services: fixture.services, loader: loader)
        let reads = fixture.credentials.reads
        controller.refresh(fixture.configuration)
        XCTAssertEqual(fixture.credentials.reads, reads)
        XCTAssertNotNil(controller.state(for: fixture.configuration.id).errorMessage)
        let requests = await loader.requestCount
        XCTAssertEqual(requests, 0)
    }

    func testQueryPreferencesPreserveManualDefaultsAndPersistWithoutServiceMutation() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let id = fixture.configuration.id
        let preferences = fixture.services.accountQueryPreferences
        XCTAssertEqual(preferences.preferences(for: id), .init(enabled: true, intervalSeconds: 0, timeoutSeconds: 10))
        XCTAssertNil(fixture.defaults.data(forKey: TranslationAccountQueryPreferencesStore.StorageKey.preferences))
        let serviceBytes = fixture.defaults.data(forKey: TranslationServiceStore.StorageKey.services)
        let saved = TranslationAccountQueryPreferences(enabled: true, intervalSeconds: 900, timeoutSeconds: 45)
        preferences.set(saved, for: id)
        let restored = TranslationAccountQueryPreferencesStore(defaults: fixture.defaults)
        XCTAssertEqual(restored.preferences(for: id), saved)
        XCTAssertEqual(fixture.defaults.data(forKey: TranslationServiceStore.StorageKey.services), serviceBytes)
        preferences.set(.init(enabled: true, intervalSeconds: -1, timeoutSeconds: 500), for: id)
        XCTAssertEqual(preferences.preferences(for: id), saved)
        preferences.remove(id)
        XCTAssertFalse(TranslationAccountQueryPreferencesStore(defaults: fixture.defaults).preferences(for: id).automaticallyQueries)
    }

    func testInvalidPersistedQueryPreferencesCannotEnableAutomaticRequests() throws {
        let defaults = UserDefaults(suiteName: "TranslationAccountQueryTests." + UUID().uuidString)!
        let id = UUID()
        defaults.set(try JSONEncoder().encode([id: TranslationAccountQueryPreferences(
            enabled: true, intervalSeconds: Int.max, timeoutSeconds: 10
        )]), forKey: TranslationAccountQueryPreferencesStore.StorageKey.preferences)
        defer { defaults.removeObject(forKey: TranslationAccountQueryPreferencesStore.StorageKey.preferences) }
        let preferences = TranslationAccountQueryPreferencesStore(defaults: defaults).preferences(for: id)
        XCTAssertEqual(preferences.intervalSeconds, 0)
        XCTAssertFalse(preferences.automaticallyQueries)
    }

    func testLegacyMinutePreferencesRetainActualDurationAndOnlyRewriteWhenSaved() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let id = fixture.configuration.id
        let bytes = try JSONEncoder().encode([id: LegacyQueryPreferences(enabled: true, intervalMinutes: 5, timeoutSeconds: 45)])
        fixture.defaults.set(bytes, forKey: TranslationAccountQueryPreferencesStore.StorageKey.preferences)

        let restored = TranslationAccountQueryPreferencesStore(defaults: fixture.defaults)
        let preferences = restored.preferences(for: id)
        XCTAssertEqual(preferences.intervalSeconds, 300, "Five saved minutes must never become five seconds")
        XCTAssertEqual(preferences.timeoutSeconds, 45)
        XCTAssertEqual(fixture.defaults.data(forKey: TranslationAccountQueryPreferencesStore.StorageKey.preferences), bytes)

        var changed = preferences
        changed.enabled = false
        restored.set(changed, for: id)
        let saved = try XCTUnwrap(fixture.defaults.data(forKey: TranslationAccountQueryPreferencesStore.StorageKey.preferences))
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("intervalSeconds"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("intervalMinutes"))
        XCTAssertEqual(TranslationAccountQueryPreferencesStore(defaults: fixture.defaults).preferences(for: id), changed)
    }

    func testLegacyInvalidMinuteValuesCannotOverflowOrDiscardOtherValidServices() throws {
        let suite = "TranslationAccountQueryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let validID = UUID(), invalidID = UUID(), negativeID = UUID(), manualID = UUID()
        let old = [validID: LegacyQueryPreferences(enabled: true, intervalMinutes: 1_440, timeoutSeconds: 120),
                   invalidID: LegacyQueryPreferences(enabled: true, intervalMinutes: Int.max, timeoutSeconds: 10),
                   negativeID: LegacyQueryPreferences(enabled: true, intervalMinutes: -1, timeoutSeconds: 10),
                   manualID: LegacyQueryPreferences(enabled: true, intervalMinutes: 0, timeoutSeconds: 10)]
        defaults.set(try JSONEncoder().encode(old), forKey: TranslationAccountQueryPreferencesStore.StorageKey.preferences)
        let restored = TranslationAccountQueryPreferencesStore(defaults: defaults)
        XCTAssertEqual(restored.preferences(for: validID).intervalSeconds, 86_400)
        for id in [invalidID, negativeID, manualID] {
            XCTAssertEqual(restored.preferences(for: id).intervalSeconds, 0)
            XCTAssertFalse(restored.preferences(for: id).automaticallyQueries)
        }
    }

    func testExplicitSecondsTakePrecedenceOverLegacyMinutes() throws {
        let data = Data(#"{"enabled":true,"intervalSeconds":5,"intervalMinutes":5,"timeoutSeconds":10}"#.utf8)
        let decoded = try JSONDecoder().decode(TranslationAccountQueryPreferences.self, from: data)
        XCTAssertEqual(decoded.intervalSeconds, 5)
        XCTAssertEqual(try JSONDecoder().decode(TranslationAccountQueryPreferences.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    func testQueryDropdownsPreserveExistingCustomDurationsUntilAChoiceIsSaved() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let id = fixture.configuration.id
        let legacy = Data(#"{"enabled":true,"intervalMinutes":5,"timeoutSeconds":45}"#.utf8)
        let preferences = try JSONDecoder().decode(TranslationAccountQueryPreferences.self, from: legacy)
        fixture.services.accountQueryPreferences.set(preferences, for: id)
        let draft = TranslationAccountQueryDraft(configuration: fixture.configuration, services: fixture.services)
        XCTAssertEqual(draft.interval, "300")
        XCTAssertEqual(draft.timeout, "45")
        XCTAssertEqual(draft.intervalOptions, [0, 5, 30, 60, 300])
        XCTAssertEqual(draft.timeoutOptions, [10, 30, 45, 60])
        XCTAssertFalse(draft.hasUnsavedChanges)
        XCTAssertTrue(draft.save())
        XCTAssertEqual(fixture.services.accountQueryPreferences.preferences(for: id), preferences)
        draft.interval = "5"
        draft.timeout = "30"
        XCTAssertEqual(fixture.services.accountQueryPreferences.preferences(for: id), preferences)
        XCTAssertTrue(draft.save())
        XCTAssertEqual(fixture.services.accountQueryPreferences.preferences(for: id), .init(intervalSeconds: 5, timeoutSeconds: 30))
        XCTAssertEqual(draft.intervalOptions, [0, 5, 30, 60])
        XCTAssertEqual(draft.timeoutOptions, [10, 30, 60])
    }

    func testQueryDraftChangesNothingUntilSavedAndSeparatesLocalRecording() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let id = fixture.configuration.id
        let draft = TranslationAccountQueryDraft(configuration: fixture.configuration, services: fixture.services)
        XCTAssertFalse(draft.hasUnsavedChanges)
        draft.enabled = false
        draft.interval = "900"
        draft.timeout = "30"
        draft.recordsUsage = false
        XCTAssertTrue(draft.hasUnsavedChanges)
        XCTAssertTrue(fixture.services.accountQueryPreferences.preferences(for: id).enabled)
        XCTAssertTrue(fixture.services.usage.isEnabled(for: id))
        XCTAssertTrue(draft.save())
        XCTAssertFalse(fixture.services.accountQueryPreferences.preferences(for: id).enabled)
        XCTAssertFalse(fixture.services.usage.isEnabled(for: id))
        XCTAssertFalse(draft.hasUnsavedChanges)
        draft.enabled = true
        draft.interval = ""
        draft.recordsUsage = true
        XCTAssertFalse(draft.save())
        XCTAssertFalse(fixture.services.usage.isEnabled(for: id))
        draft.enabled = false
        XCTAssertTrue(draft.save(), "Hidden incomplete fields must not block turning queries off")
        XCTAssertEqual(fixture.services.accountQueryPreferences.preferences(for: id).intervalSeconds, 900)
        let apple = TranslationAccountQueryDraft(configuration: nil, services: fixture.services)
        XCTAssertFalse(apple.supportsAccountQuery)
        apple.recordsUsage = false
        XCTAssertTrue(apple.save())
        XCTAssertFalse(fixture.services.usage.isEnabled(for: nil))
    }

    func testScheduledCredentialDenialNeverFallsBackToInteractiveReadOrSendsRequest() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        fixture.credentials.rejectSilentReads = true
        let id = fixture.configuration.id
        fixture.services.accountQueryPreferences.set(.init(intervalSeconds: 5, timeoutSeconds: 10), for: id)
        let loader = HeldQuotaLoader()
        let controller = TranslationAccountUsageController(services: fixture.services, loader: loader,
            automaticSleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
        defer { controller.stopAutomaticRefresh() }
        let interactiveReads = fixture.credentials.interactiveReads
        controller.startAutomaticRefresh()
        try await waitUntil { fixture.credentials.silentReads >= 2 && !controller.state(for: id).isLoading }
        XCTAssertEqual(fixture.credentials.interactiveReads, interactiveReads)
        let requests = await loader.requestCount
        XCTAssertEqual(requests, 0)
        XCTAssertNotNil(controller.state(for: id).errorMessage)

        controller.stopAutomaticRefresh()
        controller.refresh(fixture.configuration)
        try await waitForRequests(loader, count: 1)
        XCTAssertEqual(fixture.credentials.interactiveReads, interactiveReads + 1,
                       "Only the explicit refresh may ask the system for credential access")
        await loader.complete(0, result: .success(sampleSnapshot()))
    }

    func testSchedulerDoesNotReadKeysUntilAnAutomaticIntervalIsSaved() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let loader = HeldQuotaLoader()
        let controller = TranslationAccountUsageController(services: fixture.services, loader: loader)
        defer { controller.stopAutomaticRefresh() }
        let reads = fixture.credentials.reads
        controller.startAutomaticRefresh()
        await Task.yield()
        XCTAssertEqual(fixture.credentials.reads, reads)
        let initialRequests = await loader.requestCount
        XCTAssertEqual(initialRequests, 0)
        fixture.services.accountQueryPreferences.set(.init(enabled: false, intervalSeconds: 30, timeoutSeconds: 7), for: fixture.configuration.id)
        controller.configurationDidChange()
        await Task.yield()
        XCTAssertEqual(fixture.credentials.reads, reads)
        fixture.services.accountQueryPreferences.set(.init(enabled: true, intervalSeconds: 30, timeoutSeconds: 7), for: fixture.configuration.id)
        controller.configurationDidChange()
        try await waitForRequests(loader, count: 1)
        let timeouts = await loader.timeouts
        XCTAssertEqual(timeouts, [.seconds(7)])
        XCTAssertEqual(fixture.credentials.reads, reads + 1)
        controller.cancelManualQueries()
        XCTAssertTrue(controller.state(for: fixture.configuration.id).isLoading, "Leaving settings must not cancel an authorized scheduled query")
        fixture.services.accountQueryPreferences.set(.init(enabled: false, intervalSeconds: 30, timeoutSeconds: 7), for: fixture.configuration.id)
        controller.configurationDidChange()
        XCTAssertFalse(controller.state(for: fixture.configuration.id).isLoading)
        await loader.complete(0, result: .success(sampleSnapshot()))
        await Task.yield()
        XCTAssertNil(controller.state(for: fixture.configuration.id).snapshot, "A disabled query must not restore its late snapshot")
    }

    func testScheduledQueryCannotSendKeysToUnsupportedEndpoint() async throws {
        let fixture = try StoreFixture(endpoint: "https://custom.example/v1")
        defer { fixture.cleanup() }
        fixture.services.accountQueryPreferences.set(.init(enabled: true, intervalSeconds: 5, timeoutSeconds: 10), for: fixture.configuration.id)
        let loader = HeldQuotaLoader()
        let controller = TranslationAccountUsageController(services: fixture.services, loader: loader)
        defer { controller.stopAutomaticRefresh() }
        let reads = fixture.credentials.reads
        controller.startAutomaticRefresh()
        await Task.yield()
        XCTAssertEqual(fixture.credentials.reads, reads)
        let requests = await loader.requestCount
        XCTAssertEqual(requests, 0)
    }

    func testAutomaticRefreshRepeatsWithoutOverlappingAndStopsAtManualInterval() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let id = fixture.configuration.id
        fixture.services.accountQueryPreferences.set(.init(enabled: true, intervalSeconds: 5, timeoutSeconds: 8), for: id)
        let loader = HeldQuotaLoader()
        let controller = TranslationAccountUsageController(services: fixture.services, loader: loader,
            automaticSleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
        defer { controller.stopAutomaticRefresh() }
        controller.startAutomaticRefresh()
        try await waitForRequests(loader, count: 1)
        try await Task.sleep(for: .milliseconds(70))
        let overlapping = await loader.requestCount
        XCTAssertEqual(overlapping, 1)
        await loader.complete(0, result: .success(sampleSnapshot()))
        try await waitForRequests(loader, count: 2)
        fixture.services.accountQueryPreferences.set(.init(enabled: true, intervalSeconds: 0, timeoutSeconds: 8), for: id)
        controller.configurationDidChange()
        await loader.complete(1, result: .success(sampleSnapshot(total: 12)))
        try await Task.sleep(for: .milliseconds(70))
        let stopped = await loader.requestCount
        XCTAssertEqual(stopped, 2)
        XCTAssertEqual(controller.state(for: id).snapshot?.balances.first?.total, 19.64)
    }

    func testAutomaticSchedulerReceivesExactSecondDurations() async throws {
        for seconds in [5, 30, 60, 300] {
            let fixture = try StoreFixture()
            defer { fixture.cleanup() }
            let loader = HeldQuotaLoader()
            let sleeps = Mutex<[Duration]>([])
            fixture.services.accountQueryPreferences.set(.init(intervalSeconds: seconds, timeoutSeconds: 30), for: fixture.configuration.id)
            let controller = TranslationAccountUsageController(services: fixture.services, loader: loader, automaticSleep: { duration in
                sleeps.withLock { $0.append(duration) }
                try await Task.sleep(for: .seconds(60))
            })
            defer { controller.stopAutomaticRefresh() }
            controller.startAutomaticRefresh()
            try await waitForRequests(loader, count: 1)
            XCTAssertEqual(sleeps.withLock { $0 }, [.seconds(seconds)])
            let timeouts = await loader.timeouts
            XCTAssertEqual(timeouts, [.seconds(30)])
            await loader.complete(0, result: .success(sampleSnapshot()))
        }
    }

    func testConfiguredTimeoutControlsTheRequestAndDeadline() async throws {
        let fixture = transport(hold: true)
        defer { fixture.session.invalidateAndCancel() }
        do {
            _ = try await fixture.loader.usage(configuration: .init(kind: .deepSeek), apiKey: fixture.key, timeout: .milliseconds(40))
            XCTFail("Configured timeout was ignored")
        } catch { XCTAssertEqual(error as? RemoteTranslationError, .timedOut) }
        let request = QuotaURLProtocol.states.withLock { $0[fixture.key]?.requests.first }
        XCTAssertEqual(try XCTUnwrap(request).timeoutInterval, 0.04, accuracy: 0.001)
        try await waitUntil { QuotaURLProtocol.states.withLock { ($0[fixture.key]?.stops ?? 0) > 0 } }
        let long = try TranslationAccountUsageLoader.makeRequest(configuration: .init(kind: .deepSeek), apiKey: "fixture-key", timeout: 90)
        XCTAssertEqual(long.timeoutInterval, 90)
    }

    private func sampleSnapshot(total: Decimal = 19.64) -> TranslationAccountUsageSnapshot {
        .init(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
              balances: [.init(currency: "CNY", total: total, granted: nil, toppedUp: nil)])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Account query did not reach the expected state")
        throw URLError(.timedOut)
    }

    private func waitForRequests(_ loader: HeldQuotaLoader, count: Int) async throws {
        for _ in 0..<200 {
            if await loader.requestCount >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Account query did not start")
        throw URLError(.timedOut)
    }

    private func transport(status: Int = 200, headers: [String: String] = [:], data: Data = Data(),
                           hold: Bool = false, timeout: Duration = .seconds(20)) -> TransportFixture {
        let key = "fixture-" + UUID().uuidString
        QuotaURLProtocol.states.withLock { $0[key] = .init(status: status, headers: headers, data: data, hold: hold) }
        let configuration = TranslationHTTPPolicy.sessionConfiguration()
        configuration.protocolClasses = [QuotaURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return .init(key: key, session: session, loader: .init(session: session, timeout: timeout))
    }

    private struct TransportFixture {
        let key: String
        let session: URLSession
        let loader: TranslationAccountUsageLoader
    }
}

private struct LegacyQueryPreferences: Codable {
    var enabled: Bool
    var intervalMinutes: Int
    var timeoutSeconds: Int
}

@MainActor
private final class StoreFixture {
    let suite = "TranslationAccountUsageTests." + UUID().uuidString
    let defaults: UserDefaults
    let credentials = QuotaCredentials()
    let services: TranslationServiceStore
    let configuration: TranslationServiceConfiguration

    init(endpoint: String? = nil) throws {
        defaults = UserDefaults(suiteName: suite)!
        services = TranslationServiceStore(defaults: defaults, credentials: credentials)
        var configuration = TranslationServiceConfiguration(kind: .deepSeek)
        if let endpoint { configuration.endpoint = endpoint }
        self.configuration = configuration
        try services.save(configuration, apiKey: "fixture-key")
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class QuotaCredentials: TranslationCredentialStore {
    private var values: [UUID: TranslationServiceCredential] = [:]
    private(set) var interactiveReads = 0
    private(set) var silentReads = 0
    var rejectSilentReads = false
    var reads: Int { interactiveReads + silentReads }
    func credential(for id: UUID) throws -> TranslationServiceCredential? { interactiveReads += 1; return values[id] }
    func credentialWithoutInteraction(for id: UUID) throws -> TranslationServiceCredential? {
        silentReads += 1
        if rejectSilentReads { throw TranslationServiceConfigurationError.credentialUnavailable }
        return values[id]
    }
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { values[id] = credential }
    func removeCredential(for id: UUID) throws { values[id] = nil }
}

private actor HeldQuotaLoader: TranslationAccountUsageLoading {
    private var continuations: [Int: CheckedContinuation<TranslationAccountUsageSnapshot, any Error>] = [:]
    private(set) var requestCount = 0
    private(set) var timeouts: [Duration] = []
    func usage(configuration: TranslationServiceConfiguration, apiKey: String?, timeout: Duration) async throws -> TranslationAccountUsageSnapshot {
        timeouts.append(timeout)
        return try await usage(configuration: configuration, apiKey: apiKey)
    }
    func usage(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> TranslationAccountUsageSnapshot {
        let id = requestCount
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuations[id] = $0 }
    }
    func complete(_ index: Int, result: Result<TranslationAccountUsageSnapshot, any Error>) {
        continuations.removeValue(forKey: index)?.resume(with: result)
    }
}

private final class QuotaURLProtocol: URLProtocol {
    struct State: Sendable {
        let status: Int
        let headers: [String: String]
        let data: Data
        let hold: Bool
        var requests: [URLRequest] = []
        var stops = 0
    }
    static let states = Mutex<[String: State]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var fixtureKey: String { String((request.value(forHTTPHeaderField: "Authorization") ?? "").split(separator: " ").last ?? "") }
    override func startLoading() {
        let state = Self.states.withLock { states -> State? in
            guard var state = states[fixtureKey] else { return nil }
            state.requests.append(request)
            states[fixtureKey] = state
            return state
        }
        guard let state else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        if state.hold { return }
        var headers = ["Content-Type": "application/json"]
        headers.merge(state.headers) { _, value in value }
        let response = HTTPURLResponse(url: request.url!, statusCode: state.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: state.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.states.withLock { $0[fixtureKey]?.stops += 1 } }
}

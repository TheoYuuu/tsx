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
    private(set) var reads = 0
    func credential(for id: UUID) throws -> TranslationServiceCredential? { reads += 1; return values[id] }
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { values[id] = credential }
    func removeCredential(for id: UUID) throws { values[id] = nil }
}

private actor HeldQuotaLoader: TranslationAccountUsageLoading {
    private var continuations: [Int: CheckedContinuation<TranslationAccountUsageSnapshot, any Error>] = [:]
    private(set) var requestCount = 0
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

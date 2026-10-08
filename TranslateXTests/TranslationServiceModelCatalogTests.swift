import Foundation
import Synchronization
import XCTest
@testable import TranslateX

@MainActor
final class TranslationServiceModelCatalogTests: XCTestCase {
    func testOnlyFiveAPIKindsProvideDiscovery() {
        let supported: Set<TranslationServiceKind> = [.openAI, .deepSeek, .claude, .openAICompatible, .ollama]
        for kind in TranslationServiceKind.allCases {
            XCTAssertEqual(TranslationServiceModelCatalog.supports(kind), supported.contains(kind))
            if !supported.contains(kind) {
                XCTAssertThrowsError(try TranslationServiceModelCatalog.makeRequest(configuration: .init(kind: kind), apiKey: "fixture")) {
                    XCTAssertEqual($0 as? TranslationServiceModelCatalogError, .unsupportedService)
                }
            }
        }
    }

    func testDiscoveryDoesNotRequireModelNameOrTranslationInstructions() throws {
        for kind: TranslationServiceKind in [.openAI, .deepSeek, .claude, .openAICompatible, .ollama] {
            var config = TranslationServiceConfiguration(kind: kind)
            config.name = ""
            config.model = ""
            config.additionalInstructions = String(repeating: "private-text", count: 1_000)
            config.endpoint = "https://catalog.test/proxy/v1/"
            let request = try TranslationServiceModelCatalog.makeRequest(configuration: config, apiKey: "fixture")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/proxy/v1/models")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertFalse(request.url!.absoluteString.contains("private-text"))
        }
    }

    func testAuthenticationAndNativeClaudeHeaders() throws {
        for kind: TranslationServiceKind in [.openAI, .deepSeek, .claude] {
            XCTAssertThrowsError(try TranslationServiceModelCatalog.makeRequest(configuration: .init(kind: kind), apiKey: nil)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .missingKey)
            }
            let request = try TranslationServiceModelCatalog.makeRequest(configuration: .init(kind: kind), apiKey: " fixture-key \n")
            if kind == .claude {
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.url?.query, "limit=100")
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
                XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
                XCTAssertNil(request.url?.query)
            }
        }
        for kind: TranslationServiceKind in [.openAICompatible, .ollama] {
            var config = TranslationServiceConfiguration(kind: kind)
            config.endpoint = "http://127.0.0.1:11434/prefix/v1"
            let request = try TranslationServiceModelCatalog.makeRequest(configuration: config, apiKey: nil)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.absoluteString, config.endpoint + "/models")
        }
        for key in ["a\rb", "a\nb", "a b", String(repeating: "x", count: 8_193)] {
            XCTAssertThrowsError(try TranslationServiceModelCatalog.makeRequest(configuration: .init(kind: .openAI), apiKey: key)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .invalidKey)
            }
        }
    }

    func testEndpointValidationNeverChangesDestinationOrGuessesV1() throws {
        for address in ["http://example.com", "https://user:secret@example.com/v1", "https://example.com/v1?key=fixture", "https://example.com/v1#fragment", "https://example.com/a/../v1"] {
            var config = TranslationServiceConfiguration(kind: .openAICompatible)
            config.endpoint = address
            XCTAssertThrowsError(try TranslationServiceModelCatalog.makeRequest(configuration: config, apiKey: nil))
        }
        let request = try TranslationServiceModelCatalog.makeRequest(configuration: .init(kind: .deepSeek), apiKey: "fixture")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/models")
    }

    func testDirectoryNamesAndIdentifiersPreserveServerOrderWithoutChoosingAModel() async throws {
        let scenario = try fixture(.deepSeek, [json(["data": [["id": "zeta", "name": "模型 Z"], ["id": "alpha"]]])])
        let before = scenario.configuration
        let values = try await scenario.loader.models(configuration: before, apiKey: "fixture")
        XCTAssertEqual(values, [.init(id: "zeta", name: "模型 Z"), .init(id: "alpha", name: "alpha")])
        XCTAssertEqual(scenario.configuration, before)
        XCTAssertEqual(scenario.requests.count, 1)
        scenario.session.invalidateAndCancel()
    }

    func testSuccessfulEmptyDirectoryIsNotAConnectionFailure() async throws {
        for kind: TranslationServiceKind in [.openAI, .deepSeek, .openAICompatible, .ollama, .claude] {
            let scenario = try fixture(kind, [json(["data": [], "has_more": false])])
            let values = try await scenario.loader.models(configuration: scenario.configuration, apiKey: "fixture")
            XCTAssertEqual(values, [])
            scenario.session.invalidateAndCancel()
        }
    }

    func testClaudeFollowsNativeCursorAndRetainsExactHostPathAndHeaders() async throws {
        let cursor = "claude-a&not_another_query=1"
        let scenario = try fixture(.claude, [
            json(["data": [["id": cursor, "display_name": "Claude A"]], "has_more": true, "last_id": cursor]),
            json(["data": [["id": "claude-b", "display_name": "Claude B"]], "has_more": false, "last_id": "claude-b"])
        ])
        let values = try await scenario.loader.models(configuration: scenario.configuration, apiKey: "fixture")
        XCTAssertEqual(values.map(\.name), ["Claude A", "Claude B"])
        let requests = scenario.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.host, "catalog.test")
            XCTAssertEqual(request.url?.path, requests[0].url?.path)
            XCTAssertNil(request.url?.fragment)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        let query = try XCTUnwrap(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "after_id", value: cursor)])
        scenario.session.invalidateAndCancel()
    }

    func testClaudeNeverReturnsPartialDirectoryAfterSecondPageFails() async throws {
        let scenario = try fixture(.claude, [
            json(["data": [["id": "one"]], "has_more": true, "last_id": "one"]),
            .init(status: 503, body: Data("fixture-private-error".utf8))
        ])
        await assertFailure(scenario, remote: .serviceUnavailable)
        XCTAssertEqual(scenario.requests.count, 2)
    }

    func testClaudeRejectsMissingBooleanOrInvalidPaginationCursor() async throws {
        let invalid: [[String: Any]] = [
            ["data": []],
            ["data": [], "has_more": "false"],
            ["data": [], "has_more": true, "last_id": "one"],
            ["data": [["id": "one"]], "has_more": true],
            ["data": [["id": "one"]], "has_more": true, "last_id": "two"],
            ["data": [["id": "one"]], "has_more": true, "last_id": "one\n"]
        ]
        for object in invalid {
            let scenario = try fixture(.claude, [json(object)])
            await assertFailure(scenario, catalog: .invalidCatalog)
            XCTAssertEqual(scenario.requests.count, 1)
        }
    }

    func testDuplicateIDsAndRepeatedPagesFailWithoutAnotherRequest() async throws {
        let page = try json(["data": [["id": "one"]], "has_more": true, "last_id": "one"])
        let scenario = try fixture(.claude, [page, page, page])
        await assertFailure(scenario, catalog: .invalidCatalog)
        XCTAssertEqual(scenario.requests.count, 2)
        let duplicate = try fixture(.openAI, [json(["data": [["id": "one"], ["id": "one"]]])])
        await assertFailure(duplicate, catalog: .invalidCatalog)
    }

    func testPageAndModelCountLimitsNeverReturnTruncatedSuccess() async throws {
        let pages = try (0..<11).map { index in
            try json(["data": [["id": "model-\(index)"]], "has_more": true, "last_id": "model-\(index)"])
        }
        let scenario = try fixture(.claude, pages)
        await assertFailure(scenario, catalog: .catalogTooLarge)
        XCTAssertEqual(scenario.requests.count, 10)
        let tooMany = try fixture(.openAI, [json(["data": (0..<1_001).map { ["id": "model-\($0)"] }])])
        await assertFailure(tooMany, catalog: .catalogTooLarge)
        let accumulated = try fixture(.claude, [
            json(["data": (0..<1_000).map { ["id": "model-\($0)"] }, "has_more": true, "last_id": "model-999"]),
            json(["data": [["id": "extra"]], "has_more": false])
        ])
        await assertFailure(accumulated, catalog: .catalogTooLarge)
    }

    func testInvalidDirectoryFieldsAndContradictoryErrorStayLocal() async throws {
        let invalid: [[String: Any]] = [
            [:], ["data": NSNull()], ["data": "models"], ["data": ["model"]],
            ["data": [["id": false]]], ["data": [["id": 4]]], ["data": [["name": "Missing ID"]]],
            ["data": [["id": ""]]], ["data": [["id": "bad id"]]], ["data": [["id": "bad\u{202E}id"]]],
            ["data": [["id": String(repeating: "界", count: 86)]]],
            ["data": [["id": "valid", "name": "bad\nname"]]], ["data": [["id": "valid", "name": false]]],
            ["data": [["id": "valid", "name": String(repeating: "x", count: 257)]]],
            ["data": [["id": "valid"]], "error": ["message": "fixture-private-error"]],
            ["data": [], "object": "other"]
        ]
        for object in invalid {
            let scenario = try fixture(.deepSeek, [json(object)])
            await assertFailure(scenario, catalog: .invalidCatalog)
        }
    }

    func testMetadataAndNullErrorDoNotInvalidateOtherwiseValidDirectory() async throws {
        let scenario = try fixture(.openAICompatible, [json([
            "data": [["id": "custom:model/one", "owned_by": "example", "future_metadata": ["value": 1]]],
            "error": NSNull(), "future_metadata": ["ignored": true]
        ])])
        let values = try await scenario.loader.models(configuration: scenario.configuration, apiKey: nil)
        XCTAssertEqual(values.map(\.id), ["custom:model/one"])
        scenario.session.invalidateAndCancel()
    }

    func testDirectoryHTTPFailuresAreSafeAndNeverRetried() async throws {
        for status in [404, 405] {
            let scenario = try fixture(.openAICompatible, [.init(status: status, body: Data("fixture-private-error".utf8))])
            await assertFailure(scenario, catalog: .catalogUnavailable)
            XCTAssertEqual(scenario.requests.count, 1)
        }
        for (status, expected) in [(401, RemoteTranslationError.invalidKey), (402, .quotaExceeded), (403, .forbidden), (408, .timedOut), (429, .rateLimited), (500, .serviceUnavailable)] {
            let scenario = try fixture(.openAI, [.init(status: status, body: Data("fixture-private-error".utf8))])
            await assertFailure(scenario, remote: expected)
            XCTAssertEqual(scenario.requests.count, 1)
        }
    }

    func testRedirectAndNonJSONResponseCannotBecomeDirectorySuccess() async throws {
        let redirected = try fixture(.openAI, [.init(status: 307, headers: ["Location": "https://other.test/models"])])
        await assertFailure(redirected, remote: .redirected)
        XCTAssertEqual(redirected.requests.count, 1)
        let html = try fixture(.openAI, [.init(headers: ["Content-Type": "text/html"], body: Data("<html>fixture-private-error</html>".utf8))])
        await assertFailure(html, catalog: .invalidCatalog)
        let invalid = try fixture(.openAI, [.init(body: Data("{not json}".utf8))])
        await assertFailure(invalid, catalog: .invalidCatalog)
    }

    func testCumulativeResponseLimitIncludesIgnoredMetadataWithoutContentLength() async throws {
        let scenario = try fixture(.claude, [
            json(["data": [["id": "one"]], "has_more": true, "last_id": "one", "padding": String(repeating: "x", count: 2_097_152)]),
            json(["data": [["id": "two"]], "has_more": false, "padding": String(repeating: "x", count: 2_097_152)])
        ])
        await assertFailure(scenario, catalog: .catalogTooLarge)
        XCTAssertEqual(scenario.requests.count, 2)
    }

    func testAdvertisedOversizedDirectoryStopsBeforeParsing() async throws {
        let scenario = try fixture(.openAI, [.init(headers: ["Content-Length": "4194305"], hold: .body)])
        await assertFailure(scenario, catalog: .catalogTooLarge)
        try await waitFor(scenario, stopped: true)
    }

    func testCancelledTaskDoesNotStartEvenTheFirstPage() async throws {
        let scenario = try fixture(.openAI, [json(["data": []])])
        let task = Task { () throws -> [TranslationServiceModel] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scenario.loader.models(configuration: scenario.configuration, apiKey: "fixture")
        }
        do { _ = try await task.value; XCTFail("Cancelled discovery completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(scenario.requests.count, 0)
        scenario.session.invalidateAndCancel()
    }

    func testCancellationBeforeHeadersAndDuringBodyStopsUnderlyingTask() async throws {
        for hold: CatalogFixtureResponse.Hold in [.headers, .body] {
            let scenario = try fixture(.openAI, [.init(hold: hold)])
            let task = Task { try await scenario.loader.models(configuration: scenario.configuration, apiKey: "fixture") }
            try await waitFor(scenario)
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled discovery completed") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await waitFor(scenario, stopped: true)
            XCTAssertEqual(scenario.requests.count, 1)
            scenario.session.invalidateAndCancel()
        }
    }

    func testTotalDeadlineStopsHeldLaterPageInsteadOfResettingPerPage() async throws {
        let scenario = try fixture(.claude, [
            json(["data": [["id": "one"]], "has_more": true, "last_id": "one"]), .init(hold: .body)
        ], timeout: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        await assertFailure(scenario, remote: .timedOut)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
        XCTAssertEqual(scenario.requests.count, 2)
        try await waitFor(scenario, stopped: true)
    }

    func testSharedTransportHonorsSmallerLimitAndPreservesDefault() async throws {
        let small = try fixture(.openAI, [.init(body: Data("12345".utf8))])
        let request = try TranslationServiceModelCatalog.makeRequest(configuration: small.configuration, apiKey: "fixture")
        do { _ = try await BoundedTranslationHTTPTransport.send(request, session: small.session, maximumResponseBytes: 4); XCTFail("Limit was ignored") }
        catch { XCTAssertEqual(error as? RemoteTranslationError, .responseTooLarge) }
        small.session.invalidateAndCancel()

        let normal = try fixture(.openAI, [.init(body: Data("12345".utf8))])
        let normalRequest = try TranslationServiceModelCatalog.makeRequest(configuration: normal.configuration, apiKey: "fixture")
        let payload = try await BoundedTranslationHTTPTransport.send(normalRequest, session: normal.session)
        XCTAssertEqual(payload.data, Data("12345".utf8))
        normal.session.invalidateAndCancel()
        for limit in [0, -1, 4_194_305] {
            do { _ = try await BoundedTranslationHTTPTransport.send(normalRequest, maximumResponseBytes: limit); XCTFail("Invalid limit was accepted") }
            catch { XCTAssertEqual(error as? RemoteTranslationError, .responseTooLarge) }
        }
    }

    private struct Scenario: Sendable {
        let configuration: TranslationServiceConfiguration
        let session: URLSession
        let loader: TranslationServiceModelCatalog
        var requests: [URLRequest] { CatalogURLProtocol.states.withLock { $0[configuration.endpoint]!.requests } }
    }

    private func fixture(_ kind: TranslationServiceKind, _ responses: [CatalogFixtureResponse], timeout: Duration = .seconds(20)) throws -> Scenario {
        var configuration = TranslationServiceConfiguration(kind: kind)
        configuration.endpoint = "https://catalog.test/\(UUID().uuidString)/proxy/v1"
        CatalogURLProtocol.states.withLock { $0[configuration.endpoint] = .init(responses: responses) }
        let config = TranslationHTTPPolicy.sessionConfiguration()
        config.protocolClasses = [CatalogURLProtocol.self]
        let session = URLSession(configuration: config)
        return Scenario(configuration: configuration, session: session, loader: .init(session: session, timeout: timeout))
    }

    private func json(_ value: [String: Any]) throws -> CatalogFixtureResponse {
        .init(body: try JSONSerialization.data(withJSONObject: value))
    }

    private func assertFailure(_ scenario: Scenario, catalog: TranslationServiceModelCatalogError? = nil, remote: RemoteTranslationError? = nil) async {
        defer { scenario.session.invalidateAndCancel() }
        do { _ = try await scenario.loader.models(configuration: scenario.configuration, apiKey: "fixture"); XCTFail("Expected failure") }
        catch {
            if let catalog { XCTAssertEqual(error as? TranslationServiceModelCatalogError, catalog) }
            if let remote { XCTAssertEqual(error as? RemoteTranslationError, remote) }
            XCTAssertFalse(error.localizedDescription.contains("fixture-private-error"))
        }
    }

    private func waitFor(_ scenario: Scenario, stopped: Bool = false) async throws {
        for _ in 0..<100 {
            let ready = CatalogURLProtocol.states.withLock { states in
                let state = states[scenario.configuration.endpoint]!
                return stopped ? state.stops > 0 : !state.requests.isEmpty
            }
            if ready { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Transport did not reach the expected lifecycle state")
        throw URLError(.timedOut)
    }
}

private struct CatalogFixtureResponse: Sendable {
    enum Hold: Sendable { case none, headers, body }
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var hold: Hold = .none
}

private final class CatalogURLProtocol: URLProtocol {
    struct State: Sendable {
        let responses: [CatalogFixtureResponse]
        var requests: [URLRequest] = []
        var stops = 0
    }
    static let states = Mutex<[String: State]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "catalog.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var fixtureKey: String {
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.query = nil
        components.path = String(components.path.dropLast("/models".count))
        return components.url!.absoluteString
    }

    override func startLoading() {
        let response = Self.states.withLock { states -> CatalogFixtureResponse? in
            guard var state = states[fixtureKey] else { return nil }
            let index = state.requests.count
            state.requests.append(request)
            states[fixtureKey] = state
            return state.responses.indices.contains(index) ? state.responses[index] : nil
        }
        guard let response else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        if response.hold == .headers { return }
        var headers = ["Content-Type": "application/json; charset=UTF-8"]
        headers.merge(response.headers) { _, value in value }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if response.hold == .body { return }
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.states.withLock { $0[fixtureKey]?.stops += 1 }
    }
}

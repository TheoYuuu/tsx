import Foundation
import Synchronization
import XCTest
@testable import TranslateX

@MainActor
final class GoogleCloudTranslationProviderTests: XCTestCase {
    private let input = TranslationRequest(id: UUID(), text: "\n  <tag> &amp; \"quoted\" 🌍\n\nText.\n", source: nil, target: "zh-Hant")

    func testRequestUsesExactOperationURLHeaderKeyAndOnePlainTextNMTQuery() throws {
        var config = TranslationServiceConfiguration(kind: .googleCloud)
        config.model = "ignored-model"
        config.additionalInstructions = "Must not enter q"
        let http = try GoogleCloudTranslationProvider.makeRequest(configuration: config, apiKey: "fixture-key", request: input)
        XCTAssertEqual(http.url?.absoluteString, "https://translation.googleapis.com/language/translate/v2")
        XCTAssertEqual(http.httpMethod, "POST")
        XCTAssertFalse(http.httpShouldHandleCookies)
        XCTAssertEqual(http.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
        XCTAssertNil(http.value(forHTTPHeaderField: "Authorization"))
        let body = try MTProviderFixture.object(http.httpBody!)
        XCTAssertEqual(body["q"] as? String, input.text)
        XCTAssertEqual(body["format"] as? String, "text")
        XCTAssertEqual(body["model"] as? String, "nmt")
        XCTAssertEqual(body["target"] as? String, "zh-TW")
        XCTAssertNil(body["source"])
        XCTAssertNil(body["key"])
        XCTAssertFalse(String(decoding: http.httpBody!, as: UTF8.self).contains("fixture-key"))
    }

    func testCustomGoogleEndpointIsAlreadyTheOperationAndSourceIsExplicit() throws {
        var config = TranslationServiceConfiguration(kind: .googleCloud)
        config.endpoint = "https://proxy.test/customer/google-translate"
        let input = TranslationRequest(id: UUID(), text: "Olá", source: "pt-PT", target: "pt")
        let http = try GoogleCloudTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input)
        XCTAssertEqual(http.url?.path, "/customer/google-translate")
        let body = try MTProviderFixture.object(http.httpBody!)
        XCTAssertEqual(body["source"] as? String, "pt-PT")
        XCTAssertEqual(body["target"] as? String, "pt-BR")
    }

    func testGoogleLanguageIntersectionKeepsScriptsAndRegionalPortuguese() {
        XCTAssertEqual(GoogleTranslationLanguages.identifiers().count, 53)
        for asTarget in [false, true] {
            for id in GoogleTranslationLanguages.identifiers(asTarget: asTarget) {
                XCTAssertNotNil(GoogleTranslationLanguages.code(for: id, asTarget: asTarget))
            }
            for (id, code) in [("zh-Hans", "zh-CN"), ("zh-Hant", "zh-TW"), ("pt-BR", "pt-BR"), ("pt-PT", "pt-PT"), ("he", "he"), ("fil", "fil")] {
                XCTAssertEqual(GoogleTranslationLanguages.code(for: id, asTarget: asTarget), code)
            }
        }
        for id in ["nb", "auto", "unknown"] { XCTAssertNil(GoogleTranslationLanguages.code(for: id)) }
        XCTAssertNil(GoogleTranslationLanguages.detectedSourceIdentifier(from: "zh"))
        XCTAssertNil(GoogleTranslationLanguages.detectedSourceIdentifier(from: "unknown"))
        XCTAssertEqual(GoogleTranslationLanguages.detectedSourceIdentifier(from: "zh-TW"), "zh-Hant")
        XCTAssertEqual(GoogleTranslationLanguages.detectedSourceIdentifier(from: "iw"), "he")
    }

    func testGoogleInputAndEncodedRequestLimitsAreIndependent() throws {
        let config = TranslationServiceConfiguration(kind: .googleCloud)
        for (text, allowed) in [(String(repeating: "a", count: 65_536), true), (String(repeating: "a", count: 65_537), false), (String(repeating: "\u{0001}", count: 16_000), true), (String(repeating: "\u{0001}", count: 17_000), false)] {
            let input = TranslationRequest(id: UUID(), text: text, source: "en", target: "de")
            if allowed {
                let http = try GoogleCloudTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input)
                XCTAssertLessThanOrEqual(http.httpBody!.count, 100_000)
            } else {
                XCTAssertThrowsError(try GoogleCloudTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input)) {
                    XCTAssertEqual($0 as? RemoteTranslationError, .inputTooLarge)
                }
            }
        }
    }

    func testGoogleRejectsMissingInvalidKeysEmptyTextAndUnsupportedLanguageBeforeTransport() {
        let config = TranslationServiceConfiguration(kind: .googleCloud)
        for (key, error) in [(nil, RemoteTranslationError.missingKey), ("", .missingKey), ("a\r\nInjected: b", .invalidKey), (String(repeating: "k", count: 8_193), .invalidKey)] {
            XCTAssertThrowsError(try GoogleCloudTranslationProvider.makeRequest(configuration: config, apiKey: key, request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, error)
            }
        }
        for (text, target, expected) in [(" \n", "en", RemoteTranslationError.invalidRequest), ("text", "nb", .unsupportedLanguage)] {
            let request = TranslationRequest(id: UUID(), text: text, source: nil, target: target)
            XCTAssertThrowsError(try GoogleCloudTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: request)) {
                XCTAssertEqual($0 as? RemoteTranslationError, expected)
            }
        }
    }

    func testGoogleParserPreservesWhitespaceAndLiteralEntitiesWithDetection() throws {
        let expected = "\n  <tag> &amp; &#39; \"引号\" 🌍\n\n末行\n"
        let data = try MTProviderFixture.json(["data": ["translations": [["translatedText": expected, "detectedSourceLanguage": "pt-PT", "model": "nmt"]]]])
        let result = try GoogleCloudTranslationProvider.parse(data, request: input)
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.source, "pt-PT")
        XCTAssertEqual(result.target, "zh-Hant")
        let manual = TranslationRequest(id: UUID(), text: input.text, source: "en", target: input.target)
        XCTAssertEqual(try GoogleCloudTranslationProvider.parse(data, request: manual).source, "en")
    }

    func testGoogleRejectsMalformedMissingEmptyMultipleAndWrongModelResults() throws {
        let invalid = ["{}", "{\"data\":{\"translations\":[]}}", "{\"data\":{\"translations\":[{}]}}", "{\"data\":{\"translations\":[{\"translatedText\":7}]}}", "{\"data\":{\"translations\":[{\"translatedText\":\" \"}]}}", "{\"data\":{\"translations\":[{\"translatedText\":\"x\"},{\"translatedText\":\"y\"}]}}", "{\"data\":{\"translations\":[{\"translatedText\":\"x\",\"model\":\"translation-llm\"}]}}", "<html>Error</html>", "{\"data\":"]
        for fixture in invalid {
            XCTAssertThrowsError(try GoogleCloudTranslationProvider.parse(Data(fixture.utf8), request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .invalidResponse)
            }
        }
        let output = try MTProviderFixture.json(["data": ["translations": [["translatedText": String(repeating: "x", count: 524_289)]]]])
        XCTAssertThrowsError(try GoogleCloudTranslationProvider.parse(output, request: input)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .responseTooLarge)
        }
        let unknown = Data("{\"data\":{\"translations\":[{\"translatedText\":\"text\",\"detectedSourceLanguage\":\"unknown\"}]}}".utf8)
        XCTAssertNil(try GoogleCloudTranslationProvider.parse(unknown, request: input).source)
    }

    func testGoogleQuotaReasonsDistinguish403QuotaRateAndPermissionWithoutEchoes() throws {
        for (reason, expected) in [("dailyLimitExceeded", RemoteTranslationError.quotaExceeded), ("quotaExceeded", .quotaExceeded), ("userRateLimitExceeded", .rateLimited), ("rateLimitExceeded", .rateLimited), ("forbidden", .forbidden), ("keyInvalid", .invalidKey)] {
            let body = try MTProviderFixture.json(["error": ["code": 403, "message": "fixture-private-key-and-text", "errors": [["reason": reason]]]])
            let error = GoogleCloudTranslationProvider.failure(status: 403, body: body)
            XCTAssertEqual(error, expected)
            XCTAssertFalse(error.localizedDescription.contains("fixture-private"))
            XCTAssertThrowsError(try GoogleCloudTranslationProvider.parse(body, request: input)) { XCTAssertEqual($0 as? RemoteTranslationError, expected) }
        }
        for (message, expected) in [("Daily Limit Exceeded", RemoteTranslationError.quotaExceeded), ("User Rate Limit Exceeded", .rateLimited), ("private text with Daily Limit Exceeded inside", .forbidden)] {
            XCTAssertEqual(GoogleCloudTranslationProvider.failure(status: 403, body: try MTProviderFixture.json(["error": ["message": message]])), expected)
        }
        for (status, expected) in [(401, RemoteTranslationError.invalidKey), (429, .rateLimited), (500, .serviceUnavailable), (504, .timedOut)] {
            XCTAssertEqual(GoogleCloudTranslationProvider.failure(status: status, body: Data()), expected)
        }
    }

    func testGoogleRealProviderUsesBoundedTransportWithOneAttempt() async throws {
        let session = MTProviderFixture.session()
        defer { session.invalidateAndCancel() }
        let result = try await GoogleCloudTranslationProvider(configuration: MTProviderFixture.config(.googleCloud), apiKey: "fixture", session: session).translate(input)
        XCTAssertEqual(result.text, "\n  译文 &amp;\n\n🌍\n")
        XCTAssertEqual(result.source, "en")
        for (scenario, expected) in [("quota", RemoteTranslationError.quotaExceeded), ("redirect", .redirected), ("html", .invalidResponse), ("oversize", .responseTooLarge), ("timeout", .timedOut)] {
            let config = MTProviderFixture.config(.googleCloud, scenario: scenario)
            do {
                _ = try await GoogleCloudTranslationProvider(configuration: config, apiKey: "fixture", session: session).translate(input)
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? RemoteTranslationError, expected) }
            XCTAssertEqual(MTProviderURLProtocol.starts.withLock { $0[config.endpoint] }, 1)
        }
    }

    func testGoogleCancellationBeforeHeadersAndDuringBodyStopsTransport() async throws {
        for scenario in ["waitingheaders", "waitingbody"] {
            let session = MTProviderFixture.session()
            defer { session.invalidateAndCancel() }
            let config = MTProviderFixture.config(.googleCloud, scenario: scenario)
            let task = Task { try await GoogleCloudTranslationProvider(configuration: config, apiKey: "fixture", session: session).translate(input) }
            try await MTProviderFixture.waitFor(config.endpoint, stopped: false)
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled translation completed") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await MTProviderFixture.waitFor(config.endpoint, stopped: true)
        }
    }
}

@MainActor
enum MTProviderFixture {
    static func config(_ kind: TranslationServiceKind, scenario: String = "success") -> TranslationServiceConfiguration {
        var value = TranslationServiceConfiguration(kind: kind)
        value.endpoint = "https://mt-provider.test/\(scenario)/\(kind.rawValue)/\(UUID().uuidString)"
        return value
    }
    static func session() -> URLSession {
        let config = TranslationHTTPPolicy.sessionConfiguration()
        config.protocolClasses = [MTProviderURLProtocol.self]
        return URLSession(configuration: config)
    }
    static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    static func waitFor(_ url: String, stopped: Bool) async throws {
        for _ in 0..<100 {
            let count = stopped ? MTProviderURLProtocol.stops.withLock { $0[url, default: 0] }
                : MTProviderURLProtocol.starts.withLock { $0[url, default: 0] }
            if count > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The request did not reach the expected transport state")
        throw URLError(.timedOut)
    }
}

final class MTProviderURLProtocol: URLProtocol {
    static let starts = Mutex<[String: Int]>([:])
    static let stops = Mutex<[String: Int]>([:])
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mt-provider.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.starts.withLock { $0[url.absoluteString, default: 0] += 1 }
        if url.path.contains("/waitingheaders/") { return }
        if url.path.contains("/timeout/") { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let quota = url.path.contains("/quota/")
        let status = quota ? 403 : url.path.contains("/redirect/") ? 307 : 200
        var headers = ["Content-Type": url.path.contains("/html/") ? "text/html" : "application/json; charset=UTF-8"]
        if url.path.contains("/oversize/") { headers["Content-Length"] = "4194305" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path.contains("/waitingbody/") { return }
        let body: String
        if quota { body = "{\"error\":{\"code\":\"Arrearage\",\"errors\":[{\"reason\":\"dailyLimitExceeded\"}],\"message\":\"fixture-private\"}}" }
        else if url.path.contains("/googleCloud/") { body = "{\"data\":{\"translations\":[{\"translatedText\":\"\\n  译文 &amp;\\n\\n🌍\\n\",\"detectedSourceLanguage\":\"en\"}]}}" }
        else { body = "{\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\"\\n  译文 &amp;\\n\\n🌍\\n\"}}]}" }
        for byte in body.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stops.withLock { $0[request.url!.absoluteString, default: 0] += 1 } }
}

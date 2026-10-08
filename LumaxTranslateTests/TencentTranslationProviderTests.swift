import Foundation
import Synchronization
import XCTest
@testable import LumaxTranslate

@MainActor
final class TencentTranslationProviderTests: XCTestCase {
    private let input = TranslationRequest(id: UUID(), text: "\n  Hello 🌍\n\nLast line\n", source: nil, target: "zh-Hant")

    func testRequestUsesDedicatedProtocolAndPreservesOneRawText() throws {
        var config = TranslationServiceConfiguration(kind: .tencentTranslation)
        config.additionalInstructions = "must never reach this dedicated request"
        let http = try TencentTranslationProvider.makeRequest(configuration: config, apiKey: " fixture-key ", request: input)
        XCTAssertEqual(http.url?.absoluteString, "https://tokenhub.tencentmaas.com/v1/api/translations")
        XCTAssertEqual(http.httpMethod, "POST")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(http.httpShouldHandleCookies)
        let body = try TencentFixture.object(XCTUnwrap(http.httpBody))
        XCTAssertEqual(Set(body.keys), ["model", "text", "target", "stream"])
        XCTAssertEqual(body["model"] as? String, "hy-mt2-plus")
        XCTAssertEqual(body["text"] as? String, input.text)
        XCTAssertEqual(body["target"] as? String, "zh-TR")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertFalse(String(decoding: http.httpBody!, as: UTF8.self).contains("fixture-key"))
    }

    func testRegionalAndCustomRootsAppendOnlyDedicatedPathAndExplicitSource() throws {
        for root in ["https://tokenhub.tencentmaas.com", "https://tokenhub-intl.tencentmaas.com", "https://fixture.test/customer/root/"] {
            var config = TranslationServiceConfiguration(kind: .tencentTranslation)
            config.endpoint = root
            let request = TranslationRequest(id: UUID(), text: "繁體", source: "zh-Hant", target: "en")
            let http = try TencentTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: request)
            XCTAssertEqual(http.url?.absoluteString, root.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/api/translations")
            XCTAssertEqual(try TencentFixture.object(http.httpBody!)["source"] as? String, "zh-TR")
        }
    }

    func testLanguageIntersectionAndProviderReverseCodes() {
        let expected = Set(["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "pt", "it", "ru", "ar", "hi", "th", "vi", "id", "ms", "nl", "pl", "tr", "uk", "cs", "he", "fa", "bn", "ta", "te", "ur", "fil"])
        for target in [false, true] {
            XCTAssertEqual(Set(TencentTranslationLanguages.identifiers(asTarget: target)), expected)
            for id in expected {
                let code = TencentTranslationLanguages.code(for: id, asTarget: target)
                XCTAssertNotNil(code)
                XCTAssertEqual(code.flatMap(TencentTranslationLanguages.detectedSourceIdentifier), id)
            }
            XCTAssertEqual(TencentTranslationLanguages.code(for: "zh-TW", asTarget: target), "zh-TR")
            XCTAssertEqual(TencentTranslationLanguages.code(for: "zh-CN", asTarget: target), "zh")
            XCTAssertEqual(TencentTranslationLanguages.code(for: "pt-BR", asTarget: target), "pt")
            for unsupported in ["pt-PT", "nb", "sv", "auto", "unknown"] {
                XCTAssertNil(TencentTranslationLanguages.code(for: unsupported, asTarget: target))
            }
        }
        XCTAssertEqual(TencentTranslationLanguages.detectedSourceIdentifier(from: " zh-tr "), "zh-Hant")
        XCTAssertEqual(TencentTranslationLanguages.detectedSourceIdentifier(from: "zh"), "zh-Hans")
        for unknown in ["auto", "", "zh-TW", "zh-Hant", "pt-PT", "not-a-language"] {
            XCTAssertNil(TencentTranslationLanguages.detectedSourceIdentifier(from: unknown))
        }
    }

    func testInputByteLimitPreservesBoundaryAndCountsMultibyteAndJSONEscaping() throws {
        let config = TranslationServiceConfiguration(kind: .tencentTranslation)
        for text in [String(repeating: "a", count: 8_192), String(repeating: "🌍", count: 2_048), String(repeating: "\u{0001}", count: 8_192)] {
            let request = TranslationRequest(id: UUID(), text: text, source: "en", target: "de")
            let http = try TencentTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: request)
            XCTAssertEqual(try TencentFixture.object(http.httpBody!)["text"] as? String, text)
            XCTAssertLessThan(http.httpBody!.count, 65_536)
        }
        for text in [String(repeating: "a", count: 8_193), String(repeating: "🌍", count: 2_049)] {
            let request = TranslationRequest(id: UUID(), text: text, source: nil, target: "en")
            XCTAssertThrowsError(try TencentTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: request)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .inputTooLarge)
            }
        }
    }

    func testKeysWhitespaceAndUnsupportedLanguagesFailBeforeTransport() {
        let config = TranslationServiceConfiguration(kind: .tencentTranslation)
        for (key, expected) in [(nil, RemoteTranslationError.missingKey), (" \n", .missingKey), ("a\r\nInjected: b", .invalidKey), ("a b", .invalidKey), (String(repeating: "x", count: 8_193), .invalidKey)] {
            XCTAssertThrowsError(try TencentTranslationProvider.makeRequest(configuration: config, apiKey: key, request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, expected)
            }
        }
        for (text, source, target, expected) in [(" \n", nil, "en", RemoteTranslationError.invalidRequest), ("text", "auto", "en", .unsupportedLanguage), ("text", nil, "pt-PT", .unsupportedLanguage)] {
            let request = TranslationRequest(id: UUID(), text: text, source: source, target: target)
            XCTAssertThrowsError(try TencentTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: request)) {
                XCTAssertEqual($0 as? RemoteTranslationError, expected)
            }
        }
    }

    func testWrongProviderIsRejected() {
        XCTAssertThrowsError(try TencentTranslationProvider.makeRequest(configuration: TranslationServiceConfiguration(kind: .deepSeek), apiKey: "fixture", request: input)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .modelUnavailable)
        }
    }

    func testCompleteResponsePreservesParagraphsAndUnknownSource() throws {
        let text = "\n  <tag> &amp; \"引号\" 🌍\n\n末行\n"
        let result = try TencentTranslationProvider.parse(TencentFixture.response(text: text), request: input)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.target, "zh-Hant")
        XCTAssertNil(result.source)
        for source in [NSNull(), "auto", "unknown", "zh-TW"] as [Any] {
            var body = try TencentFixture.object(TencentFixture.response())
            body["source"] = source
            XCTAssertNil(try TencentTranslationProvider.parse(TencentFixture.json(body), request: input).source)
        }
    }

    func testResponseRecognizesTraditionalSourceBeforeLocaleNormalizationAndKeepsExplicitSource() throws {
        var body = try TencentFixture.object(TencentFixture.response())
        body["source"] = "zh-TR"
        let data = try TencentFixture.json(body)
        XCTAssertEqual(try TencentTranslationProvider.parse(data, request: input).source, "zh-Hant")
        let explicit = TranslationRequest(id: input.id, text: input.text, source: "en-US", target: input.target)
        XCTAssertEqual(try TencentTranslationProvider.parse(data, request: explicit).source, "en")
    }

    func testRejectsMissingWrongTypedOrDifferentTargetAndWrongTypedSource() throws {
        for target in [NSNull(), "zh", "zh-TW", 42, true] as [Any] {
            var body = try TencentFixture.object(TencentFixture.response())
            body["target"] = target
            assertFailure(try TencentFixture.json(body), .invalidResponse)
        }
        var body = try TencentFixture.object(TencentFixture.response())
        body.removeValue(forKey: "target")
        assertFailure(try TencentFixture.json(body), .invalidResponse)
        body["target"] = "zh-TR"
        body["source"] = 7
        assertFailure(try TencentFixture.json(body), .invalidResponse)
    }

    func testFinishReasonRequiredAndRefusalDoesNotReturnPartialText() throws {
        for (reason, expected) in [("length", RemoteTranslationError.incompleteResponse), ("tool_calls", .incompleteResponse), ("unknown", .incompleteResponse), ("sensitive", .refused), ("content_filter", .refused)] {
            assertFailure(try TencentFixture.response(reason: reason), expected)
        }
        assertFailure(try TencentFixture.response(reason: nil), .incompleteResponse)
        for refusal in ["private refusal body", false, ["text": "refused"]] as [Any] {
            assertFailure(try TencentFixture.response(extraMessage: ["refusal": refusal]), .refused)
        }
    }

    func testToolOrFunctionOutputNeverMasqueradesAsTranslation() throws {
        for field in ["tool_calls", "function_call"] {
            for value in [["name": "read_file"], [["name": "read_file"]], true, "call"] as [Any] {
                assertFailure(try TencentFixture.response(extraMessage: [field: value]), .invalidResponse)
            }
        }
        let permitted = try TencentFixture.response(extraMessage: ["tool_calls": [], "function_call": NSNull(), "refusal": NSNull(), "reasoning_content": "never translation"])
        XCTAssertEqual(try TencentTranslationProvider.parse(permitted, request: input).text, TencentFixture.text)
    }

    func testStrictChoiceIndexAndAssistantText() throws {
        for index in [true, false, "0", -1, 1, NSNull()] as [Any] {
            assertFailure(try TencentFixture.response(index: index), .invalidResponse)
        }
        for role in ["user", "tool", "system", "", 42, NSNull()] as [Any] {
            assertFailure(try TencentFixture.response(extraMessage: ["role": role]), .invalidResponse)
        }
        for text in [" \n", 42, false, [], NSNull()] as [Any] {
            assertFailure(try TencentFixture.response(extraMessage: ["content": text]), .invalidResponse)
        }
        var body = try TencentFixture.object(TencentFixture.response())
        let choices = body["choices"] as! [Any]
        for value in [[], choices + choices] {
            body["choices"] = value
            assertFailure(try TencentFixture.json(body), .invalidResponse)
        }
    }

    func testMalformedAndMissingFieldsAreSafeFailures() {
        for text in ["{}", "[]", "<html>private upstream body</html>", "{\"choices\":", "{\"choices\":[{}],\"target\":\"zh-TR\"}"] {
            assertFailure(Data(text.utf8), .invalidResponse)
        }
        assertFailure(Data([0xff, 0xfe]), .invalidResponse)
    }

    func testOutputAndResponseBounds() throws {
        XCTAssertEqual(try TencentTranslationProvider.parse(TencentFixture.response(text: String(repeating: "🌍", count: 131_072)), request: input).text.utf8.count, 524_288)
        assertFailure(try TencentFixture.response(text: String(repeating: "🌍", count: 131_073)), .responseTooLarge)
        assertFailure(Data(repeating: 32, count: 4_194_305), .responseTooLarge)
    }

    func testKnownGatewayCodesMapWithoutPrivateMessages() throws {
        let codes: [(String, RemoteTranslationError)] = [
            ("400003", .inputTooLarge), ("413001", .inputTooLarge),
            ("400004", .modelUnavailable), ("400005", .modelUnavailable), ("401006", .modelUnavailable),
            ("401001", .invalidKey), ("401002", .invalidKey), ("401003", .invalidKey), ("401004", .invalidKey), ("401005", .invalidKey),
            ("401007", .quotaExceeded), ("401008", .quotaExceeded), ("403004", .quotaExceeded),
            ("403001", .forbidden), ("403002", .forbidden), ("403003", .forbidden), ("403005", .forbidden), ("403006", .forbidden),
            ("429001", .rateLimited), ("429002", .rateLimited), ("429003", .rateLimited), ("429004", .rateLimited), ("429005", .rateLimited), ("429006", .rateLimited),
            ("451001", .refused), ("500001", .serviceUnavailable), ("502001", .serviceUnavailable), ("503001", .serviceUnavailable), ("504001", .timedOut)
        ]
        for (code, expected) in codes {
            for value in [code, Int(code)!] as [Any] {
                let body = try TencentFixture.json(["error": ["code": value, "message": "private fixture text and key", "message_zh": "private fixture"]])
                let error = TencentTranslationProvider.failure(status: 400, body: body)
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.localizedDescription.contains("private fixture"))
                assertFailure(body, expected)
            }
        }
    }

    func testHTTPFallbackDoesNotInterpretMessagesOrInventCancellation() throws {
        for (status, expected) in [(200, RemoteTranslationError.invalidResponse), (204, .invalidResponse), (307, .redirected), (400, .invalidRequest), (401, .invalidKey), (402, .quotaExceeded), (403, .forbidden), (404, .modelUnavailable), (408, .timedOut), (413, .inputTooLarge), (429, .rateLimited), (451, .refused), (499, .invalidRequest), (500, .serviceUnavailable), (502, .serviceUnavailable), (504, .timedOut)] {
            for body in [Data("private fixture text and key".utf8), try TencentFixture.json(["error": ["code": "unknown", "message": "401002 private fixture"]]), try TencentFixture.json(["error": ["code": true]])] {
                XCTAssertEqual(TencentTranslationProvider.failure(status: status, body: body), expected)
            }
        }
        assertFailure(try TencentFixture.json(["code": "private-unknown"]), .invalidResponse)
    }

    func testProviderUsesBoundedTransportAndOneAttemptAcrossErrors() async throws {
        let session = TencentFixture.session()
        defer { session.invalidateAndCancel() }
        let config = TencentFixture.config()
        let result = try await TencentTranslationProvider(configuration: config, apiKey: "fixture", session: session).translate(input)
        XCTAssertEqual(result.text, TencentFixture.text)
        XCTAssertNil(result.source)
        for (scenario, expected) in [("quota", RemoteTranslationError.quotaExceeded), ("redirect", .redirected), ("html", .invalidResponse), ("oversize", .responseTooLarge), ("timeout", .timedOut), ("connection", .connectionFailed), ("truncated", .invalidResponse)] {
            let config = TencentFixture.config(scenario)
            do {
                _ = try await TencentTranslationProvider(configuration: config, apiKey: "fixture", session: session).translate(input)
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? RemoteTranslationError, expected) }
            XCTAssertEqual(TencentFixtureProtocol.starts.withLock { $0[TencentFixture.url(config)] }, 1)
        }
        XCTAssertEqual(TencentFixtureProtocol.starts.withLock { $0[TencentFixture.url(config)] }, 1)
    }

    func testCancellationBeforeStartMakesNoRequest() async {
        let config = TencentFixture.config()
        let session = TencentFixture.session()
        defer { session.invalidateAndCancel() }
        let task = Task { try await TencentTranslationProvider(configuration: config, apiKey: "fixture", session: session).translate(input) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(TencentFixtureProtocol.starts.withLock { $0[TencentFixture.url(config)] })
    }

    func testCancellationBeforeHeadersAndDuringBodyStopsLoading() async throws {
        for scenario in ["waitingheaders", "waitingbody"] {
            let session = TencentFixture.session()
            defer { session.invalidateAndCancel() }
            let config = TencentFixture.config(scenario)
            let task = Task { try await TencentTranslationProvider(configuration: config, apiKey: "fixture", session: session).translate(input) }
            try await TencentFixture.waitFor(TencentFixture.url(config), stopped: false)
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await TencentFixture.waitFor(TencentFixture.url(config), stopped: true)
            XCTAssertEqual(TencentFixtureProtocol.starts.withLock { $0[TencentFixture.url(config)] }, 1)
        }
    }

    private func assertFailure(_ data: Data, _ expected: RemoteTranslationError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TencentTranslationProvider.parse(data, request: input), file: file, line: line) {
            XCTAssertEqual($0 as? RemoteTranslationError, expected, file: file, line: line)
        }
    }
}

nonisolated private enum TencentFixture {
    static let text = "\n  译文 &amp;\n\n🌍\n"
    static func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    static func response(text: String = text, reason: String? = "stop", index: Any = 0, extraMessage: [String: Any] = [:]) throws -> Data {
        var message: [String: Any] = ["role": "assistant", "content": text]
        message.merge(extraMessage) { _, new in new }
        var choice: [String: Any] = ["index": index, "message": message]
        if let reason { choice["finish_reason"] = reason }
        return try json(["id": "fixture", "created": 123, "choices": [choice], "target": "zh-TR", "usage": ["prompt_tokens": 20, "completion_tokens": 10]])
    }
    static func session() -> URLSession {
        let config = TranslationHTTPPolicy.sessionConfiguration()
        config.protocolClasses = [TencentFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    static func config(_ scenario: String = "success") -> TranslationServiceConfiguration {
        var config = TranslationServiceConfiguration(kind: .tencentTranslation)
        config.endpoint = "https://tencent-fixture.test/\(scenario)/\(UUID().uuidString)"
        return config
    }
    static func url(_ config: TranslationServiceConfiguration) -> String { config.endpoint + "/v1/api/translations" }
    static func waitFor(_ url: String, stopped: Bool) async throws {
        for _ in 0..<100 {
            let count: Int
            if stopped { count = TencentFixtureProtocol.stops.withLock { $0[url, default: 0] } }
            else if url.contains("/waitingbody/") { count = TencentFixtureProtocol.bodyStarts.withLock { $0[url, default: 0] } }
            else { count = TencentFixtureProtocol.starts.withLock { $0[url, default: 0] } }
            if count > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Request failed to reach the expected transport state")
        throw URLError(.timedOut)
    }
}

private final class TencentFixtureProtocol: URLProtocol {
    static let starts = Mutex<[String: Int]>([:])
    static let bodyStarts = Mutex<[String: Int]>([:])
    static let stops = Mutex<[String: Int]>([:])
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tencent-fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.starts.withLock { $0[url.absoluteString, default: 0] += 1 }
        if url.path.contains("/waitingheaders/") { return }
        if url.path.contains("/timeout/") { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        if url.path.contains("/connection/") {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: URLError.cannotConnectToHost.rawValue, userInfo: [NSLocalizedDescriptionKey: "private fixture text and key"]))
            return
        }
        let quota = url.path.contains("/quota/")
        let status = quota ? 402 : url.path.contains("/redirect/") ? 307 : 200
        var headers = ["Content-Type": url.path.contains("/html/") ? "text/html" : "application/json; charset=UTF-8"]
        if url.path.contains("/oversize/") { headers["Content-Length"] = "4194305" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path.contains("/waitingbody/") {
            client?.urlProtocol(self, didLoad: Data("{\"choices\":[".utf8))
            Self.bodyStarts.withLock { $0[url.absoluteString, default: 0] += 1 }
            return
        }
        let body: Data
        if quota { body = Data("{\"error\":{\"code\":\"401008\",\"message\":\"private fixture\"}}".utf8) }
        else if url.path.contains("/truncated/") { body = Data("{\"choices\":[".utf8) }
        else { body = try! TencentFixture.response() }
        // Deliberately splits multibyte UTF-8 characters between transport reads.
        for byte in body { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stops.withLock { $0[request.url!.absoluteString, default: 0] += 1 } }
}

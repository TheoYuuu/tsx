import Foundation
import Synchronization
import XCTest
@testable import TranslateX

@MainActor
final class DedicatedTranslationProviderTests: XCTestCase {
    private let input = TranslationRequest(id: UUID(), text: "\n  Hello 🌍\n\nSecond paragraph.\n", source: nil, target: "zh-Hant")

    func testDeepLUsesOfficialJSONAuthenticationAndAutomaticSourceOmission() throws {
        let request = try DedicatedTranslationProvider.makeRequest(
            configuration: TranslationServiceConfiguration(kind: .deepL), apiKey: "fixture:fx", request: input
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "DeepL-Auth-Key fixture:fx")
        XCTAssertNil(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        let body = try dictionary(request.httpBody!)
        XCTAssertEqual(body["text"] as? [String], [input.text])
        XCTAssertEqual(body["target_lang"] as? String, "ZH-HANT")
        XCTAssertEqual(body["preserve_formatting"] as? Bool, true)
        XCTAssertNil(body["source_lang"])
        XCTAssertNil(body["model"])
        XCTAssertNil(body["messages"])
    }

    func testDeepLUsesSelectedPaidOrRegionalEndpointWithoutKeyBasedRerouting() throws {
        for host in ["api.deepl.com", "api-us.deepl.com", "api-jp.deepl.com"] {
            var config = TranslationServiceConfiguration(kind: .deepL)
            config.endpoint = "https://\(host)"
            let request = try DedicatedTranslationProvider.makeRequest(configuration: config, apiKey: "fixture:fx", request: input)
            XCTAssertEqual(request.url?.host, host)
            XCTAssertEqual(request.url?.path, "/v2/translate")
        }
    }

    func testDeepLPreservesKnownTargetVariantsAndUsesBaseSources() throws {
        for (identifier, expectedSource, expectedTarget) in [
            ("en-US", "EN", "EN-US"), ("en-GB", "EN", "EN-GB"),
            ("pt-BR", "PT", "PT-BR"), ("pt-PT", "PT", "PT-PT"),
            ("zh-Hans", "ZH", "ZH-HANS"), ("zh-Hant", "ZH", "ZH-HANT"),
            ("fr-CA", "FR", "FR-CA")
        ] {
            XCTAssertEqual(DedicatedTranslationLanguages.code(for: identifier, kind: .deepL, asTarget: false), expectedSource)
            XCTAssertEqual(DedicatedTranslationLanguages.code(for: identifier, kind: .deepL, asTarget: true), expectedTarget)
            let text = TranslationRequest(id: UUID(), text: "fixture", source: identifier, target: "de")
            let request = try DedicatedTranslationProvider.makeRequest(configuration: TranslationServiceConfiguration(kind: .deepL), apiKey: "fixture", request: text)
            XCTAssertEqual(try dictionary(request.httpBody!)["source_lang"] as? String, expectedSource)
        }
    }

    func testAzureUsesRegionHeaderAndQueryOnlyForLanguageOptions() throws {
        var config = TranslationServiceConfiguration(kind: .azureTranslator)
        config.region = "EastUS"
        let text = TranslationRequest(id: UUID(), text: input.text, source: "pt-PT", target: "zh-Hans")
        let request = try DedicatedTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: text)
        XCTAssertEqual(request.url?.host, "api.cognitive.microsofttranslator.com")
        XCTAssertEqual(request.url?.path, "/translate")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region"), "eastus")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(query(request.url!), ["api-version": "3.0", "from": "pt-PT", "to": "zh-Hans", "textType": "plain"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [[String: String]])
        XCTAssertEqual(body, [["Text": input.text]])
    }

    func testAzureGlobalRequestOmitsRegionAndAutomaticSource() throws {
        let request = try DedicatedTranslationProvider.makeRequest(configuration: TranslationServiceConfiguration(kind: .azureTranslator), apiKey: "fixture", request: input)
        XCTAssertNil(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region"))
        XCTAssertNil(query(request.url!)["from"])
    }

    func testAzureCustomResourceRootAndExplicitProxyBasePaths() throws {
        for (base, expectedPath) in [
            ("https://sample.cognitiveservices.azure.com", "/translator/text/v3.0/translate"),
            ("https://sample.cognitiveservices.azure.com/translator/text/v3.0", "/translator/text/v3.0/translate"),
            ("https://gateway.test/company/translator", "/company/translator/translate")
        ] {
            var config = TranslationServiceConfiguration(kind: .azureTranslator)
            config.endpoint = base
            let request = try DedicatedTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input)
            XCTAssertEqual(request.url?.path, expectedPath)
        }
    }

    func testAzureMapsCanonicalPortugueseAndSerbianWithoutLosingVariant() {
        for (identifier, expected) in [("pt-BR", "pt"), ("pt-PT", "pt-PT"), ("sr", "sr-Cyrl"), ("sr-Latn", "sr-Latn"), ("fr-CA", "fr-CA")] {
            XCTAssertEqual(DedicatedTranslationLanguages.code(for: identifier, kind: .azureTranslator, asTarget: true), expected)
            XCTAssertEqual(DedicatedTranslationLanguages.code(for: identifier, kind: .azureTranslator, asTarget: false), expected)
        }
        XCTAssertEqual(DedicatedTranslationLanguages.detectedSourceIdentifier(from: "SR-CYRL", kind: .azureTranslator), "sr")
    }

    func testDedicatedPickersOnlyContainRoundTrippableImplementedLanguages() {
        for kind in [TranslationServiceKind.deepL, .azureTranslator] {
            for asTarget in [false, true] {
                let values = DedicatedTranslationLanguages.identifiers(for: kind, asTarget: asTarget)
                XCTAssertFalse(values.isEmpty)
                XCTAssertEqual(values.count, Set(values).count)
                for identifier in values {
                    XCTAssertEqual(LanguageCatalog.canonicalIdentifier(identifier), identifier)
                    XCTAssertNotNil(DedicatedTranslationLanguages.code(for: identifier, kind: kind, asTarget: asTarget))
                }
            }
        }
        XCTAssertTrue(DedicatedTranslationLanguages.identifiers(for: .openAI, asTarget: true).isEmpty)
        // DeepL extended languages require a different model capability. They
        // are deliberately excluded until that scope is implemented and tested.
        XCTAssertNil(DedicatedTranslationLanguages.code(for: "hi", kind: .deepL, asTarget: true))
        XCTAssertNil(DedicatedTranslationLanguages.code(for: "en-AU", kind: .azureTranslator, asTarget: true))
    }

    func testUnsupportedLanguageAndInvalidCredentialsFailBeforeNetworking() {
        let unsupported = TranslationRequest(id: UUID(), text: "fixture", source: nil, target: "hi")
        XCTAssertThrowsError(try DedicatedTranslationProvider.makeRequest(configuration: TranslationServiceConfiguration(kind: .deepL), apiKey: "fixture", request: unsupported)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .unsupportedLanguage)
        }
        for kind in [TranslationServiceKind.deepL, .azureTranslator] {
            XCTAssertThrowsError(try DedicatedTranslationProvider.makeRequest(configuration: TranslationServiceConfiguration(kind: kind), apiKey: nil, request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .missingKey)
            }
            XCTAssertThrowsError(try DedicatedTranslationProvider.makeRequest(configuration: TranslationServiceConfiguration(kind: kind), apiKey: "fixture\r\nInjected: header", request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .invalidKey)
            }
        }
    }

    func testDeepLChecksSerializedJSONSizeAfterEscaping() throws {
        let config = TranslationServiceConfiguration(kind: .deepL)
        let small = TranslationRequest(id: UUID(), text: String(repeating: "\u{0001}", count: 20_000), source: "en", target: "de")
        let request = try DedicatedTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: small)
        XCTAssertLessThanOrEqual(request.httpBody!.count, DedicatedTranslationProvider.maximumDeepLBodyBytes)
        let oversized = TranslationRequest(id: UUID(), text: String(repeating: "\u{0001}", count: 30_000), source: "en", target: "de")
        XCTAssertLessThan(oversized.text.utf8.count, DedicatedTranslationProvider.maximumInputBytes)
        XCTAssertThrowsError(try DedicatedTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: oversized)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .inputTooLarge)
        }
    }

    func testAzureChecksCharacterLimitIndependentlyOfUTF8Limit() throws {
        let config = TranslationServiceConfiguration(kind: .azureTranslator)
        let boundary = TranslationRequest(id: UUID(), text: String(repeating: "a", count: 50_000), source: "en", target: "de")
        XCTAssertNoThrow(try DedicatedTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: boundary))
        let oversized = TranslationRequest(id: UUID(), text: boundary.text + "a", source: "en", target: "de")
        XCTAssertThrowsError(try DedicatedTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: oversized)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .inputTooLarge)
        }
    }

    func testRawUTF8InputLimitAppliesToBothProtocols() {
        let oversized = TranslationRequest(id: UUID(), text: String(repeating: "界", count: 22_000), source: "zh-Hans", target: "en")
        for kind in [TranslationServiceKind.deepL, .azureTranslator] {
            XCTAssertThrowsError(try DedicatedTranslationProvider.makeRequest(configuration: TranslationServiceConfiguration(kind: kind), apiKey: "fixture", request: oversized)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .inputTooLarge)
            }
        }
    }

    func testDeepLParserPreservesParagraphWhitespaceAndReportedDetection() throws {
        let expected = "\n  你好\n\n第二段。\n"
        let body = try json(["translations": [["text": expected, "detected_source_language": "EN", "extra": "future field"]]])
        let result = try DedicatedTranslationProvider.parse(body, kind: .deepL, request: input)
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.source, "en")
        XCTAssertEqual(result.target, "zh-Hant")
    }

    func testDeepLUnknownChineseScriptIsNotInvented() throws {
        let body = try json(["translations": [["text": "Hello", "detected_source_language": "ZH"]]])
        let auto = TranslationRequest(id: UUID(), text: "你好", source: nil, target: "en")
        XCTAssertNil(try DedicatedTranslationProvider.parse(body, kind: .deepL, request: auto).source)
        let explicit = TranslationRequest(id: UUID(), text: "你好", source: "zh-Hant", target: "en")
        XCTAssertEqual(try DedicatedTranslationProvider.parse(body, kind: .deepL, request: explicit).source, "zh-Hant")
        XCTAssertNil(DedicatedTranslationLanguages.detectedSourceIdentifier(from: "unknown", kind: .deepL))
    }

    func testAzureParserPreservesTextAndChecksReturnedTarget() throws {
        let expected = "  譯文\n\n下一段\n"
        let body = try json([["detectedLanguage": ["language": "en", "score": 0.99], "translations": [["text": expected, "to": "ZH-HANT"]]]])
        let result = try DedicatedTranslationProvider.parse(body, kind: .azureTranslator, request: input)
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.source, "en")
        let wrongTarget = try json([["translations": [["text": expected, "to": "zh-Hans"]]]])
        XCTAssertThrowsError(try DedicatedTranslationProvider.parse(wrongTarget, kind: .azureTranslator, request: input)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .invalidResponse)
        }
    }

    func testAzureMissingOrUnknownDetectionLeavesSourceUnknown() throws {
        let rows: [[String: Any]] = [
            ["translations": [["text": "譯文", "to": "zh-Hant"]]],
            ["detectedLanguage": ["language": "unknown", "score": 1], "translations": [["text": "譯文", "to": "zh-Hant"]]],
            ["detectedLanguage": ["language": "en", "score": 2], "translations": [["text": "譯文", "to": "zh-Hant"]]],
            ["detectedLanguage": ["language": "en"], "translations": [["text": "譯文", "to": "zh-Hant"]]]
        ]
        for row in rows {
            XCTAssertNil(try DedicatedTranslationProvider.parse(json([row]), kind: .azureTranslator, request: input).source)
        }
    }

    func testMalformedEmptyAndExtraResultEntriesAreRejected() throws {
        let invalidDeepL: [[String: Any]] = [[:], ["translations": []], ["translations": [["text": " " ]]], ["translations": [["text": "a"], ["text": "b"]]]]
        for body in invalidDeepL {
            XCTAssertThrowsError(try DedicatedTranslationProvider.parse(json(body), kind: .deepL, request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try DedicatedTranslationProvider.parse(Data("not-json".utf8), kind: .azureTranslator, request: input)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .invalidResponse)
        }
        XCTAssertThrowsError(try DedicatedTranslationProvider.parse(json([]), kind: .azureTranslator, request: input)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .invalidResponse)
        }
    }

    func testOutputLimitRejectsOversizedTranslationWithoutTruncation() throws {
        let body = try json(["translations": [["text": String(repeating: "x", count: DedicatedTranslationProvider.maximumOutputBytes + 1)]]])
        XCTAssertThrowsError(try DedicatedTranslationProvider.parse(body, kind: .deepL, request: input)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .responseTooLarge)
        }
    }

    func testDeepLErrorMatrixUsesFixedLocalMessages() {
        let body = Data("{\"message\":\"fixture-sensitive\"}".utf8)
        let cases: [(Int, RemoteTranslationError)] = [(400, .invalidRequest), (401, .authenticationFailed), (403, .authenticationFailed), (413, .inputTooLarge), (429, .rateLimited), (529, .rateLimited), (456, .quotaExceeded), (500, .serviceUnavailable), (503, .serviceUnavailable), (504, .timedOut)]
        for (status, expected) in cases {
            let error = DedicatedTranslationProvider.failure(kind: .deepL, status: status, body: body)
            XCTAssertEqual(error, expected)
            XCTAssertFalse(error.localizedDescription.contains("fixture-sensitive"))
        }
    }

    func testAzureNumericAndStringErrorCodesOverrideBroadHTTPStatus() throws {
        let cases: [(Int, Int, RemoteTranslationError)] = [
            (403, 403001, .quotaExceeded), (401, 401000, .invalidKey), (401, 401015, .invalidKey),
            (400, 400019, .unsupportedLanguage), (400, 400035, .unsupportedLanguage), (400, 400036, .unsupportedLanguage),
            (400, 400050, .inputTooLarge), (400, 400077, .inputTooLarge),
            (408, 408001, .serviceUnavailable), (408, 408002, .timedOut),
            (429, 429000, .rateLimited), (429, 429002, .rateLimited), (500, 500000, .serviceUnavailable), (503, 503000, .serviceUnavailable)
        ]
        for (status, code, expected) in cases {
            for encodedCode: Any in [code, String(code)] {
                let body = try json(["error": ["code": encodedCode, "message": "fixture-sensitive"]])
                let error = DedicatedTranslationProvider.failure(kind: .azureTranslator, status: status, body: body)
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.localizedDescription.contains("fixture-sensitive"))
            }
        }
        XCTAssertEqual(DedicatedTranslationProvider.failure(kind: .azureTranslator, status: 403, body: Data()), .forbidden)
    }

    func testBothDedicatedProtocolsTranslateThroughBoundedTransport() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for kind in [TranslationServiceKind.deepL, .azureTranslator] {
            let result = try await DedicatedTranslationProvider(configuration: config(kind), apiKey: "fixture", session: session).translate(input)
            XCTAssertEqual(result.text, "\n  譯文\n\n下一段。\n")
            XCTAssertEqual(result.source, "en")
            XCTAssertEqual(result.target, "zh-Hant")
        }
    }

    func testQuotaResponsesAreNotRetriedOrMappedToInvalidKey() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for kind in [TranslationServiceKind.deepL, .azureTranslator] {
            let config = config(kind, "quota")
            let path = try DedicatedTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input).url!.path
            DedicatedTranslationURLProtocol.starts.withLock { $0[path] = 0 }
            do {
                _ = try await DedicatedTranslationProvider(configuration: config, apiKey: "fixture", session: session).translate(input)
                XCTFail("Expected quota failure")
            } catch { XCTAssertEqual(error as? RemoteTranslationError, .quotaExceeded) }
            XCTAssertEqual(DedicatedTranslationURLProtocol.starts.withLock { $0[path] }, 1)
        }
    }

    func testTransportRejectsRedirectMIMEAndDeclaredOversizedBody() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for (scenario, expected) in [("redirect", RemoteTranslationError.redirected), ("html", .invalidResponse), ("oversized", .responseTooLarge), ("timeout", .timedOut)] {
            do {
                _ = try await DedicatedTranslationProvider(configuration: config(.deepL, scenario), apiKey: "fixture", session: session).translate(input)
                XCTFail("Expected transport failure")
            } catch { XCTAssertEqual(error as? RemoteTranslationError, expected) }
        }
    }

    func testCancellationBeforeHeadersAndDuringBodyStopsNetworkRequest() async throws {
        for scenario in ["waitingheaders", "waitingbody"] {
            let session = session()
            defer { session.invalidateAndCancel() }
            let config = config(.deepL, scenario)
            let path = try DedicatedTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input).url!.path
            DedicatedTranslationURLProtocol.starts.withLock { $0[path] = 0 }
            DedicatedTranslationURLProtocol.stops.withLock { $0[path] = 0 }
            let task = Task { try await DedicatedTranslationProvider(configuration: config, apiKey: "fixture", session: session).translate(input) }
            try await waitFor(path: path, stopped: false)
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled request completed") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await waitFor(path: path, stopped: true)
            XCTAssertEqual(DedicatedTranslationURLProtocol.stops.withLock { $0[path] }, 1)
        }
    }

    private func waitFor(path: String, stopped: Bool) async throws {
        for _ in 0..<100 {
            let count = stopped ? DedicatedTranslationURLProtocol.stops.withLock { $0[path, default: 0] }
                : DedicatedTranslationURLProtocol.starts.withLock { $0[path, default: 0] }
            if count > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Transport did not reach expected state")
        throw URLError(.timedOut)
    }

    private func config(_ kind: TranslationServiceKind, _ scenario: String = "success") -> TranslationServiceConfiguration {
        TranslationServiceConfiguration(name: "Fixture", kind: kind, endpoint: "https://dedicated.test/\(scenario)/\(kind.rawValue)", model: "")
    }

    private func session() -> URLSession {
        let config = TranslationHTTPPolicy.sessionConfiguration()
        config.protocolClasses = [DedicatedTranslationURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap {
            guard let value = $0.value else { return nil }
            return ($0.name, value)
        })
    }
}

private final class DedicatedTranslationURLProtocol: URLProtocol {
    static let starts = Mutex<[String: Int]>([:])
    static let stops = Mutex<[String: Int]>([:])
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dedicated.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        Self.starts.withLock { $0[path, default: 0] += 1 }
        if path.contains("/waitingheaders/") { return }
        if path.contains("/timeout/") {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let deepL = path.contains("/deepL/")
        let quota = path.contains("/quota/")
        let status = quota ? (deepL ? 456 : 403) : path.contains("/redirect/") ? 307 : 200
        var headers = ["Content-Type": path.contains("/html/") ? "text/html" : "application/json; charset=UTF-8"]
        if path.contains("/oversized/") { headers["Content-Length"] = String(BoundedTranslationHTTPTransport.maximumResponseBytes + 1) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path.contains("/waitingbody/") { return }
        let body: String
        if quota {
            body = "{\"error\":{\"code\":403001,\"message\":\"fixture-sensitive\"}}"
        } else if deepL {
            body = "{\"translations\":[{\"text\":\"\\n  譯文\\n\\n下一段。\\n\",\"detected_source_language\":\"EN\"}]}"
        } else {
            body = "[{\"detectedLanguage\":{\"language\":\"en\",\"score\":1},\"translations\":[{\"text\":\"\\n  譯文\\n\\n下一段。\\n\",\"to\":\"zh-Hant\"}]}]"
        }
        for byte in body.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.stops.withLock { $0[request.url!.path, default: 0] += 1 } }
}

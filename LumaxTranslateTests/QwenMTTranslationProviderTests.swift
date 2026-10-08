import Foundation
import XCTest
@testable import LumaxTranslate

@MainActor
final class QwenMTTranslationProviderTests: XCTestCase {
    private let input = TranslationRequest(id: UUID(), text: "\n  原文 <tag> &amp; 🌍\n\n尾行\n", source: nil, target: "zh-Hant")

    func testQwenRequestContainsOnlyRawUserTextAndTopLevelTranslationOptions() throws {
        var config = TranslationServiceConfiguration(kind: .qwenMT)
        config.additionalInstructions = "Must never become a system prompt"
        let http = try QwenMTTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input)
        XCTAssertEqual(http.url?.absoluteString, "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertFalse(http.httpShouldHandleCookies)
        let body = try MTProviderFixture.object(http.httpBody!)
        XCTAssertEqual(body["model"] as? String, "qwen-mt-flash")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "user", "content": input.text]])
        XCTAssertEqual(body["translation_options"] as? [String: String], ["source_lang": "auto", "target_lang": "zh_tw"])
        for field in ["system", "extra_body", "max_tokens", "temperature", "tools", "enable_thinking", "stream_options"] { XCTAssertNil(body[field]) }
    }

    func testQwenPreservesChosenRegionWorkspaceAndProxyBasePath() throws {
        for base in ["https://dashscope-intl.aliyuncs.com/compatible-mode/v1", "https://fixture.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", "https://proxy.test/team/compatible-mode/v1"] {
            var config = TranslationServiceConfiguration(kind: .qwenMT)
            config.endpoint = base
            let request = TranslationRequest(id: UUID(), text: "文字", source: "zh-Hans", target: "fil")
            let http = try QwenMTTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: request)
            XCTAssertEqual(http.url?.absoluteString, base + "/chat/completions")
            XCTAssertEqual(try MTProviderFixture.object(http.httpBody!)["translation_options"] as? [String: String], ["source_lang": "zh", "target_lang": "tl"])
        }
    }

    func testQwenLanguagesAreTheFlashIntersectionWithoutRegionalFallbacks() {
        XCTAssertEqual(QwenMTTranslationLanguages.identifiers().count, 52)
        for asTarget in [false, true] {
            for id in QwenMTTranslationLanguages.identifiers(asTarget: asTarget) { XCTAssertNotNil(QwenMTTranslationLanguages.code(for: id, asTarget: asTarget)) }
            for (id, expected) in [("zh-Hans", "zh"), ("zh-Hant", "zh_tw"), ("fil", "tl"), ("nb", "nb"), ("pt", "pt")] {
                XCTAssertEqual(QwenMTTranslationLanguages.code(for: id, asTarget: asTarget), expected)
            }
        }
        for id in ["pt-PT", "ga", "auto", "unknown"] { XCTAssertNil(QwenMTTranslationLanguages.code(for: id)) }
        XCTAssertNil(QwenMTTranslationLanguages.detectedSourceIdentifier(from: "en"))
    }

    func testQwenRejectsOtherModelsAndUnsupportedLanguagesBeforeNetworking() {
        for model in ["qwen-mt-plus", "qwen-mt-turbo", "qwen-plus", ""] {
            var config = TranslationServiceConfiguration(kind: .qwenMT)
            config.model = model
            XCTAssertThrowsError(try QwenMTTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input))
        }
        for identifier in ["pt-PT", "ga", "auto"] {
            let request = TranslationRequest(id: UUID(), text: "text", source: nil, target: identifier)
            XCTAssertThrowsError(try QwenMTTranslationProvider.makeRequest(configuration: .init(kind: .qwenMT), apiKey: "fixture", request: request)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .unsupportedLanguage)
            }
        }
    }

    func testQwenRejectsInvalidKeysAndOversizedInput() {
        for (key, expected) in [(nil, RemoteTranslationError.missingKey), ("a\r\nX: b", .invalidKey)] {
            XCTAssertThrowsError(try QwenMTTranslationProvider.makeRequest(configuration: .init(kind: .qwenMT), apiKey: key, request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, expected)
            }
        }
        let large = TranslationRequest(id: UUID(), text: String(repeating: "x", count: 65_537), source: nil, target: "en")
        XCTAssertThrowsError(try QwenMTTranslationProvider.makeRequest(configuration: .init(kind: .qwenMT), apiKey: "fixture", request: large)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .inputTooLarge)
        }
    }

    func testQwenParserPreservesTextAndNeverInventsAutoDetectedLanguage() throws {
        let data = try response(content: "\n  <tag> &amp; 🌍\n\n原样\n")
        let result = try QwenMTTranslationProvider.parse(data, request: input)
        XCTAssertEqual(result.text, "\n  <tag> &amp; 🌍\n\n原样\n")
        XCTAssertNil(result.source)
        XCTAssertEqual(result.target, "zh-Hant")
        let manual = TranslationRequest(id: UUID(), text: input.text, source: "zh-CN", target: "en")
        XCTAssertEqual(try QwenMTTranslationProvider.parse(data, request: manual).source, "zh-Hans")
    }

    func testQwenRequiresCompleteStopRatherThanHTTP200OrPartialText() throws {
        for reason: Any in ["length", NSNull(), "future_reason", "tool_calls"] {
            XCTAssertThrowsError(try QwenMTTranslationProvider.parse(response(reason: reason), request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .incompleteResponse)
            }
        }
        XCTAssertThrowsError(try QwenMTTranslationProvider.parse(response(reason: "content_filter"), request: input)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .refused)
        }
        for body in ["{}", "{\"choices\":[]}", "{\"choices\":[{\"delta\":{\"content\":\"text\"}}]}", "{\"choices\":", "<html>Error</html>"] {
            XCTAssertThrowsError(try QwenMTTranslationProvider.parse(Data(body.utf8), request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .invalidResponse)
            }
        }
    }

    func testQwenRejectsToolsRefusalWrongRoleExtraChoicesAndEmptyContent() throws {
        for changes: [String: Any] in [["tool_calls": [["id": "tool"]]], ["function_call": ["name": "function"]], ["role": "user"], ["content": " \n"], ["content": ["text": "structured"]]] {
            XCTAssertThrowsError(try QwenMTTranslationProvider.parse(response(messageChanges: changes), request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try QwenMTTranslationProvider.parse(response(messageChanges: ["refusal": "private"]), request: input)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .refused)
        }
        var object = try MTProviderFixture.object(response())
        object["choices"] = (object["choices"] as! [[String: Any]]) + (object["choices"] as! [[String: Any]])
        XCTAssertThrowsError(try QwenMTTranslationProvider.parse(MTProviderFixture.json(object), request: input)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .invalidResponse)
        }
        XCTAssertThrowsError(try QwenMTTranslationProvider.parse(response(content: String(repeating: "x", count: 524_289)), request: input)) {
            XCTAssertEqual($0 as? RemoteTranslationError, .responseTooLarge)
        }
    }

    func testQwenRejectsBooleanIndexAndMalformedCompletionFieldTypes() throws {
        for changes: [String: Any] in [["index": false], ["index": "0"], ["index": 0.5], ["finish_reason": 0]] {
            var object = try MTProviderFixture.object(response())
            var choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
            choices[0].merge(changes) { _, new in new }
            object["choices"] = choices
            XCTAssertThrowsError(try QwenMTTranslationProvider.parse(MTProviderFixture.json(object), request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .invalidResponse)
            }
        }
    }

    func testQwenCodeMappingsDoNotTreatTokenThrottlingAsAccountBalance() throws {
        for (code, expected) in [("insufficient_quota", RemoteTranslationError.rateLimited), ("Throttling.AllocationQuota", .rateLimited), ("Arrearage", .quotaExceeded), ("InvalidApiKey", .invalidKey), ("invalid_api_key", .invalidKey), ("AccessDenied", .forbidden), ("ModelNotFound", .modelUnavailable), ("DataInspectionFailed", .refused), ("InternalError", .serviceUnavailable)] {
            for nested in [true, false] {
                let error: [String: Any] = ["code": code, "message": "fixture-private-key-and-text"]
                let payload: [String: Any]
                if nested { payload = ["error": error] }
                else { payload = error }
                let data = try MTProviderFixture.json(payload)
                let value = QwenMTTranslationProvider.failure(status: 400, body: data)
                XCTAssertEqual(value, expected)
                XCTAssertFalse(value.localizedDescription.contains("fixture-private"))
                XCTAssertThrowsError(try QwenMTTranslationProvider.parse(data, request: input)) { XCTAssertEqual($0 as? RemoteTranslationError, expected) }
            }
        }
        XCTAssertEqual(QwenMTTranslationProvider.failure(status: 403, body: Data()), .forbidden)
        XCTAssertEqual(QwenMTTranslationProvider.failure(status: 429, body: Data()), .rateLimited)
    }

    func testQwenProviderUsesBoundedJSONTransportAndNeverRetries() async throws {
        let session = MTProviderFixture.session()
        defer { session.invalidateAndCancel() }
        let result = try await QwenMTTranslationProvider(configuration: MTProviderFixture.config(.qwenMT), apiKey: "fixture", session: session).translate(input)
        XCTAssertEqual(result.text, "\n  译文 &amp;\n\n🌍\n")
        XCTAssertNil(result.source)
        for (scenario, expected) in [("quota", RemoteTranslationError.quotaExceeded), ("redirect", .redirected), ("html", .invalidResponse), ("oversize", .responseTooLarge), ("timeout", .timedOut)] {
            let config = MTProviderFixture.config(.qwenMT, scenario: scenario)
            do {
                _ = try await QwenMTTranslationProvider(configuration: config, apiKey: "fixture", session: session).translate(input)
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? RemoteTranslationError, expected) }
            let url = try config.endpointURL(appending: "chat/completions").absoluteString
            XCTAssertEqual(MTProviderURLProtocol.starts.withLock { $0[url] }, 1)
        }
    }

    func testQwenCancellationBeforeHeadersAndDuringBodyStopsTransport() async throws {
        for scenario in ["waitingheaders", "waitingbody"] {
            let session = MTProviderFixture.session()
            defer { session.invalidateAndCancel() }
            let config = MTProviderFixture.config(.qwenMT, scenario: scenario)
            let url = try config.endpointURL(appending: "chat/completions").absoluteString
            let task = Task { try await QwenMTTranslationProvider(configuration: config, apiKey: "fixture", session: session).translate(input) }
            try await MTProviderFixture.waitFor(url, stopped: false)
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled translation completed") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await MTProviderFixture.waitFor(url, stopped: true)
        }
    }

    private func response(content: String = "译文", reason: Any = "stop", messageChanges: [String: Any] = [:]) throws -> Data {
        var message: [String: Any] = ["role": "assistant", "content": content, "refusal": NSNull(), "tool_calls": NSNull(), "function_call": NSNull()]
        message.merge(messageChanges) { _, new in new }
        return try MTProviderFixture.json(["choices": [["index": 0, "finish_reason": reason, "message": message]], "usage": ["total_tokens": 5]])
    }
}

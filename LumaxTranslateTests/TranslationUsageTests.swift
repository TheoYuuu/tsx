import Foundation
import XCTest
@testable import LumaxTranslate

@MainActor
final class TranslationUsageTests: XCTestCase {
    private let input = TranslationRequest(id: UUID(), text: "A deliberately longer input 🌍", source: "en", target: "de")

    func testUsageRejectsInvalidCountsWithoutInventingMissingTotals() throws {
        let usage = TranslationUsage(inputTokens: -1, outputTokens: 0, totalTokens: Int.max, characters: 13)
        XCTAssertEqual(usage, TranslationUsage(outputTokens: 0, characters: 13))
        XCTAssertEqual(try JSONDecoder().decode(TranslationUsage.self, from: JSONEncoder().encode(usage)), usage)
        let corrupt = Data(#"{"inputTokens":true,"outputTokens":-1,"totalTokens":1.5,"characters":1000000001}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TranslationUsage.self, from: corrupt).nonempty)
        XCTAssertNil(TranslationUsage(inputTokens: 2, outputTokens: 3).totalTokens)
        XCTAssertNil(TranslationResult(text: "Hallo", source: "en", target: "de").usage)
        XCTAssertNil(TranslationResult(text: "Hallo", source: "en", target: "de", usage: TranslationUsage()).usage)
    }

    func testRemoteMetadataRejectsBooleansStringsFractionsAndUnboundedValues() throws {
        for value: Any in [true, false, "12", -1, 1.25, 1_000_000_001, NSNull()] {
            var parser = RemoteTranslationResponseParser(usesResponses: false)
            let payload = try chatJSON(usage: ["prompt_tokens": value, "completion_tokens": 8])
            XCTAssertEqual(try parser.readJSON(payload), "Hallo")
            XCTAssertEqual(parser.usage, TranslationUsage(outputTokens: 8))
        }
    }

    func testChatUsageOnlyTailIsCapturedWithoutCompletingStreamEarly() throws {
        var parser = RemoteTranslationResponseParser(usesResponses: false)
        _ = try parser.consume(Data(#"{"choices":[{"index":0,"delta":{"content":"Hallo"},"finish_reason":"stop"}]}"#.utf8))
        _ = try parser.consume(Data(#"{"choices":[],"usage":{"prompt_tokens":21,"completion_tokens":4,"total_tokens":25}}"#.utf8))
        XCTAssertFalse(parser.isComplete)
        XCTAssertThrowsError(try parser.completedText())
        _ = try parser.consume(Data("[DONE]".utf8))
        XCTAssertEqual(try parser.completedText(), "Hallo")
        XCTAssertEqual(parser.usage, TranslationUsage(inputTokens: 21, outputTokens: 4, totalTokens: 25))
    }

    func testDeepSeekUsageOnStopChunkAndJSONFallbackHaveSameCounts() throws {
        var parser = RemoteTranslationResponseParser(usesResponses: false)
        _ = try parser.consume(Data(#"{"choices":[{"delta":{"content":"Hallo"},"finish_reason":"stop"}],"usage":{"prompt_tokens":17,"completion_tokens":9,"total_tokens":26}}"#.utf8))
        _ = try parser.consume(Data("[DONE]".utf8))
        var jsonParser = RemoteTranslationResponseParser(usesResponses: false)
        _ = try jsonParser.readJSON(chatJSON(usage: ["prompt_tokens": 17, "completion_tokens": 9, "total_tokens": 26]))
        XCTAssertEqual(parser.usage, TranslationUsage(inputTokens: 17, outputTokens: 9, totalTokens: 26))
        XCTAssertEqual(parser.usage, jsonParser.usage)
    }

    func testUsageDoesNotTurnMissingStopIntoSuccess() throws {
        var parser = RemoteTranslationResponseParser(usesResponses: false)
        _ = try parser.consume(Data(#"{"choices":[],"usage":{"total_tokens":42}}"#.utf8))
        XCTAssertThrowsError(try parser.consume(Data("[DONE]".utf8))) {
            XCTAssertEqual($0 as? RemoteTranslationError, .incompleteResponse)
        }
    }

    func testResponsesUsageComesFromCompletedEnvelopeForStreamAndJSON() throws {
        let response: [String: Any] = [
            "status": "completed",
            "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Hallo"]]]],
            "usage": ["input_tokens": 37, "output_tokens": 11, "total_tokens": 48]
        ]
        var streamParser = RemoteTranslationResponseParser(usesResponses: true)
        _ = try streamParser.consume(JSONSerialization.data(withJSONObject: ["type": "response.completed", "response": response]))
        var jsonParser = RemoteTranslationResponseParser(usesResponses: true)
        _ = try jsonParser.readJSON(JSONSerialization.data(withJSONObject: response))
        XCTAssertEqual(streamParser.usage, TranslationUsage(inputTokens: 37, outputTokens: 11, totalTokens: 48))
        XCTAssertEqual(jsonParser.usage, streamParser.usage)
    }

    func testClaudeUsageDeltasReplaceCumulativeOutputAndKeepStartingInput() throws {
        var parser = ClaudeTranslationResponseParser()
        for event in [
            #"{"type":"message_start","message":{"type":"message","role":"assistant","content":[],"usage":{"input_tokens":25,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Hallo"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":null},"usage":{"output_tokens":4}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":15}}"#,
            #"{"type":"message_stop"}"#
        ] { _ = try parser.consume(Data(event.utf8)) }
        XCTAssertEqual(try parser.completedText(), "Hallo")
        XCTAssertEqual(parser.usage, TranslationUsage(inputTokens: 25, outputTokens: 15))
        XCTAssertNil(parser.usage?.totalTokens)
    }

    func testClaudeProvisionalStartOutputDoesNotBecomeFinalUsage() throws {
        var parser = ClaudeTranslationResponseParser()
        for event in [
            #"{"type":"message_start","message":{"type":"message","role":"assistant","content":[],"usage":{"input_tokens":25,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Hallo"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#
        ] { _ = try parser.consume(Data(event.utf8)) }
        XCTAssertEqual(try parser.completedText(), "Hallo")
        XCTAssertEqual(parser.usage, TranslationUsage(inputTokens: 25))
    }

    func testClaudeInvalidOptionalUsageNeverInvalidatesTranslation() throws {
        var parser = ClaudeTranslationResponseParser()
        let data = Data(#"{"type":"message","role":"assistant","content":[{"type":"text","text":"Hallo"}],"stop_reason":"end_turn","usage":{"input_tokens":true,"output_tokens":-4}}"#.utf8)
        XCTAssertEqual(try parser.readJSON(data), "Hallo")
        XCTAssertNil(parser.usage)
    }

    func testQwenAndTencentPreserveReportedJSONTokenUsage() throws {
        let payload = try chatJSON(usage: ["prompt_tokens": 53, "completion_tokens": 9, "total_tokens": 62])
        let expected = TranslationUsage(inputTokens: 53, outputTokens: 9, totalTokens: 62)
        XCTAssertEqual(try QwenMTTranslationProvider.parse(payload, request: input).usage, expected)
        XCTAssertEqual(try TencentTranslationProvider.parse(payload, request: input).usage, expected)
    }

    func testMissingOrMalformedMetadataStaysUnknownInSuccessfulJSONResponses() throws {
        for usage: Any in [NSNull(), [:] as [String: Int], "unsupported"] {
            let payload = try chatJSON(usage: usage)
            XCTAssertNil(try QwenMTTranslationProvider.parse(payload, request: input).usage)
            XCTAssertNil(try TencentTranslationProvider.parse(payload, request: input).usage)
            var parser = RemoteTranslationResponseParser(usesResponses: false)
            XCTAssertEqual(try parser.readJSON(payload), "Hallo")
            XCTAssertNil(parser.usage)
        }
    }

    func testDeepLUsesOnlyReportedBilledCharactersAndDoesNotChangeRequest() throws {
        let response = Data(#"{"translations":[{"text":"Hallo","detected_source_language":"EN","billed_characters":7}]}"#.utf8)
        XCTAssertEqual(try DedicatedTranslationProvider.parse(response, kind: .deepL, request: input).usage,
                       TranslationUsage(characters: 7))
        for response in [
            #"{"translations":[{"text":"Hallo"}]}"#,
            #"{"translations":[{"text":"Hallo","billed_characters":true}]}"#,
            #"{"translations":[{"text":"Hallo","billed_characters":-3}]}"#
        ] {
            XCTAssertNil(try DedicatedTranslationProvider.parse(Data(response.utf8), kind: .deepL, request: input).usage)
        }
        let http = try DedicatedTranslationProvider.makeRequest(configuration: .init(kind: .deepL), apiKey: "fixture", request: input)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.httpBody)) as? [String: Any])
        XCTAssertNil(body["show_billed_characters"])
    }

    func testGoogleAndAzureDoNotUseInputLengthAsBilledCharacters() throws {
        let google = Data(#"{"data":{"translations":[{"translatedText":"Hallo"}]}}"#.utf8)
        XCTAssertNil(try GoogleCloudTranslationProvider.parse(google, request: input).usage)
        let azure = Data(#"[{"translations":[{"text":"Hallo","to":"de"}]}]"#.utf8)
        XCTAssertNil(try DedicatedTranslationProvider.parse(azure, kind: .azureTranslator, request: input).usage)
    }

    func testStreamingRequestsDoNotRequireUsageSupportFromCompatibleServers() throws {
        for kind: TranslationServiceKind in [.openAI, .deepSeek, .openAICompatible, .ollama] {
            var config = TranslationServiceConfiguration(kind: kind)
            if kind == .ollama { config.model = "fixture-model" }
            if kind == .openAICompatible { config.endpoint = "https://fixture.test/v1"; config.model = "fixture-model" }
            let http = try RemoteTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.httpBody)) as? [String: Any])
            XCTAssertNil(body["stream_options"])
        }
    }

    func testUsagePresentationFiltersBothPurposesAndOrdersByRequestStart() {
        let completed = Date(timeIntervalSince1970: 1_800_000_000)
        let first = TranslationUsageRecord(id: UUID(), configurationID: nil, model: "fixture",
            purpose: .translation, outcome: .succeeded, completedAt: completed,
            duration: 20, usage: TranslationUsage(inputTokens: 2, outputTokens: 3))
        let second = TranslationUsageRecord(id: UUID(), configurationID: nil, model: "fixture",
            purpose: .sampleTest, outcome: .failed, completedAt: completed.addingTimeInterval(-1),
            duration: 1, usage: nil)
        XCTAssertEqual(TranslationUsagePresentation.filtered([first, second], purpose: .all).map(\.id), [second.id, first.id])
        XCTAssertEqual(TranslationUsagePresentation.filtered([first, second], purpose: .translations), [first])
        XCTAssertEqual(TranslationUsagePresentation.filtered([first, second], purpose: .sampleTests), [second])
        XCTAssertEqual(TranslationUsagePresentation.startedAt(second), completed.addingTimeInterval(-2))
        XCTAssertEqual(TranslationUsagePresentation.totalTokens([first, second]), 5)
        XCTAssertEqual(TranslationUsagePresentation.averageDuration([first, second]), 10.5)
    }

    func testUsagePresentationDistinguishesMissingCountsFromReportedZero() {
        let unknown = TranslationUsageRecord(id: UUID(), configurationID: nil, model: "fixture",
            purpose: .translation, outcome: .cancelled, completedAt: Date(), duration: 1, usage: nil)
        let zero = TranslationUsageRecord(id: UUID(), configurationID: nil, model: "fixture",
            purpose: .translation, outcome: .succeeded, completedAt: Date(), duration: 3,
            usage: TranslationUsage(inputTokens: 0, outputTokens: 0, totalTokens: 0))
        XCTAssertNil(TranslationUsagePresentation.totalTokens([unknown]))
        XCTAssertEqual(TranslationUsagePresentation.totalTokens([unknown, zero]), 0)
        XCTAssertNil(TranslationUsagePresentation.reportedTokens(TranslationUsage(inputTokens: 12)))
        XCTAssertNil(TranslationUsagePresentation.averageDuration([]))
        XCTAssertNil(TranslationUsagePresentation.totalTokens([]))
    }

    private func chatJSON(usage: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "choices": [["index": 0, "message": ["role": "assistant", "content": "Hallo"], "finish_reason": "stop"]],
            "target": "de", "usage": usage
        ])
    }
}

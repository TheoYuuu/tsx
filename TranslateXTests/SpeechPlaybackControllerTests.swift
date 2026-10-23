import Foundation
import XCTest
@testable import TranslateX

@MainActor
final class SpeechPlaybackControllerTests: XCTestCase {
    func testInitializationStopAndUnknownLanguageDoNotCreateSystemBackend() async throws {
        let (defaults, _) = try isolatedDefaults()
        var creations = 0
        let backend = RecordingSpeechBackend()
        let playback = SpeechPlaybackController(defaults: defaults) { creations += 1; return backend }
        let owner = UUID()
        playback.stop()
        playback.stop(owner: owner)
        playback.englishAccent = .british
        playback.toggle(text: "  \n", language: "en", owner: owner, side: .source)
        XCTAssertEqual(creations, 0)
        for language in [nil, "", "auto", " AUTO "] as [String?] {
            playback.toggle(text: "example", language: language, owner: owner, side: .source)
            XCTAssertEqual(playback.failure, .languageUnknown)
            XCTAssertFalse(playback.isSpeaking(owner: owner, side: .source))
        }
        XCTAssertEqual(creations, 0)
        playback.clearFailure()
        XCTAssertNil(playback.failure)
    }

    func testSameSideStopsImmediatelyAndNextClickStartsFromBeginning() async throws {
        let (playback, backend, _) = try fixture()
        let owner = UUID()
        playback.toggle(text: " example \n", language: "en", owner: owner, side: .source)
        let first = try XCTUnwrap(backend.requests.first)
        XCTAssertEqual(first.text, "example")
        XCTAssertTrue(playback.isSpeaking(owner: owner, side: .source))
        playback.toggle(text: "example", language: "en", owner: owner, side: .source)
        XCTAssertEqual(backend.stops, 1)
        XCTAssertEqual(backend.requests.count, 1)
        XCTAssertFalse(playback.isSpeaking(owner: owner, side: .source))
        playback.toggle(text: "example", language: "en", owner: owner, side: .source)
        XCTAssertEqual(backend.requests.count, 2)
        XCTAssertEqual(backend.requests.last?.text, "example")
        XCTAssertNotEqual(first.id, backend.requests.last?.id)
    }

    func testAnotherSideOrOwnerReplacesPlaybackAndLateCompletionsAreIgnored() async throws {
        let (playback, backend, _) = try fixture()
        let firstOwner = UUID(), secondOwner = UUID()
        playback.toggle(text: "example", language: "en", owner: firstOwner, side: .source)
        let first = try XCTUnwrap(backend.requests.last)
        playback.toggle(text: "示例", language: "zh-Hans", owner: firstOwner, side: .target)
        let second = try XCTUnwrap(backend.requests.last)
        backend.onCompletion?(first.id)
        XCTAssertTrue(playback.isSpeaking(owner: firstOwner, side: .target))
        XCTAssertFalse(playback.isSpeaking(owner: firstOwner, side: .source))
        playback.toggle(text: "another", language: "en", owner: secondOwner, side: .source)
        let third = try XCTUnwrap(backend.requests.last)
        backend.onCompletion?(second.id)
        backend.onCompletion?(first.id)
        XCTAssertTrue(playback.isSpeaking(owner: secondOwner, side: .source))
        XCTAssertFalse(playback.isSpeaking(owner: firstOwner, side: .target))
        XCTAssertEqual(backend.stops, 2)
        backend.onCompletion?(third.id)
        XCTAssertFalse(playback.isSpeaking(owner: secondOwner, side: .source))
    }

    func testStoppingAnUnrelatedOwnerDoesNotInterruptPlayback() async throws {
        let (playback, backend, _) = try fixture()
        let owner = UUID()
        playback.toggle(text: "example", language: "en", owner: owner, side: .source)
        playback.stop(owner: UUID())
        XCTAssertTrue(playback.isSpeaking(owner: owner, side: .source))
        XCTAssertEqual(backend.stops, 0)
        playback.stop(owner: owner)
        XCTAssertEqual(backend.stops, 1)
        XCTAssertFalse(playback.isSpeaking(owner: owner, side: .source))
        playback.stop()
        XCTAssertEqual(backend.stops, 1)
    }

    func testSynchronousCancellationDoesNotEraseTheReplacement() async throws {
        let (playback, backend, _) = try fixture()
        backend.completesOnStop = true
        let owner = UUID()
        playback.toggle(text: "example", language: "en", owner: owner, side: .source)
        playback.toggle(text: "示例", language: "zh-Hans", owner: owner, side: .target)
        XCTAssertTrue(playback.isSpeaking(owner: owner, side: .target))
        XCTAssertEqual(backend.requests.count, 2)
    }

    func testEnglishAccentPersistsStopsCurrentPlaybackAndSelectsStrictRegion() async throws {
        let (playback, backend, defaults) = try fixture()
        let owner = UUID()
        playback.toggle(text: "example", language: "en-GB", owner: owner, side: .source)
        XCTAssertEqual(backend.requests.last?.voice, "american")
        playback.englishAccent = .british
        XCTAssertFalse(playback.isSpeaking(owner: owner, side: .source))
        XCTAssertEqual(backend.stops, 1)
        XCTAssertEqual(backend.requests.count, 1)
        playback.toggle(text: "example", language: "en-US", owner: owner, side: .source)
        XCTAssertEqual(backend.requests.last?.voice, "british")
        XCTAssertEqual(SpeechPlaybackController(defaults: defaults).englishAccent, .british)
        playback.englishAccent = .british
        XCTAssertTrue(playback.isSpeaking(owner: owner, side: .source))
    }

    func testMissingBritishVoiceNeverFallsBackToAmericanOrAustralian() async throws {
        let (playback, backend, _) = try fixture()
        backend.voices = [.init(identifier: "american", language: "en-US"),
                          .init(identifier: "australian", language: "en-AU")]
        playback.englishAccent = .british
        playback.toggle(text: "example", language: "en", owner: UUID(), side: .source)
        XCTAssertEqual(playback.failure, .voiceUnavailable)
        XCTAssertTrue(backend.requests.isEmpty)
        backend.voices.append(.init(identifier: "british", language: "en-GB"))
        playback.toggle(text: "example", language: "en", owner: UUID(), side: .source)
        XCTAssertNil(playback.failure)
        XCTAssertEqual(backend.requests.last?.voice, "british")
        XCTAssertEqual(backend.voiceQueries, 2)
    }

    func testPersonalAndNoveltyVoicesAreExcludedEvenAtHigherQuality() async throws {
        let (playback, backend, _) = try fixture()
        backend.voices = [.init(identifier: "personal", language: "en-US", quality: 3, isPersonal: true),
                          .init(identifier: "novelty", language: "en-US", quality: 3, isNovelty: true),
                          .init(identifier: "ordinary", language: "en-US", quality: 1)]
        playback.toggle(text: "example", language: "en", owner: UUID(), side: .source)
        XCTAssertEqual(backend.requests.last?.voice, "ordinary")
        backend.voices.removeAll { $0.identifier == "ordinary" }
        playback.toggle(text: "example", language: "en", owner: UUID(), side: .source)
        XCTAssertEqual(playback.failure, .voiceUnavailable)
        XCTAssertEqual(backend.requests.count, 1)
    }

    func testMultilingualVoicesRespectLanguageScriptAndPreferExactRegion() async throws {
        let (playback, backend, _) = try fixture()
        backend.voices = [.init(identifier: "simplified", language: "zh-CN"),
                          .init(identifier: "traditional", language: "zh-TW"),
                          .init(identifier: "japanese", language: "ja-JP"),
                          .init(identifier: "french-canada", language: "fr-CA", quality: 3),
                          .init(identifier: "french-france", language: "fr-FR", quality: 1)]
        for (language, voice) in [("zh-Hans", "simplified"), ("zh-Hant", "traditional"),
                                  ("ja", "japanese"), ("fr-FR", "french-france")] {
            playback.toggle(text: "Constructed sample", language: language, owner: UUID(), side: .source)
            XCTAssertEqual(backend.requests.last?.voice, voice)
        }
        backend.voices = [.init(identifier: "simplified", language: "zh-CN")]
        playback.toggle(text: "構造範例", language: "zh-Hant", owner: UUID(), side: .source)
        XCTAssertEqual(playback.failure, .voiceUnavailable)
    }

    func testVoiceDisappearingBeforePlaybackClearsPlayingState() async throws {
        let (playback, backend, _) = try fixture()
        backend.acceptsPlayback = false
        let owner = UUID()
        playback.toggle(text: "example", language: "en", owner: owner, side: .source)
        XCTAssertEqual(playback.failure, .voiceUnavailable)
        XCTAssertFalse(playback.isSpeaking(owner: owner, side: .source))
        playback.stop(owner: UUID())
        XCTAssertEqual(playback.failure, .voiceUnavailable)
        playback.stop(owner: owner)
        XCTAssertNil(playback.failure)
    }

    func testUnknownPreferenceFallsBackWithoutWritingAndOnlyAccentIsPersisted() async throws {
        let (defaults, suite) = try isolatedDefaults()
        let backend = RecordingSpeechBackend()
        let fresh = SpeechPlaybackController(defaults: defaults) { backend }
        XCTAssertEqual(fresh.englishAccent, .american)
        XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        defaults.set("future-accent", forKey: SpeechPlaybackController.StorageKey.englishAccent)
        let playback = SpeechPlaybackController(defaults: defaults) { backend }
        XCTAssertEqual(playback.englishAccent, .american)
        XCTAssertEqual(defaults.string(forKey: SpeechPlaybackController.StorageKey.englishAccent), "future-accent")
        playback.toggle(text: "Constructed sample never persisted", language: "en", owner: UUID(), side: .source)
        playback.englishAccent = .british
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?.count, 1)
        XCTAssertEqual(defaults.string(forKey: SpeechPlaybackController.StorageKey.englishAccent), "british")
    }

    private func fixture() throws -> (SpeechPlaybackController, RecordingSpeechBackend, UserDefaults) {
        let (defaults, _) = try isolatedDefaults()
        let backend = RecordingSpeechBackend()
        return (SpeechPlaybackController(defaults: defaults) { backend }, backend, defaults)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "SpeechPlaybackControllerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }
}

@MainActor
private final class RecordingSpeechBackend: SpeechPlaybackBackend {
    struct Request {
        let text: String
        let voice: String
        let id: UUID
    }
    var onCompletion: (@MainActor @Sendable (UUID) -> Void)?
    var voices: [SpeechPlaybackVoice] = [.init(identifier: "american", language: "en-US"),
                                       .init(identifier: "british", language: "en-GB"),
                                       .init(identifier: "chinese", language: "zh-CN")]
    var requests: [Request] = []
    var stops = 0
    var voiceQueries = 0
    var acceptsPlayback = true
    var completesOnStop = false

    func availableVoices() -> [SpeechPlaybackVoice] {
        voiceQueries += 1
        return voices
    }

    func speak(text: String, voiceIdentifier: String, requestID: UUID) -> Bool {
        guard acceptsPlayback else { return false }
        requests.append(Request(text: text, voice: voiceIdentifier, id: requestID))
        return true
    }

    func stop() {
        stops += 1
        if completesOnStop, let id = requests.last?.id { onCompletion?(id) }
    }
}

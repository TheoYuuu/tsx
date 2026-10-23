import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import TranslateX

@MainActor
final class TranslationSpeechSessionTests: XCTestCase {
    func testCreatingAndEditingAWorkspaceNeverStartsPlaybackOrTranslation() async throws {
        let fixture = try fixture()
        fixture.model.editingChanged("A new sentence stays silent until requested.", isComposing: false)
        await settle()
        XCTAssertEqual(fixture.backend.requests.count, 0)
        XCTAssertFalse(fixture.session.isSpeaking(.source))
        XCTAssertFalse(fixture.session.isSpeaking(.target))
        XCTAssertNil(fixture.model.request)
    }

    func testAutoSourceCanBeReadBeforeAnyTranslationWithLocalLanguageDetection() throws {
        let fixture = try fixture(source: "auto", detectedSource: nil,
                                  original: "The quiet garden opens every morning for visitors.")
        XCTAssertNil(fixture.model.resolvedSource)
        fixture.session.toggle(.source)
        XCTAssertEqual(fixture.backend.requests.map(\.voice), ["constructed-en-US"])
        XCTAssertTrue(fixture.session.isSpeaking(.source))
        XCTAssertNil(fixture.model.request, "Reading must not create a translation request")
        XCTAssertNil(fixture.model.resolvedSource, "Local speech detection must not rewrite translation state")
    }

    func testExplicitAndPreviouslyResolvedLanguagesTakePriorityOverTextDetection() throws {
        let explicit = try fixture(source: "en", original: "这是专门构造的测试文字。")
        explicit.session.toggle(.source)
        XCTAssertEqual(explicit.backend.requests.map(\.voice), ["constructed-en-US"])
        XCTAssertNil(explicit.model.request)

        let resolved = try fixture(source: "auto", detectedSource: "fr",
                                   original: "The text alone would otherwise suggest English.")
        resolved.session.toggle(.source)
        XCTAssertEqual(resolved.backend.requests.map(\.voice), ["constructed-fr"])
        XCTAssertNil(resolved.model.request)
    }

    func testBothSidesPlayIndependentlyAndStoppingThenReadingStartsFromTheBeginning() throws {
        let fixture = try fixture()
        fixture.session.toggle(.source)
        XCTAssertTrue(fixture.session.isSpeaking(.source))
        fixture.session.toggle(.target)
        XCTAssertFalse(fixture.session.isSpeaking(.source))
        XCTAssertTrue(fixture.session.isSpeaking(.target))
        XCTAssertEqual(fixture.backend.requests.map(\.text), [fixture.model.text, fixture.model.translatedText])

        fixture.session.toggle(.target)
        XCTAssertFalse(fixture.session.isSpeaking(.target))
        fixture.session.toggle(.target)
        XCTAssertEqual(fixture.backend.requests.last?.text, fixture.model.translatedText)
        XCTAssertEqual(fixture.backend.requests.count, 3)
        XCTAssertNotEqual(fixture.backend.requests[1].id, fixture.backend.requests[2].id)
    }

    func testWorkspaceMutationsStopPlaybackWithoutAutomaticallyReadingTheReplacement() async throws {
        let mutations: [(String, (TranslationModel) -> Void)] = [
            ("source edit", { $0.editingChanged("An edited source sentence.", isComposing: false) }),
            ("target edit", { $0.editingChanged("修改后的构造译文。", isComposing: false, side: .target) }),
            ("external replacement", { _ = $0.beginExternalReplacement() }),
            ("swap", { $0.swapLanguages() }),
            ("clear", { $0.clear() }),
            ("composition", { $0.editingChanged($0.text, isComposing: true) }),
            ("source language", { $0.source = "fr" }),
            ("target language", { $0.target = "fr" })
        ]
        for (name, mutate) in mutations {
            let fixture = try fixture()
            fixture.session.toggle(.source)
            XCTAssertTrue(fixture.session.isSpeaking(.source), name)
            mutate(fixture.model)
            await settle()
            XCTAssertFalse(fixture.session.isSpeaking(.source), name)
            XCTAssertFalse(fixture.session.isSpeaking(.target), name)
            XCTAssertEqual(fixture.backend.requests.count, 1, name)
            XCTAssertEqual(fixture.backend.stopCount, 1, name)
        }
    }

    func testComposingTextCannotStartPlaybackAndCommitStaysSilent() async throws {
        let fixture = try fixture()
        fixture.model.editingChanged("ni hao", isComposing: true)
        fixture.session.toggle(.source)
        fixture.session.toggle(.target)
        XCTAssertTrue(fixture.backend.requests.isEmpty)
        fixture.model.editingChanged("你好，构造样例。", isComposing: false)
        await settle()
        XCTAssertTrue(fixture.backend.requests.isEmpty)
    }

    func testLateEditInvalidationCannotStopAnExplicitReadOfTheNewText() async throws {
        let fixture = try fixture()
        fixture.session.toggle(.source)
        fixture.model.editingChanged("Read this latest sentence from its beginning.", isComposing: false)
        // A fresh user click may arrive before Observation's main-actor task.
        fixture.session.toggle(.source)
        await settle()
        XCTAssertTrue(fixture.session.isSpeaking(.source))
        XCTAssertEqual(fixture.backend.requests.map(\.text), [
            "A quiet morning in the constructed garden.", "Read this latest sentence from its beginning."
        ])
        XCTAssertEqual(fixture.backend.stopCount, 1)
        fixture.model.editingChanged("A later edit must still stop the latest playback.", isComposing: false)
        await settle()
        XCTAssertFalse(fixture.session.isSpeaking(.source))
    }

    func testChangesInAnotherSessionDoNotStopTheWorkspaceCurrentlySpeaking() async throws {
        let fixture = try fixture()
        let secondModel = TranslationModel()
        secondModel.source = "en"
        secondModel.text = "A second constructed workspace."
        let secondSession = TranslationSpeechSession(model: secondModel, playback: fixture.playback)
        fixture.session.toggle(.source)
        secondSession.toggle(.source)
        XCTAssertFalse(fixture.session.isSpeaking(.source))
        XCTAssertTrue(secondSession.isSpeaking(.source))

        fixture.model.clear()
        fixture.session.stop()
        await settle()
        XCTAssertTrue(secondSession.isSpeaking(.source))
        XCTAssertEqual(fixture.backend.requests.count, 2)
        secondSession.stop()
    }

    func testReplacingScreenshotIdentityStopsReadingEvenWhenItsTextIsIdentical() async throws {
        let fixture = try fixture()
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        var handoff = try XCTUnwrap(fixture.model.makeHandoff())
        handoff.screenshot = ScreenshotDocument(image: image)
        fixture.model.acceptHandoff(handoff)
        fixture.session.toggle(.source)
        let previousIdentity = fixture.model.screenshot?.id
        handoff.screenshot = ScreenshotDocument(image: image)
        fixture.model.acceptHandoff(handoff)
        await settle()
        XCTAssertNotEqual(fixture.model.screenshot?.id, previousIdentity)
        XCTAssertFalse(fixture.session.isSpeaking(.source))
        XCTAssertEqual(fixture.backend.requests.count, 1)
        XCTAssertEqual(fixture.backend.stopCount, 1)
    }

    func testWindowDismissalScreenshotHidingAndShutdownStopPlaybackWithoutReplaying() async throws {
        _ = NSApplication.shared
        let originalLanguage = try XCTUnwrap(AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier))
        defer { L10n.apply(originalLanguage) }
        let operations: [(String, (WindowCoordinator) -> Void)] = [
            ("dismiss translation", { $0.dismissTranslation(restoreFocus: false) }),
            ("hide for screenshot", { _ = $0.hideForScreenshot() }),
            ("shutdown", { $0.shutdown() })
        ]
        for (name, operation) in operations {
            let suite = "TranslateXTests.SpeechWindowLifecycle.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = AppPreferences(defaults: defaults)
            let services = TranslationServiceStore(defaults: defaults, credentials: SpeechSessionCredentials())
            let backend = SpeechSessionBackend()
            let playback = SpeechPlaybackController(defaults: defaults, makeBackend: { backend })
            let windows = WindowCoordinator(preferences: preferences, services: services, speech: playback)
            defer { windows.shutdown() }
            windows.inputModel.source = "en"
            windows.inputModel.text = "A constructed passage for the window lifecycle."
            windows.speechSession.toggle(.source)
            XCTAssertTrue(windows.speechSession.isSpeaking(.source), name)

            // Exercise the production lifecycle without creating or showing a
            // window, activating an application, or reading system credentials.
            operation(windows)
            await settle()
            XCTAssertFalse(windows.speechSession.isSpeaking(.source), name)
            XCTAssertFalse(windows.speechSession.isSpeaking(.target), name)
            XCTAssertEqual(backend.stopCount, 1, name)
            XCTAssertEqual(backend.requests.count, 1, name)
            XCTAssertNil(windows.inputModel.request, name)
        }
    }

    func testStreamedTranslationChangesStopReadingTheOldFragmentWithoutCancellingTranslation() async throws {
        let suite = "TranslateXTests.SpeechStream.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = SpeechSessionCredentials()
        let services = TranslationServiceStore(defaults: defaults, credentials: credentials)
        let configuration = TranslationServiceConfiguration(kind: .deepSeek)
        try services.save(configuration, apiKey: "constructed-speech-test-key")
        try services.select(configuration.id)
        let provider = SpeechSessionStreamProvider()
        let model = TranslationModel(services: services, remoteProvider: { _, _, partial in
            provider.partial = partial
            return provider
        })
        defer { model.cancel(); provider.finish() }
        model.source = "en"
        model.text = "A constructed sentence for streaming translation."
        model.submit()
        for _ in 0..<100 where !provider.started { await Task.yield() }
        XCTAssertTrue(provider.started)
        provider.partial?("第一段构造译文")
        await settle()
        let backend = SpeechSessionBackend()
        let playback = SpeechPlaybackController(defaults: defaults, makeBackend: { backend })
        let session = TranslationSpeechSession(model: model, playback: playback)
        session.toggle(.target)
        XCTAssertTrue(session.isSpeaking(.target))
        provider.partial?("第一段构造译文，后续内容仍在到达。")
        await settle()
        XCTAssertFalse(session.isSpeaking(.target))
        XCTAssertEqual(backend.requests.map(\.text), ["第一段构造译文"])
        XCTAssertEqual(model.phase, .translating)
        XCTAssertNotNil(model.request)
        XCTAssertEqual(model.translatedText, "第一段构造译文，后续内容仍在到达。")
    }

    private func fixture(source: String = "en", detectedSource: String? = nil,
                         original: String = "A quiet morning in the constructed garden.") throws -> SpeechSessionFixture {
        let suite = "TranslateXTests.SpeechSession.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = TranslationModel()
        // A handoff constructs unresolved-language and completed pairs without
        // invoking Apple Translation, service credentials or a network provider.
        model.acceptHandoff(TranslationHandoff(text: original, translatedText: "构造花园中的一个安静早晨。",
            source: source, target: "zh-Hans", detectedSource: detectedSource, inputSide: .source,
            partialSide: nil, translationWasEdited: false, phase: .empty, completedResult: nil,
            serviceConfiguration: nil, serviceRevision: 0))
        let backend = SpeechSessionBackend()
        let playback = SpeechPlaybackController(defaults: defaults, makeBackend: { backend })
        let session = TranslationSpeechSession(model: model, playback: playback)
        return SpeechSessionFixture(model: model, session: session, playback: playback, backend: backend)
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

@MainActor
private struct SpeechSessionFixture {
    let model: TranslationModel
    let session: TranslationSpeechSession
    let playback: SpeechPlaybackController
    let backend: SpeechSessionBackend
}

@MainActor
private final class SpeechSessionBackend: SpeechPlaybackBackend {
    struct Request {
        let text: String
        let voice: String
        let id: UUID
    }
    var onCompletion: (@MainActor @Sendable (UUID) -> Void)?
    private(set) var requests: [Request] = []
    private(set) var stopCount = 0

    func availableVoices() -> [SpeechPlaybackVoice] {
        [SpeechPlaybackVoice(identifier: "constructed-en-US", language: "en-US"),
         SpeechPlaybackVoice(identifier: "constructed-en-GB", language: "en-GB"),
         SpeechPlaybackVoice(identifier: "constructed-zh", language: "zh-CN"),
         SpeechPlaybackVoice(identifier: "constructed-fr", language: "fr-FR")]
    }

    func speak(text: String, voiceIdentifier: String, requestID: UUID) -> Bool {
        requests.append(Request(text: text, voice: voiceIdentifier, id: requestID))
        return true
    }

    func stop() { stopCount += 1 }
}

@MainActor
private final class SpeechSessionCredentials: TranslationCredentialStore {
    private var values: [UUID: TranslationServiceCredential] = [:]
    func credential(for id: UUID) throws -> TranslationServiceCredential? { values[id] }
    func containsCredential(for id: UUID) throws -> Bool? { values[id] != nil }
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { values[id] = credential }
    func removeCredential(for id: UUID) throws { values[id] = nil }
}

@MainActor
private final class SpeechSessionStreamProvider: TranslationProvider {
    var partial: (@MainActor @Sendable (String) -> Void)?
    private(set) var started = false
    private var continuation: CheckedContinuation<TranslationResult, any Error>?

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

import AVFoundation
import Foundation
import Observation

enum EnglishSpeechAccent: String, CaseIterable {
    case american, british

    var languageIdentifier: String { self == .american ? "en-US" : "en-GB" }
}

enum SpeechPlaybackFailure: Equatable {
    case languageUnknown, voiceUnavailable
}

struct SpeechPlaybackVoice: Equatable, Sendable {
    let identifier: String
    let language: String
    var quality = 0
    var isPersonal = false
    var isNovelty = false
}

/// The only boundary that can produce sound; tests supply an in-memory backend.
@MainActor
protocol SpeechPlaybackBackend: AnyObject {
    var onCompletion: (@MainActor @Sendable (UUID) -> Void)? { get set }
    func availableVoices() -> [SpeechPlaybackVoice]
    func speak(text: String, voiceIdentifier: String, requestID: UUID) -> Bool
    func stop()
}

/// One manually triggered playback across all translation surfaces. Text is held
/// only by the active system utterance and is never written to preferences or logs.
@MainActor @Observable
final class SpeechPlaybackController {
    enum StorageKey {
        static let englishAccent = "speech.englishAccent"
    }

    var englishAccent: EnglishSpeechAccent {
        didSet {
            guard englishAccent != oldValue else { return }
            stop()
            defaults.set(englishAccent.rawValue, forKey: StorageKey.englishAccent)
        }
    }
    private(set) var failure: SpeechPlaybackFailure?
    private var active: Playback?
    @ObservationIgnored private var failureOwner: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeBackend: @MainActor () -> any SpeechPlaybackBackend
    @ObservationIgnored private var backend: (any SpeechPlaybackBackend)?

    private struct Playback {
        let id: UUID
        let owner: UUID
        let side: TranslationSide
    }

    init(defaults: UserDefaults = .standard,
         makeBackend: @escaping @MainActor () -> any SpeechPlaybackBackend = { SystemSpeechPlaybackBackend() }) {
        self.defaults = defaults
        self.makeBackend = makeBackend
        englishAccent = defaults.string(forKey: StorageKey.englishAccent)
            .flatMap(EnglishSpeechAccent.init(rawValue:)) ?? .american
    }

    func isSpeaking(owner: UUID, side: TranslationSide) -> Bool {
        active?.owner == owner && active?.side == side
    }

    func toggle(text: String, language: String?, owner: UUID, side: TranslationSide) {
        if isSpeaking(owner: owner, side: side) {
            stop()
            return
        }
        stop()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty, language.lowercased() != "auto" else {
            fail(.languageUnknown, owner: owner)
            return
        }
        let backend = prepareBackend()
        guard let voice = selectedVoice(for: language, from: backend.availableVoices()) else {
            fail(.voiceUnavailable, owner: owner)
            return
        }
        let playback = Playback(id: UUID(), owner: owner, side: side)
        active = playback
        guard backend.speak(text: text, voiceIdentifier: voice.identifier, requestID: playback.id) else {
            active = nil
            fail(.voiceUnavailable, owner: owner)
            return
        }
    }

    func stop(owner: UUID) {
        if active?.owner == owner { stop() }
        else if failureOwner == owner { clearFailure() }
    }

    func stop() {
        // Invalidate before stopping: cancellation may complete synchronously.
        let hadPlayback = active != nil
        active = nil
        if hadPlayback { backend?.stop() }
        clearFailure()
    }

    func clearFailure() {
        failure = nil
        failureOwner = nil
    }

    private func fail(_ failure: SpeechPlaybackFailure, owner: UUID) {
        self.failure = failure
        failureOwner = owner
    }

    private func prepareBackend() -> any SpeechPlaybackBackend {
        if let backend { return backend }
        let backend = makeBackend()
        backend.onCompletion = { [weak self] id in
            guard self?.active?.id == id else { return }
            self?.active = nil
        }
        self.backend = backend
        return backend
    }

    private func selectedVoice(for identifier: String, from voices: [SpeechPlaybackVoice]) -> SpeechPlaybackVoice? {
        let language = Locale.Language(identifier: Locale.canonicalLanguageIdentifier(from: identifier))
        guard let code = language.languageCode?.identifier else { return nil }
        let requestedIdentifier = code == "en" ? englishAccent.languageIdentifier : identifier
        let requested = Locale.Language(identifier: Locale.canonicalLanguageIdentifier(from: requestedIdentifier))
        let candidates = voices.filter { voice in
            guard !voice.isPersonal, !voice.isNovelty else { return false }
            let candidate = Locale.Language(identifier: voice.language)
            guard candidate.languageCode == requested.languageCode else { return false }
            // English has an explicit accent choice; never substitute another region.
            if code == "en" { return candidate.region == requested.region }
            // A shared base language does not make different writing systems
            // interchangeable, particularly for Simplified/Traditional Chinese.
            return candidate.script == requested.script
        }
        return candidates.sorted { lhs, rhs in
            let leftExact = Locale.Language(identifier: lhs.language).maximalIdentifier == requested.maximalIdentifier
            let rightExact = Locale.Language(identifier: rhs.language).maximalIdentifier == requested.maximalIdentifier
            if leftExact != rightExact { return leftExact }
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            return lhs.identifier < rhs.identifier
        }.first
    }
}

@MainActor
private final class SystemSpeechPlaybackBackend: SpeechPlaybackBackend {
    var onCompletion: (@MainActor @Sendable (UUID) -> Void)?
    private var synthesizer: AVSpeechSynthesizer?
    private var completionDelegate: SpeechCompletionDelegate?
    private var currentRequest: UUID?

    func availableVoices() -> [SpeechPlaybackVoice] {
        AVSpeechSynthesisVoice.speechVoices().map {
            SpeechPlaybackVoice(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue,
                                isPersonal: $0.voiceTraits.contains(.isPersonalVoice),
                                isNovelty: $0.voiceTraits.contains(.isNoveltyVoice))
        }
    }

    func speak(text: String, voiceIdentifier: String, requestID: UUID) -> Bool {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier),
              !voice.voiceTraits.contains(.isPersonalVoice), !voice.voiceTraits.contains(.isNoveltyVoice) else { return false }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // Each playback owns a delegate with an immutable identity. A cancelled
        // synthesizer's late callback cannot complete the next playback.
        let delegate = SpeechCompletionDelegate(requestID: requestID) { [weak self] id in
            guard let self, self.currentRequest == id else { return }
            self.synthesizer?.delegate = nil
            self.synthesizer = nil
            self.completionDelegate = nil
            self.currentRequest = nil
            self.onCompletion?(id)
        }
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = delegate
        self.synthesizer = synthesizer
        completionDelegate = delegate
        currentRequest = requestID
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        currentRequest = nil
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        completionDelegate = nil
    }
}

/// AVFoundation may deliver delegate messages outside the main actor. Only a
/// UUID crosses that boundary; utterances and their text stay in AVFoundation.
private final class SpeechCompletionDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let requestID: UUID
    private let completion: @MainActor @Sendable (UUID) -> Void

    init(requestID: UUID, completion: @escaping @MainActor @Sendable (UUID) -> Void) {
        self.requestID = requestID
        self.completion = completion
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        complete()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete()
    }

    private func complete() {
        let id = requestID
        let completion = completion
        Task { @MainActor in completion(id) }
    }
}

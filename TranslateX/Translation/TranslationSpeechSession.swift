import Foundation
import Observation

/// A workspace owns playback without owning the system synthesizer. Observe only
/// while a user has requested speech; edits never start or restart playback.
@MainActor
final class TranslationSpeechSession {
    let playback: SpeechPlaybackController
    private let model: TranslationModel
    private let owner = UUID()
    private var generation: UInt64 = 0
    private var spokenContent: Content?

    private struct Content: Equatable {
        let original: String
        let translation: String
        let source: String
        let target: String
        let resolvedSource: String?
        let composing: Bool
        let screenshot: UUID?

        @MainActor init(_ model: TranslationModel) {
            original = model.text
            translation = model.translatedText
            source = model.source
            target = model.target
            resolvedSource = model.resolvedSource
            composing = model.isComposing
            screenshot = model.screenshot?.id
        }
    }

    init(model: TranslationModel, playback: SpeechPlaybackController) {
        self.model = model
        self.playback = playback
    }

    func language(on side: TranslationSide) -> String? {
        if side == .target { return model.target }
        if let resolved = model.resolvedSource { return resolved }
        // Manual speech must also work before a translation request. Reuse the
        // local recognizer on a bounded sample, leaving the editable source choice.
        return TranslationModel.detectLanguage(String(model.text.prefix(512)))
    }

    func isSpeaking(_ side: TranslationSide) -> Bool {
        playback.isSpeaking(owner: owner, side: side)
    }

    func toggle(_ side: TranslationSide) {
        guard !model.isComposing else { return }
        let current = Content(model)
        // A click can arrive before the observation task for the preceding edit.
        // Treat that old utterance as obsolete, rather than toggling off the new text.
        if spokenContent != current { playback.stop(owner: owner) }
        generation &+= 1
        spokenContent = current
        observeContent(generation: generation)
        playback.toggle(text: model.text(on: side), language: language(on: side), owner: owner, side: side)
    }

    func stop() {
        generation &+= 1
        spokenContent = nil
        playback.stop(owner: owner)
    }

    private func observeContent(generation expected: UInt64) {
        withObservationTracking {
            _ = Content(model)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                self.stop()
            }
        }
    }
}

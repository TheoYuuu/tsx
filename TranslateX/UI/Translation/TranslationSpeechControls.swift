import SwiftUI

struct TranslationSpeechControls: View {
    let session: TranslationSpeechSession
    let side: TranslationSide
    let text: String
    var compact = false
    var enabled = true
    var metricPrefix = "main"
    @Environment(\.translateXTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    #if TRANSLATEX_VISUAL_QA
    @Environment(\.translationReviewReduceMotion) private var reviewReduceMotion
    #endif

    private var reducesMotion: Bool {
        #if TRANSLATEX_VISUAL_QA
        reviewReduceMotion ?? reduceMotion
        #else
        reduceMotion
        #endif
    }

    private var speaking: Bool { session.isSpeaking(side) }
    private var sideName: String { side == .source ? "source" : "target" }
    private var isEnglish: Bool {
        guard let language = session.language(on: side) else { return false }
        return Locale.Language(identifier: language).languageCode?.identifier == "en"
    }
    private var actionTitle: String {
        if speaking { return side == .source ? "Stop reading original" : "Stop reading translation" }
        return side == .source ? "Read original from the beginning" : "Read translation from the beginning"
    }

    var body: some View {
        HStack(spacing: 4) {
            if isEnglish {
                LanguageMenu(label: L10n.string("English pronunciation"), selection: Binding(
                    get: { session.playback.englishAccent.rawValue },
                    set: { if let accent = EnglishSpeechAccent(rawValue: $0) { session.playback.englishAccent = accent } }
                ), languages: [
                    TranslationLanguage(id: EnglishSpeechAccent.american.rawValue, name: L10n.string("American English")),
                    TranslationLanguage(id: EnglishSpeechAccent.british.rawValue, name: L10n.string("British English"))
                ], prominent: false, enabled: enabled,
                             displayTitle: L10n.string(session.playback.englishAccent == .american ? "American" : "British"),
                             maximumWidth: 104, grouped: true)
                .fixedSize(horizontal: true, vertical: true)
                .translateXTooltip(L10n.string("English pronunciation"))
                .accessibilityLabel(Text(L10n.string("English pronunciation")))
                .accessibilityValue(Text(L10n.string(session.playback.englishAccent == .american ? "American English" : "British English")))
                .accessibilityIdentifier("translation.\(sideName).accent")
                .serviceDesignMetric("\(metricPrefix).\(sideName)Accent")
                .disabled(!enabled)
            }
            Button { session.toggle(side) } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 14))
                    .symbolEffect(.variableColor.iterative, options: .repeating,
                                  isActive: speaking && !reducesMotion && activeState == .key)
                    .foregroundStyle(speaking ? theme.accent : theme.ink)
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                    .background(speaking ? theme.accent.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(TranslateXHoverButtonStyle(radius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(speaking ? theme.accent : theme.divider, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .translateXTooltip(L10n.string(speaking ? "Stop reading. The next click starts from the beginning." : actionTitle))
            .accessibilityLabel(Text(L10n.string(actionTitle)))
            .accessibilityValue(Text(L10n.string(speaking ? "Reading aloud" : "Not reading")))
            .accessibilityIdentifier("translation.\(sideName).speech")
            .serviceDesignMetric("\(metricPrefix).\(sideName)Speech")
            .disabled(!enabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

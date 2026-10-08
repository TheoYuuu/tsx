import SwiftUI

// Only the isolated visual-review target collects rectangles. The shipping view
// uses the same layout and an ordinary accessibility identifier, with no probe.
#if TRANSLATEX_VISUAL_QA
// Override only inside the isolated fixture; never change macOS preferences.
private struct TranslationReviewCaptureModeKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
private struct TranslationReviewReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}
extension EnvironmentValues {
    var translationReviewCaptureMode: String? {
        get { self[TranslationReviewCaptureModeKey.self] }
        set { self[TranslationReviewCaptureModeKey.self] = newValue }
    }
    var translationReviewReduceMotion: Bool? {
        get { self[TranslationReviewReduceMotionKey.self] }
        set { self[TranslationReviewReduceMotionKey.self] = newValue }
    }
}

struct TranslationServiceLayoutFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
#endif

extension View {
    @ViewBuilder
    func serviceDesignMetric(_ id: String) -> some View {
        #if TRANSLATEX_VISUAL_QA
        self.accessibilityIdentifier("service-design.\(id)")
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: TranslationServiceLayoutFrames.self,
                        value: [id: geometry.frame(in: .named("service-design.window"))])
                }
            }
        #else
        self.accessibilityIdentifier("service-design.\(id)")
        #endif
    }
}

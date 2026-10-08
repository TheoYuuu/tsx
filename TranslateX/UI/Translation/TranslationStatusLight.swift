import SwiftUI

/// Timing is shared with the native tests. Finite confirmations never turn into
/// an endless warning or an apparent background request.
enum TranslationStatusLightStyle: Hashable {
    case idle, waiting, recognizing, translating, updated, stopped, failed
    init(phase: TranslationPhase) {
        switch phase {
        case .waiting: self = .waiting
        case .recognizing: self = .recognizing
        case .translating, .preparingLanguages: self = .translating
        case .completed, .unchanged: self = .updated
        case .cancelled: self = .stopped
        case .failed, .noText: self = .failed
        default: self = .idle
        }
    }
    var period: Double {
        switch self {
        case .waiting: 3.2
        case .recognizing: 2.2
        case .translating: 1.65
        case .updated: 0.95
        case .failed: 0.75
        default: 0
        }
    }
    var duration: Double? { self == .updated ? 0.95 : self == .failed ? 1.5 : nil }
    var breathes: Bool { period > 0 }
    func intensity(elapsed: Double, reduced: Bool = false) -> Double {
        guard breathes, !reduced, duration.map({ elapsed < $0 }) ?? true else { return 0 }
        let progress = max(0, elapsed).truncatingRemainder(dividingBy: period) / period
        return (1 - cos(progress * .pi * 2)) / 2
    }
}

struct TranslationStatusLight: View {
    let phase: TranslationPhase
    @Environment(\.translateXTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if TRANSLATEX_VISUAL_QA
    @Environment(\.translationReviewReduceMotion) private var reviewReduceMotion
    private var reduced: Bool { reviewReduceMotion ?? reduceMotion }
    #else
    private var reduced: Bool { reduceMotion }
    #endif
    @State private var visible = false
    @State private var started = Date()
    @State private var finished = false
    private var style: TranslationStatusLightStyle { .init(phase: phase) }
    private var color: Color {
        switch style {
        case .waiting: Color(red: 0.39, green: 0.57, blue: 0.76)
        case .recognizing: Color(red: 0.02, green: 0.65, blue: 0.76)
        case .translating: theme.accent
        case .updated: Color(red: 0.12, green: 0.65, blue: 0.43)
        case .failed: Color(red: 0.87, green: 0.54, blue: 0.08)
        default: theme.muted
        }
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduced || !visible || !style.breathes || finished)) { context in
            let strength = style.intensity(elapsed: context.date.timeIntervalSince(started), reduced: reduced || !visible)
            ZStack {
                if style != .stopped {
                    Circle().fill(color.opacity(0.06 + strength * 0.12)).frame(width: 12, height: 12)
                        .scaleEffect(0.85 + strength * 0.3)
                    Circle().stroke(color.opacity(strength * 0.4), lineWidth: 0.6)
                        .frame(width: 11 + strength * 4, height: 11 + strength * 4)
                    Circle().fill(color).frame(width: 6, height: 6).opacity(0.78 + strength * 0.22)
                        .shadow(color: color.opacity(strength * 0.6), radius: 2 + strength * 2)
                } else { Circle().stroke(color, lineWidth: 1).frame(width: 6, height: 6) }
            }.frame(width: 16, height: 16)
        }
        .task(id: style) {
            started = Date(); finished = false
            guard let duration = style.duration else { return }
            do { try await Task.sleep(for: .seconds(duration)); finished = true } catch { }
        }
        .background(TranslateXWindowVisibility { visible = $0 })
        .onDisappear { visible = false }
        .accessibilityHidden(true)
    }
}

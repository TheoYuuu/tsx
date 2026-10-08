import SwiftUI

/// Apply to clickable controls only. Native text, resize and scroll cursors keep
/// their own semantics; SwiftUI owns cursor lifetime across dismissal/disable.
struct TranslateXControlCursor: ViewModifier {
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content.pointerStyle(enabled && theme.hoverCursor == .pointingHand ? .link : .default)
    }
}

extension View {
    func translateXControlCursor() -> some View { modifier(TranslateXControlCursor()) }
}

/// Shared icon treatment: strong available actions, quiet disabled actions,
/// and a small rounded square that never appears on a disabled control.
struct TranslateXIconButtonStyle: ButtonStyle {
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? theme.ink : theme.disabledInk)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.ink.opacity(enabled && (hovered || configuration.isPressed)
                                           ? (configuration.isPressed ? 0.12 : 0.06) : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered && enabled)
            .translateXControlCursor()
    }
}

/// Lightweight feedback for controls whose label already defines its geometry.
/// It never scales the label, so pointer and keyboard interaction cannot move it.
struct TranslateXHoverButtonStyle: ButtonStyle {
    var radius: CGFloat = 7
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .fill(theme.accent.opacity(enabled && (hovered || configuration.isPressed)
                                               ? (configuration.isPressed ? 0.16 : 0.08) : 0))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered && enabled)
            .translateXControlCursor()
    }
}

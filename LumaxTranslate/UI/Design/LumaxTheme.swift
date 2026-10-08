import AppKit
import SwiftUI

/// Shared by both materials. Content geometry never depends on the surface.
struct LumaxTheme {
    var material: AppMaterial = .light
    var isDark = false
    var reduceTransparency = false
    var increaseContrast = false
    var hoverCursor: HoverCursor = .pointingHand

    var isGlass: Bool { material == .glass && !reduceTransparency }
    var accent: Color { Color(red: 0.09, green: 0.42, blue: 0.91) }
    var ink: Color { isDark ? Color(white: 0.94) : Color(lumaxHex: isGlass ? 0x1a293b : 0x242b37) }
    var disabledInk: Color { Color(white: isDark ? (increaseContrast ? 0.62 : 0.48) : (increaseContrast ? 0.49 : 0.67)) }
    var muted: Color { isDark ? Color(white: 0.73) : Color(lumaxHex: isGlass ? 0x1b2c42 : 0x687383) }
    var faint: Color { isDark ? Color(white: isGlass ? 0.76 : 0.58) : Color(lumaxHex: isGlass ? 0x34465b : 0x9ba4b1) }
    var control: Color { isDark ? Color.white.opacity(0.10) : (isGlass ? Color.white.opacity(0.46) : Color(red: 0.94, green: 0.95, blue: 0.96)) }
    var card: Color { isDark ? Color(white: 0.12).opacity(isGlass ? 0.62 : 1) : (isGlass ? Color(lumaxHex: 0xfbfdff).opacity(0.72) : .white) }
    var workspace: Color { isDark ? card : (isGlass ? Color(lumaxHex: 0xfafdff).opacity(0.76) : .white) }
    var secondaryCard: Color { isDark ? Color.white.opacity(0.025) : Color(lumaxHex: isGlass ? 0xf7fbff : 0xf9fafd).opacity(isGlass ? 0.25 : 1) }
    var divider: Color { (isDark ? Color.white : Color(red: 0.35, green: 0.42, blue: 0.53)).opacity(increaseContrast ? 0.45 : 0.14) }
    var edge: Color { isGlass ? Color.white.opacity(isDark ? 0.25 : 0.8) : divider }
    var radius: CGFloat { isGlass ? 24 : 19 }
    var buttonRadius: CGFloat { isGlass ? 18 : 9 }
}

private extension Color {
    init(lumaxHex: UInt32) {
        self.init(red: Double((lumaxHex >> 16) & 255) / 255,
                  green: Double((lumaxHex >> 8) & 255) / 255,
                  blue: Double(lumaxHex & 255) / 255)
    }
}

private struct LumaxThemeKey: EnvironmentKey {
    static let defaultValue = LumaxTheme()
}

extension EnvironmentValues {
    var lumaxTheme: LumaxTheme {
        get { self[LumaxThemeKey.self] }
        set { self[LumaxThemeKey.self] = newValue }
    }
}

struct LumaxThemeHost<Content: View>: View {
    let preferences: AppPreferences
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let theme = LumaxTheme(material: preferences.material, isDark: colorScheme == .dark,
                               reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased,
                               hoverCursor: preferences.hoverCursor)
        content()
            .environment(\.locale, L10n.currentLocale)
            .environment(\.lumaxTheme, theme)
            .environment(\.translationLayout, preferences.translationLayout)
            .tint(theme.accent)
            .foregroundStyle(theme.ink)
            .ignoresSafeArea(.container, edges: .top)
    }
}

struct LumaxButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    @Environment(\.lumaxTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13)
            .frame(minHeight: 32)
            .foregroundStyle(kind == .primary ? Color.white : (kind == .quiet ? theme.muted : theme.ink))
            .background {
                RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
                    .fill(kind == .primary ? theme.accent : (kind == .quiet ? .clear : theme.control))
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.buttonRadius)
                    .fill(theme.ink.opacity(enabled && hovered ? 0.06 : 0))
                    .allowsHitTesting(false)
                if theme.isGlass && kind == .secondary {
                    RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
                        .strokeBorder(theme.edge, lineWidth: 0.75)
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
            .contentShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
            .onHover { hovered = $0 }
            .lumaxControlCursor()
    }
}

struct LumaxIconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 32
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(LumaxIconButtonStyle())
        .lumaxTooltip(L10n.string(label))
        .accessibilityLabel(Text(L10n.string(label)))
    }
}

struct LumaxBrandMark: View {
    var size: CGFloat = 25
    var body: some View {
        Image("AppBrand")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            // The app-icon canvas includes transparent margins around the tile.
            // Keep its visible footprint while preserving the existing layout size.
            .frame(width: size / 0.78, height: size / 0.78)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct LumaxLocalStatus: View {
    @Environment(\.lumaxTheme) private var theme
    var body: some View {
        Label("On-device translation", systemImage: "lock.shield")
            .font(.system(size: 11)).foregroundStyle(theme.muted)
    }
}

/// Real AppKit controls in our full-size title area, with the window's original actions.
struct WindowTrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeTrafficLights { NativeTrafficLights() }
    func updateNSView(_ nsView: NativeTrafficLights, context: Context) { nsView.refreshEnabledState() }
}

@MainActor
final class NativeTrafficLights: NSView {
    private var buttons: [NSButton] = []
    override var intrinsicContentSize: NSSize { NSSize(width: 58, height: 14) }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 58, height: 14))
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
            button.target = self
            button.action = [#selector(closeWindow), #selector(minimizeWindow), #selector(zoomWindow)][index]
            button.frame = NSRect(x: CGFloat(index) * 22, y: 0, width: 14, height: 14)
            addSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshEnabledState() }
    func refreshEnabledState() {
        guard buttons.count == 3, let window else { return }
        buttons[0].isEnabled = window.styleMask.contains(.closable)
        buttons[1].isEnabled = window.styleMask.contains(.miniaturizable)
        buttons[2].isEnabled = window.styleMask.contains(.resizable)
    }
    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func minimizeWindow() { window?.miniaturize(nil) }
    @objc private func zoomWindow() {
        if NSEvent.modifierFlags.contains(.option) { window?.performZoom(nil) }
        else { window?.toggleFullScreen(nil) }
    }
}

/// Shared vector geometry from the approved 24 pt icon board. Templates inherit
/// their surrounding text color in SwiftUI and AppKit menus.
enum LumaxActionSymbol: Sendable {
    case selection, input

    var outline: Path {
        var path = Path()
        func line(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        switch self {
        case .selection:
            line([CGPoint(x: 5, y: 6.5), CGPoint(x: 14, y: 6.5)])
            line([CGPoint(x: 5, y: 10.5), CGPoint(x: 11.5, y: 10.5)])
            line([CGPoint(x: 3.5, y: 18), CGPoint(x: 8.5, y: 18)])
            line([CGPoint(x: 13, y: 11), CGPoint(x: 21, y: 16.5),
                  CGPoint(x: 16.7, y: 17.5), CGPoint(x: 15.1, y: 21.5)])
            path.closeSubpath()
        case .input:
            path.addRoundedRect(in: CGRect(x: 3, y: 3.5, width: 18, height: 17), cornerSize: CGSize(width: 3, height: 3))
            line([CGPoint(x: 3, y: 8), CGPoint(x: 21, y: 8)])
            line([CGPoint(x: 8.5, y: 11.5), CGPoint(x: 12.5, y: 11.5)])
            line([CGPoint(x: 10.5, y: 11.5), CGPoint(x: 10.5, y: 17.5)])
            line([CGPoint(x: 8.5, y: 17.5), CGPoint(x: 12.5, y: 17.5)])
            line([CGPoint(x: 16, y: 17.5), CGPoint(x: 17.5, y: 17.5)])
        }
        return path
    }

    var highlight: Path {
        self == .selection
            ? Path(roundedRect: CGRect(x: 2.5, y: 3, width: 15, height: 11.5), cornerRadius: 2)
            : Path()
    }

    @MainActor func menuImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 24, y: rect.height / 24)
            context.setFillColor(NSColor.black.withAlphaComponent(0.1).cgColor)
            context.addPath(highlight.cgPath)
            context.fillPath()
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.65)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(outline.cgPath)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct LumaxActionIcon: View {
    let symbol: LumaxActionSymbol
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 24
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            symbol.highlight.applying(transform).fill(.primary.opacity(0.1))
            symbol.outline.applying(transform)
                .stroke(style: StrokeStyle(lineWidth: 1.65 * scale, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

import AppKit
import SwiftUI

/// Screenshot controls deliberately have their own appearance. Main-window
/// command buttons and the automatic-translation animation remain unchanged.
struct ScreenshotIconButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var selected = false
    @Environment(\.translateXTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? tint ?? theme.ink : theme.disabledInk)
            .background(theme.ink.opacity(enabled ? (configuration.isPressed ? 0.12 : hovered || selected ? 0.06 : 0) : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
            .translateXControlCursor()
    }
}

@MainActor
struct ScreenshotMenuItem {
    var title: String
    var symbol: String? = nil
    var enabled = true
    var action: () -> Void = {}
    static var separator: Self { Self(title: "") }
}

/// AppKit retains menu-row icons and gives icon-only menus a predictable tint,
/// hover surface and keyboard behavior in both system appearances.
struct ScreenshotActionMenu: NSViewRepresentable {
    let title: String
    var savesImage = false
    let items: [ScreenshotMenuItem]
    @Environment(\.translateXTheme) private var theme

    func makeNSView(context: Context) -> ScreenshotActionMenuControl { ScreenshotActionMenuControl() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScreenshotActionMenuControl, context: Context) -> CGSize? {
        CGSize(width: 30, height: 30)
    }
    func updateNSView(_ control: ScreenshotActionMenuControl, context: Context) {
        control.savesImage = savesImage
        control.ink = NSColor(theme.ink)
        control.hoverFill = NSColor(theme.ink.opacity(0.06))
        control.hoverCursor = theme.hoverCursor
        control.isEnabled = context.environment.isEnabled
        control.setAccessibilityLabel(L10n.string(title))
        control.toolTip = L10n.string(title)
        control.configure(items)
    }
}

@MainActor
final class ScreenshotActionMenuControl: NSPopUpButton, NSMenuDelegate {
    var savesImage = false
    var ink = NSColor.labelColor
    var hoverFill = NSColor.labelColor.withAlphaComponent(0.06)
    var hoverCursor: HoverCursor = .pointingHand {
        didSet { if hoverCursor != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var items: [ScreenshotMenuItem] = []
    private var hovered = false
    private var menuOpen = false
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 30) }

    init() {
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        preferredEdge = isFlipped ? .maxY : .minY
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        setAccessibilityRole(.menuButton)
    }
    required init?(coder: NSCoder) { nil }
    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: hoverCursor == .pointingHand ? .pointingHand : .arrow) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || menuOpen) {
            hoverFill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let image = savesImage ? ScreenshotActionIcon.Symbol.save.menuImage : NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let size = ScreenshotDocument.fittedSize(image: image.size, available: CGSize(width: 17, height: 17))
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        context.saveGState(); context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        ink.withAlphaComponent(isEnabled ? 1 : 0.4).setFill(); rect.fill(using: .sourceAtop)
        context.endTransparencyLayer(); context.restoreGState()
    }
    func configure(_ entries: [ScreenshotMenuItem]) {
        items = entries
        guard !menuOpen else { return }
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        let display = NSMenuItem(title: "", action: nil, keyEquivalent: ""); display.isHidden = true
        menu.addItem(display)
        for (index, entry) in entries.enumerated() {
            if entry.title.isEmpty { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: L10n.string(entry.title), action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = index; item.isEnabled = entry.enabled
            item.image = entry.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            if savesImage { item.image = ScreenshotActionIcon.Symbol.save.menuImage }
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        self.menu = menu; needsDisplay = true
    }
    @objc private func choose(_ item: NSMenuItem) {
        guard isEnabled, let index = item.representedObject as? Int, items.indices.contains(index), items[index].enabled else { return }
        items[index].action()
    }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; needsDisplay = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; configure(items) }
    func confinementRect(for menu: NSMenu, on screen: NSScreen?) -> NSRect {
        guard let window, let screen = screen ?? window.screen else { return .zero }
        return LanguageMenuControl.menuConfinementRect(anchor: window.convertToScreen(convert(bounds, to: nil)), visibleFrame: screen.visibleFrame)
    }
}

struct ScreenshotServicePicker: View {
    let model: TranslationModel
    var openSettings: () -> Void = {}
    @Environment(\.translateXTheme) private var theme
    @State private var hovered = false

    var body: some View {
        NativeTranslationServicePicker(model: model, maximumWidth: 142, openSettings: openSettings)
            .padding(1)
            .background(theme.ink.opacity(hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.divider, lineWidth: theme.increaseContrast ? 1 : 0.5).allowsHitTesting(false) }
            .onHover { hovered = $0 }
            .translateXTooltip(model.serviceDisplayName)
    }
}

/// Angular repeat arrows and a save disk keep these actions distinct from
/// refreshing a web page and downloading a remote file.
struct ScreenshotActionIcon: Shape {
    enum Symbol: Sendable { case retranslate, save }
    let symbol: Symbol
    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch symbol {
        case .retranslate:
            path.move(to: CGPoint(x: 4, y: 10)); path.addLine(to: CGPoint(x: 4, y: 7)); path.addLine(to: CGPoint(x: 19, y: 7))
            path.move(to: CGPoint(x: 16, y: 4)); path.addLine(to: CGPoint(x: 19, y: 7)); path.addLine(to: CGPoint(x: 16, y: 10))
            path.move(to: CGPoint(x: 20, y: 14)); path.addLine(to: CGPoint(x: 20, y: 17)); path.addLine(to: CGPoint(x: 5, y: 17))
            path.move(to: CGPoint(x: 8, y: 14)); path.addLine(to: CGPoint(x: 5, y: 17)); path.addLine(to: CGPoint(x: 8, y: 20))
        case .save:
            path.move(to: CGPoint(x: 4, y: 3)); path.addLine(to: CGPoint(x: 17, y: 3)); path.addLine(to: CGPoint(x: 21, y: 7))
            path.addLine(to: CGPoint(x: 21, y: 21)); path.addLine(to: CGPoint(x: 3, y: 21)); path.addLine(to: CGPoint(x: 3, y: 4)); path.closeSubpath()
            path.addRect(CGRect(x: 7, y: 3, width: 9, height: 6))
            path.addRect(CGRect(x: 7, y: 14, width: 10, height: 7))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

extension ScreenshotActionIcon.Symbol {
    /// Native macOS Menu extracts Image labels. Supply a template image rather
    /// than a Shape so the save disk remains visible in a menu button.
    var menuImage: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.35)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.addPath(ScreenshotActionIcon(symbol: self).path(in: rect.insetBy(dx: 0.5, dy: 0.5)).cgPath)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct ScreenshotSymbol: View {
    let symbol: ScreenshotActionIcon.Symbol
    var body: some View {
        ScreenshotActionIcon(symbol: symbol).stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            .frame(width: 17, height: 17).accessibilityHidden(true)
    }
}

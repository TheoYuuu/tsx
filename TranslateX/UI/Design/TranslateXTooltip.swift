import AppKit
import SwiftUI

/// Immediate, non-activating hints. The anchor never intercepts text or button
/// events; a hint is dismissed before a click, scroll, menu, or window change.
struct TranslateXTooltip: ViewModifier {
    let text: String
    @Environment(\.translateXTheme) private var theme
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .background(TooltipAnchor(text: text, dark: theme.isDark, presented: focused))
            .accessibilityHint(Text(text))
    }
}

extension View {
    func translateXTooltip(_ text: String) -> some View { modifier(TranslateXTooltip(text: text)) }
}

private struct TooltipAnchor: NSViewRepresentable {
    let text: String
    let dark: Bool
    let presented: Bool
    func makeNSView(context: Context) -> TooltipAnchorView { TooltipAnchorView() }
    func updateNSView(_ view: TooltipAnchorView, context: Context) {
        view.update(text: text, dark: dark, presented: presented)
    }
    static func dismantleNSView(_ view: TooltipAnchorView, coordinator: ()) { view.dismiss() }
}

@MainActor
final class TooltipAnchorView: NSView {
    private var panel: NSPanel?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var requested = false
    private var pointerInside = false
    private var keyboardFocused = false
    private var hoverArea: NSTrackingArea?
    private var text = ""
    private var dark = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String, dark: Bool, presented: Bool) {
        let changed = self.text != text || self.dark != dark
        self.text = text; self.dark = dark
        keyboardFocused = presented
        refreshPresentation(changed: changed)
    }

    // SwiftUI suppresses onHover on disabled controls. Native tracking remains
    // active on the inert anchor without enabling or intercepting the button.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self)
        addTrackingArea(area); hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        refreshPresentation()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        refreshPresentation()
    }

    private func refreshPresentation(changed: Bool = false) {
        if !pointerInside && !keyboardFocused { requested = false; dismiss(); return }
        if !requested || changed { requested = true; dismiss(); show() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { pointerInside = false; requested = false; dismiss() } else if requested { show() }
    }

    private func show() {
        guard panel == nil, requested, !text.isEmpty, let window, window.isVisible,
              let screen = window.screen else { return }
        let font = NSFont.systemFont(ofSize: 11)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2
        let foreground = dark ? NSColor(calibratedWhite: 0.14, alpha: 1) : .white
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph])
        let label = NSTextField(labelWithAttributedString: attributed)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        // Measure the actual cell, including its text inset and line metrics.
        // Measuring only glyphs clips the last character and multiline descenders.
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 294, height: CGFloat.greatestFiniteMagnitude)) ?? .zero
        let labelWidth = ceil(measured.width)
        let fitted = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: labelWidth, height: CGFloat.greatestFiniteMagnitude)) ?? measured
        let size = NSSize(width: labelWidth + 20, height: ceil(fitted.height) + 14)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let frame = Self.placement(anchor: anchor, size: size, visibleFrame: screen.visibleFrame)
        let hint = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hint.isReleasedWhenClosed = false; hint.isOpaque = false; hint.backgroundColor = .clear
        hint.hasShadow = true; hint.ignoresMouseEvents = true; hint.hidesOnDeactivate = true
        hint.collectionBehavior = [.transient, .fullScreenAuxiliary]
        label.frame = NSRect(x: 10, y: 7, width: size.width - 20, height: size.height - 14)
        let body = NSView(frame: NSRect(origin: .zero, size: size))
        body.wantsLayer = true; body.layer?.cornerRadius = 7
        body.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.95, alpha: 1) : NSColor(calibratedWhite: 0.15, alpha: 1)).cgColor
        body.addSubview(label); hint.contentView = body
        panel = hint
        window.addChildWindow(hint, ordered: .above)
        hint.orderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            let dismissesEscape = MainActor.assumeIsolated {
                let wasVisible = self?.panel != nil
                self?.dismiss()
                return wasVisible && event.type == .keyDown && event.keyCode == 53
            }
            return dismissesEscape ? nil : event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    static func placement(anchor: NSRect, size: NSSize, visibleFrame: NSRect) -> NSRect {
        let x = min(max(anchor.midX - size.width / 2, visibleFrame.minX + 6), visibleFrame.maxX - size.width - 6)
        let below = anchor.minY - 8 - size.height
        let y = below >= visibleFrame.minY + 6 ? below : min(anchor.maxY + 8, visibleFrame.maxY - size.height - 6)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); self.panel = nil }
    }
}

/// AppKit owns window visibility; a hidden/minimized retained SwiftUI view must
/// not keep a TimelineView running merely because it has not disappeared.
struct TranslateXWindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> WindowVisibilityProbe {
        let view = WindowVisibilityProbe(); view.changed = changed
        return view
    }
    func updateNSView(_ view: WindowVisibilityProbe, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: WindowVisibilityProbe, coordinator: ()) { view.stop() }
}

@MainActor
final class WindowVisibilityProbe: NSView {
    var changed: ((Bool) -> Void)?
    private var lastVisible: Bool?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility), name: name, object: window)
            }
        }
        updateVisibility()
    }
    @objc private func updateVisibility() {
        let visible = window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
        guard visible != lastVisible else { return }
        lastVisible = visible
        DispatchQueue.main.async { [weak self] in self?.changed?(visible) }
    }
    func stop() { NotificationCenter.default.removeObserver(self); changed = nil }
}

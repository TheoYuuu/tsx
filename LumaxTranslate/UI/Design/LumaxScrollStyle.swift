import AppKit
import SwiftUI

/// Native overlay scrolling with a shared narrow thumb and no opaque track.
/// AppKit retains scrolling, dragging, accessibility and its automatic fade.
@MainActor
enum LumaxScrollStyle {
    static func apply(to scrollView: NSScrollView) {
        if scrollView.hasVerticalScroller, !(scrollView.verticalScroller is LumaxScroller) {
            scrollView.verticalScroller = LumaxScroller(frame: .zero)
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is LumaxScroller) {
            scrollView.horizontalScroller = LumaxScroller(frame: .zero)
        }
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .small
        scrollView.horizontalScroller?.controlSize = .small
    }
}

@MainActor
final class LumaxScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func drawKnob() {
        var knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }
        let width: CGFloat = hovered || hitPart == .knob ? 7 : 5
        if bounds.height > bounds.width {
            knob.origin.x = knob.midX - width / 2
            knob.size.width = width
        } else {
            knob.origin.y = knob.midY - width / 2
            knob.size.height = width
        }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.labelColor.withAlphaComponent(contrast ? 0.8 : hovered ? 0.5 : 0.32).setFill()
        NSBezierPath(roundedRect: knob, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

/// Place in the content of a SwiftUI ScrollView, never above its container.
struct LumaxScrollAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.configure() }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }
        override func layout() { super.layout(); configure() }
        func configure() {
            if let scrollView = enclosingScrollView { LumaxScrollStyle.apply(to: scrollView) }
        }
    }
}

extension View {
    func lumaxScrollContent() -> some View {
        background(LumaxScrollAnchor().frame(width: 0, height: 0))
    }
}

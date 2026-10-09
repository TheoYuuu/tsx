import AppKit
import SwiftUI

/// Native overlay scrolling with a shared narrow thumb and no opaque track.
/// AppKit retains scrolling, dragging, accessibility and its automatic fade.
@MainActor
enum TranslateXScrollStyle {
    static func apply(to scrollView: NSScrollView) {
        if scrollView.hasVerticalScroller, !(scrollView.verticalScroller is TranslateXScroller) {
            scrollView.verticalScroller = TranslateXScroller(frame: .zero)
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is TranslateXScroller) {
            scrollView.horizontalScroller = TranslateXScroller(frame: .zero)
        }
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .small
        scrollView.horizontalScroller?.controlSize = .small
    }
}

@MainActor
final class TranslateXScroller: NSScroller {
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
struct TranslateXScrollAnchor: NSViewRepresentable {
    var overlayVerticalIndicator = false
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.overlayVerticalIndicator = overlayVerticalIndicator
        view.configure()
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.stopObserving() }

    final class AnchorView: NSView {
        private weak var styledScrollView: NSScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var configurationScheduled = false
        var overlayVerticalIndicator = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }
        override func layout() { super.layout(); configure() }
        func configure() {
            guard window != nil, let scrollView = enclosingScrollView else { stopObserving(); return }
            if styledScrollView !== scrollView {
                stopObserving()
                styledScrollView = scrollView
                // SwiftUI can restore the system's legacy style after mounting
                // or updating its ScrollView. Keep ownership beyond that first
                // layout; otherwise a popup's next update appears to fix the gutter.
                observations = [
                    scrollView.observe(\.scrollerStyle) { [weak self] _, _ in self?.scheduleConfiguration() },
                    scrollView.observe(\.verticalScroller) { [weak self] _, _ in self?.scheduleConfiguration() },
                    scrollView.observe(\.horizontalScroller) { [weak self] _, _ in self?.scheduleConfiguration() },
                    scrollView.observe(\.hasVerticalScroller) { [weak self] _, _ in self?.scheduleConfiguration() }
                ]
            }
            if overlayVerticalIndicator, !scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = true }
            TranslateXScrollStyle.apply(to: scrollView)
        }

        nonisolated private func scheduleConfiguration() {
            // Native view mutations run on the main thread. Reconcile after the
            // setter finishes instead of reentering AppKit's tiling operation.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.configurationScheduled else { return }
                self.configurationScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.configurationScheduled = false
                    self.configure()
                }
            }
        }

        func stopObserving() {
            observations.removeAll()
            styledScrollView = nil
        }
    }
}

extension View {
    func translateXScrollContent(overlayVerticalIndicator: Bool = false) -> some View {
        background(TranslateXScrollAnchor(overlayVerticalIndicator: overlayVerticalIndicator).frame(width: 0, height: 0))
    }
}

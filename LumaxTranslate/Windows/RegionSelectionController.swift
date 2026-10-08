import AppKit
import SwiftUI

/// One screenshot owns this guard from before selection until its result is accepted.
/// A layout change invalidates the intent permanently, even if the screens later revert.
@MainActor
final class CaptureLayoutGuard: NSObject {
    private let original: CaptureLayoutSnapshot
    private let notificationCenter: NotificationCenter
    private let currentLayout: @MainActor () throws -> CaptureLayoutSnapshot
    private var invalidated = false
    private var stopped = false

    static func begin() throws -> CaptureLayoutGuard {
        try CaptureLayoutGuard(notificationCenter: .default, currentLayout: readCurrentLayout)
    }

    init(notificationCenter: NotificationCenter, currentLayout: @escaping @MainActor () throws -> CaptureLayoutSnapshot) throws {
        self.notificationCenter = notificationCenter
        self.currentLayout = currentLayout
        original = try currentLayout()
        super.init()
        notificationCenter.addObserver(self, selector: #selector(layoutChanged),
                                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func validate(referenceTop: CGFloat? = nil) throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard !invalidated else { throw CaptureError.screenConfigurationChanged }
        do {
            guard try currentLayout() == original,
                  referenceTop == nil || referenceTop == original.referenceTop else {
                throw CaptureError.screenConfigurationChanged
            }
        } catch {
            invalidated = true
            throw CaptureError.screenConfigurationChanged
        }
    }

    func validatedDisplays(_ displays: [CaptureDisplay]) throws -> [CaptureDisplay] {
        try validate()
        do { return try original.matchingDisplays(in: displays) }
        catch {
            invalidated = true
            throw CaptureError.screenConfigurationChanged
        }
    }

    func stop() {
        stopped = true
        notificationCenter.removeObserver(self)
    }

    @objc private func layoutChanged() { invalidated = true }

    private static func readCurrentLayout() throws -> CaptureLayoutSnapshot {
        let screens = NSScreen.screens
        guard let primary = screens.first,
              let primaryID = primary.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.noDisplays
        }
        let referenceTop = primary.frame.maxY
        let displays = try screens.map { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                throw CaptureError.screenConfigurationChanged
            }
            return CaptureDisplay(id: id.uint32Value,
                                  frame: try CaptureGeometry.quartzRect(fromAppKit: screen.frame, referenceTop: referenceTop),
                                  scale: screen.backingScaleFactor)
        }
        return CaptureLayoutSnapshot(primaryDisplayID: primaryID.uint32Value, referenceTop: referenceTop, displays: displays)
    }

    isolated deinit { notificationCenter.removeObserver(self) }
}

@MainActor
final class RegionSelectionController: NSObject {
    private let preferences: AppPreferences
    private var continuation: CheckedContinuation<SelectedRegion, any Error>?
    private var sessionID: UUID?
    private var panels: [RegionSelectionPanel] = []
    private var geometry: RegionSelectionGeometry?
    private var referenceTop: CGFloat = 0
    private var hasPushedCursor = false

    var isSelecting: Bool { continuation != nil }

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        super.init()
    }

    func selectRegion() async throws -> SelectedRegion {
        try Task.checkCancellation()
        guard !isSelecting else { throw RegionSelectionError.busy }
        let screens = NSScreen.screens
        guard let primary = screens.first else { throw RegionSelectionError.noScreens }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                sessionID = id
                referenceTop = primary.frame.maxY
                geometry = RegionSelectionGeometry(screenFrames: screens.map(\.frame))
                presentOverlays(on: screens)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                // A delayed cancellation for an old task must not cancel a later selection.
                guard self?.sessionID == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func presentOverlays(on screens: [NSScreen]) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        for screen in screens {
            let panel = RegionSelectionPanel(
                contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.animationBehavior = .none
            panel.acceptsMouseMovedEvents = true
            let view = RegionSelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), screenFrame: screen.frame,
                                                  preferences: preferences)
            view.onBegin = { [weak self] point in
                self?.geometry?.begin(at: point)
                self?.refreshOverlays()
            }
            view.onDrag = { [weak self] point in
                self?.geometry?.update(to: point)
                self?.refreshOverlays()
            }
            view.onEnd = { [weak self] point in self?.completeDrag(at: point) }
            view.onCancel = { [weak self] in self?.cancel() }
            panel.contentView = view
            panel.initialFirstResponder = view
            panel.makeFirstResponder(view)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        let pointer = NSEvent.mouseLocation
        let activePanel = panels.first { $0.frame.contains(pointer) } ?? panels.first
        activePanel?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
        hasPushedCursor = true
    }

    private func refreshOverlays() {
        for panel in panels {
            (panel.contentView as? RegionSelectionOverlayView)?.selection = geometry?.selection
        }
    }

    private func completeDrag(at point: CGPoint) {
        guard let bounds = geometry?.finish(at: point) else {
            refreshOverlays()
            return
        }
        let identifiers = panels.compactMap { panel -> CGWindowID? in
            panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
        }
        finish(.success(SelectedRegion(bounds: bounds, referenceTop: referenceTop, excludingWindowIDs: identifiers)))
    }

    @objc private func screenConfigurationChanged() {
        finish(.failure(RegionSelectionError.screenConfigurationChanged))
    }

    private func finish(_ result: Result<SelectedRegion, any Error>) {
        guard let pending = continuation else { return }
        continuation = nil
        sessionID = nil
        geometry = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        if hasPushedCursor {
            NSCursor.pop()
            hasPushedCursor = false
        }
        // Return only after our windows are hidden and closed. IDs additionally let
        // the capture service exclude an overlay still pending compositor cleanup.
        pending.resume(with: result)
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        if hasPushedCursor { NSCursor.pop() }
        continuation?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RegionSelectionOverlayView: NSView {
    var onBegin: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    var selection: CGRect? { didSet { needsDisplay = true } }
    private let screenFrame: CGRect
    private let hint: WindowSurface<CaptureHintView>

    init(frame: NSRect, screenFrame: CGRect, preferences: AppPreferences = AppPreferences()) {
        self.screenFrame = screenFrame
        hint = WindowSurface(preferences: preferences, content: CaptureHintView())
        super.init(frame: frame)
        addSubview(hint)
        positionHint()
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Drag to select an area · Esc to cancel"))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Hints are informative, never a hole in the drag-selection surface.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    override func layout() { super.layout(); positionHint() }

    private func positionHint() {
        let width = min(480, max(200, bounds.width - 32))
        hint.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.height - 119, width: width, height: 44)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseDown(with event: NSEvent) {
        guard let point = globalPoint(for: event) else { return }
        window?.makeFirstResponder(self)
        onBegin?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = globalPoint(for: event) else { return }
        onDrag?(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let point = globalPoint(for: event) else { return }
        onEnd?(point)
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }

    private func globalPoint(for event: NSEvent) -> CGPoint? {
        // AppKit keeps delivering the original drag stream beyond this window's
        // bounds. Converting its event coordinates preserves cross-display drags.
        window?.convertPoint(toScreen: event.locationInWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let outside = NSBezierPath(rect: bounds)
        var localSelection: CGRect?
        if let selection, !selection.isEmpty {
            let rect = selection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            localSelection = rect
            outside.appendRect(rect)
            outside.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.28).setFill()
        outside.fill()
        if let localSelection {
            let outline = NSBezierPath(rect: localSelection)
            NSColor.black.withAlphaComponent(0.65).setStroke()
            outline.lineWidth = 3
            outline.stroke()
            NSColor.white.setStroke()
            outline.lineWidth = 1
            outline.stroke()
            let corners = NSBezierPath()
            for (x, dx) in [(localSelection.minX, CGFloat(1)), (localSelection.maxX, CGFloat(-1))] {
                for (y, dy) in [(localSelection.minY, CGFloat(1)), (localSelection.maxY, CGFloat(-1))] {
                    corners.move(to: CGPoint(x: x, y: y + dy * 12))
                    corners.line(to: CGPoint(x: x, y: y))
                    corners.line(to: CGPoint(x: x + dx * 12, y: y))
                }
            }
            corners.lineWidth = 3
            corners.stroke()
            if let selection, localSelection.intersects(bounds) {
                let size = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
                drawLabel(size, near: CGPoint(x: localSelection.midX, y: localSelection.minY - 40), centered: true, monospaced: true)
            }
        }
    }

    private func drawLabel(_ text: String, near point: CGPoint, centered: Bool = false, monospaced: Bool = false) {
        let font: NSFont = monospaced ? .monospacedDigitSystemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = CGSize(width: textSize.width + 20, height: textSize.height + 12)
        let x = min(max(centered ? point.x - size.width / 2 : point.x, 12), max(12, bounds.maxX - size.width - 12))
        let y = min(max(point.y, 12), max(12, bounds.maxY - size.height - 12))
        let box = CGRect(origin: CGPoint(x: x, y: y), size: size)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 10, y: box.minY + 6), withAttributes: attributes)
    }
}

private struct CaptureHintView: View {
    @Environment(\.lumaxTheme) private var theme
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder").font(.system(size: 17))
            Text("Drag to select an area").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            Text("esc").font(.system(size: 11)).foregroundStyle(theme.muted)
            Text("Cancel").font(.system(size: 12)).foregroundStyle(theme.muted)
        }.padding(.horizontal, 18).frame(maxHeight: .infinity)
    }
}

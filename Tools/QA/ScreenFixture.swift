import AppKit

/// A synthetic, display-only sample for crop/OCR QA. The floating level keeps the
/// sample stable; this fixture is not evidence of source-app focus compatibility.
@main
struct ScreenFixture {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let canvas = FixtureCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    private var fixtureWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Screen Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu

        let window = NSWindow(
            contentRect: canvas.bounds,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.delegate = self
        window.contentView = canvas
        fixtureWindow = window
        canvas.previousButton.target = self
        canvas.previousButton.action = #selector(previousScreen)
        canvas.nextButton.target = self
        canvas.nextButton.action = #selector(nextScreen)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        window.center()
        showFixture()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showFixture()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        fixtureWindow?.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) { updateGeometry() }
    func windowDidChangeScreen(_ notification: Notification) { updateGeometry() }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateGeometry() }

    @objc private func screenParametersChanged(_ notification: Notification) { updateGeometry() }
    @objc private func previousScreen(_ sender: NSButton) { moveToScreen(offset: -1) }
    @objc private func nextScreen(_ sender: NSButton) { moveToScreen(offset: 1) }

    private func showFixture() {
        guard let window = fixtureWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateGeometry()
    }

    private func moveToScreen(offset: Int) {
        guard let window = fixtureWindow else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let current = screens.firstIndex { $0 === window.screen } ?? 0
        let screen = screens[(current + offset + screens.count) % screens.count]
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: visible.midX - window.frame.width / 2,
            y: visible.midY - window.frame.height / 2
        ))
        updateGeometry()
    }

    private func updateGeometry() {
        guard let window = fixtureWindow, let screen = window.screen else { return }
        let target = window.convertToScreen(canvas.convert(FixtureCanvas.targetRect, to: nil))
        let scale = String(format: "%.1f", screen.backingScaleFactor)
        window.title = "TranslateX Screen Fixture — \(screen.localizedName) — \(scale)×"
        canvas.screenLabel.stringValue = "Display: \(screen.localizedName)  |  Scale: \(scale)×  |  Frame: \(format(screen.frame))"
        canvas.geometryLabel.stringValue = "Target AppKit global (bottom-left origin): \(format(target))"
        let multipleScreens = NSScreen.screens.count > 1
        canvas.previousButton.isEnabled = multipleScreens
        canvas.nextButton.isEnabled = multipleScreens
    }

    private func format(_ rect: NSRect) -> String {
        String(format: "x %.1f, y %.1f, w %.1f, h %.1f pt", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}

@MainActor
private final class FixtureCanvas: NSView {
    static let targetRect = NSRect(x: 100, y: 260, width: 600, height: 100)
    let screenLabel = NSTextField(labelWithString: "")
    let geometryLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton(title: "Previous display", target: nil, action: nil)
    let nextButton = NSButton(title: "Next display", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addLabel("SYNTHETIC SCREEN / CROP FIXTURE", frame: NSRect(x: 32, y: 444, width: 736, height: 28), size: 20)
        addLabel("Select the 600 × 100 pt box. Only the sentence belongs inside it.", frame: NSRect(x: 32, y: 408, width: 736, height: 24), size: 15)
        addLabel("EXCLUDE THIS LINE: outside the target box.", frame: NSRect(x: 100, y: 200, width: 640, height: 30), size: 22)
        addLabel("Fixed floating sample; not a source-focus compatibility test.", frame: NSRect(x: 32, y: 154, width: 736, height: 22), size: 13)

        previousButton.frame = NSRect(x: 32, y: 102, width: 160, height: 32)
        nextButton.frame = NSRect(x: 204, y: 102, width: 160, height: 32)
        for button in [previousButton, nextButton] {
            button.bezelStyle = .rounded
            addSubview(button)
        }
        screenLabel.frame = NSRect(x: 32, y: 65, width: 736, height: 25)
        geometryLabel.frame = NSRect(x: 32, y: 29, width: 736, height: 25)
        for label in [screenLabel, geometryLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .black
            label.isSelectable = true
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor.black.setStroke()
        let target = Self.targetRect
        // The outline lies outside the exact crop rectangle; no markers or
        // labels enter the crop and become accidental OCR input.
        NSBezierPath(rect: target.insetBy(dx: -2, dy: -2)).stroke()
        for point in [NSPoint(x: target.minX - 8, y: target.minY - 8),
                      NSPoint(x: target.maxX + 8, y: target.minY - 8),
                      NSPoint(x: target.minX - 8, y: target.maxY + 8),
                      NSPoint(x: target.maxX + 8, y: target.maxY + 8)] {
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: point.x - 4, y: point.y))
            marker.line(to: NSPoint(x: point.x + 4, y: point.y))
            marker.move(to: NSPoint(x: point.x, y: point.y - 4))
            marker.line(to: NSPoint(x: point.x, y: point.y + 4))
            marker.stroke()
        }
        let sentence = "A quiet window helps you focus." as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        let size = sentence.size(withAttributes: attributes)
        sentence.draw(at: NSPoint(x: target.midX - size.width / 2, y: target.midY - size.height / 2), withAttributes: attributes)
    }

    private func addLabel(_ text: String, frame: NSRect, size: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.font = .systemFont(ofSize: size)
        label.textColor = .black
        addSubview(label)
    }
}

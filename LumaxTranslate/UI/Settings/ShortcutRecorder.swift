import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: View {
    @Environment(\.lumaxTheme) private var theme
    let action: ShortcutAction
    let settings: ShortcutSettings

    var body: some View {
        NativeShortcutRecorder(action: action, settings: settings, theme: theme,
                               configured: settings.rememberedShortcut(for: action),
                               candidate: settings.recordingAction == action ? settings.candidate : nil,
                               isRecording: settings.recordingAction == action,
                               enabled: settings.isEnabled(action),
                               hasError: settings.error(for: action) != nil)
            .disabled(!settings.isEnabled(action))
    }
}

private struct NativeShortcutRecorder: NSViewRepresentable {
    @Environment(\.locale) private var locale
    let action: ShortcutAction
    let settings: ShortcutSettings
    let theme: LumaxTheme
    let configured: GlobalShortcut
    let candidate: GlobalShortcut?
    let isRecording: Bool
    let enabled: Bool
    let hasError: Bool

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        ShortcutRecorderControl(action: action, settings: settings)
    }

    func updateNSView(_ control: ShortcutRecorderControl, context: Context) {
        _ = locale
        control.theme = theme
        control.isEnabled = enabled
        control.refresh(configured: configured, isRecording: isRecording)
    }

    static func dismantleNSView(_ control: ShortcutRecorderControl, coordinator: ()) {
        control.endRecording()
    }
}

/// A normal keyboard-focusable button until explicitly recording. The temporary
/// monitor is local to this app, this key window and this first responder. Carbon
/// registrations remain owned by ShortcutManager throughout the interaction.
@MainActor
final class ShortcutRecorderControl: NSButton {
    let shortcutAction: ShortcutAction
    private let settings: ShortcutSettings
    private var recordingToken: UUID?
    private var localMonitor: Any?
    var theme = LumaxTheme() {
        didSet {
            needsDisplay = true
            if theme.hoverCursor != oldValue.hoverCursor { window?.invalidateCursorRects(for: self) }
        }
    }
    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: theme.hoverCursor == .pointingHand ? .pointingHand : .arrow) }
    }
    private var displayedShortcut: GlobalShortcut?
    private var recording = false

    init(action: ShortcutAction, settings: ShortcutSettings) {
        self.shortcutAction = action
        self.settings = settings
        super.init(frame: .zero)
        bezelStyle = .rounded
        isBordered = false
        setButtonType(.momentaryPushIn)
        controlSize = .regular
        font = .systemFont(ofSize: 11, weight: .medium)
        alignment = .center
        focusRingType = .none
        target = self
        self.action = #selector(toggleRecording)
        setAccessibilityLabel(accessibilityActionTitle)
        setAccessibilityHelp(L10n.string("Click to record a shortcut. Press Escape to cancel."))
        toolTip = L10n.string("Click to record a shortcut. Press Escape to cancel.")
        refresh(configured: settings.configuredShortcut(for: action), isRecording: false)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            endRecording()
            if let window { NotificationCenter.default.removeObserver(self, name: nil, object: window) }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowStoppedRecording), name: name, object: window
            )
        }
    }

    func refresh(configured: GlobalShortcut?, isRecording: Bool) {
        if let recordingToken, !settings.isRecording(recordingToken) { removeLocalMonitor() }
        displayedShortcut = configured ?? settings.rememberedShortcut(for: shortcutAction)
        recording = isRecording
        needsDisplay = true
        title = isRecording
            ? settings.candidate?.displayString ?? L10n.string("Press a combination")
            : displayedShortcut?.displayString ?? L10n.string("Disabled")
        setAccessibilityLabel(accessibilityActionTitle)
        setAccessibilityHelp(L10n.string("Click to record a shortcut. Press Escape to cancel."))
        toolTip = L10n.string("Click to record a shortcut. Press Escape to cancel.")
        setAccessibilityValue(title)
    }

    /// One renderer owns the entire control, including keyboard focus. The
    /// NSButton cell's title and system focus ring must not draw on top of it.
    override func draw(_ dirtyRect: NSRect) {
        let error = settings.error(for: shortcutAction) != nil
        let warning = NSColor(theme.isDark ? Color(red: 0.96, green: 0.72, blue: 0.40)
                                         : Color(red: 0.58, green: 0.38, blue: 0.14))
        let accent = NSColor(theme.accent)
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        let highlighted = recording || focused
        let alpha: CGFloat = isEnabled ? 1 : 0.52
        let fill = error ? warning.withAlphaComponent(0.07)
            : recording ? accent.withAlphaComponent(0.06) : NSColor(theme.control)
        fill.withAlphaComponent(fill.alphaComponent * alpha).setFill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 9, yRadius: 9)
        border.fill()
        let stroke = error ? warning : highlighted ? accent : NSColor(theme.divider)
        stroke.withAlphaComponent(stroke.alphaComponent * alpha).setStroke()
        border.lineWidth = highlighted ? 1.5 : 1
        border.stroke()

        if recording && !error {
            let label = L10n.string("Press a combination")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: accent
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            let left = (bounds.width - size.width - 12) / 2
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: left, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
            (label as NSString).draw(at: NSPoint(x: left + 12, y: bounds.midY - size.height / 2), withAttributes: attributes)
            return
        }
        let shortcut = recording ? settings.candidate ?? displayedShortcut : displayedShortcut
        let keys = shortcut?.displayKeys ?? []
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(theme.ink).withAlphaComponent(alpha)
        ]
        let widths = keys.map { max(23, ($0 as NSString).size(withAttributes: attributes).width + 10) }
        let total = widths.reduce(0, +) + CGFloat(max(0, keys.count - 1)) * 5
        var x = (bounds.width - total) / 2
        for (key, width) in zip(keys, widths) {
            let rect = NSRect(x: x, y: bounds.midY - 11.5, width: width, height: 23)
            let cap = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            NSColor(theme.isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.80))
                .withAlphaComponent(theme.isDark ? 0.10 * alpha : 0.80 * alpha).setFill()
            cap.fill()
            NSColor(theme.divider).withAlphaComponent(0.20 * alpha).setStroke()
            cap.lineWidth = 0.5
            cap.stroke()
            let size = (key as NSString).size(withAttributes: attributes)
            (key as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                  withAttributes: attributes)
            x += width + 5
        }
    }

    @objc private func toggleRecording() {
        if let recordingToken, settings.isRecording(recordingToken) {
            endRecording()
        } else {
            beginRecording()
        }
    }

    func beginRecording() {
        guard isEnabled, settings.isEnabled(shortcutAction), let window, window.makeFirstResponder(self) else { return }
        endRecording()
        recordingToken = settings.beginRecording(for: shortcutAction)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.window?.isKeyWindow == true,
                      self.window?.firstResponder === self else { return false }
                return self.handleRecordingEvent(event)
            }
            return consumed ? nil : event
        }
        refresh(configured: settings.configuredShortcut(for: shortcutAction), isRecording: true)
    }

    func endRecording() {
        if let recordingToken { settings.endRecording(recordingToken) }
        removeLocalMonitor()
        refresh(configured: settings.configuredShortcut(for: shortcutAction), isRecording: false)
    }

    @objc private func windowStoppedRecording(_ notification: Notification) { endRecording() }

    private func removeLocalMonitor() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        recordingToken = nil
    }

    override func keyDown(with event: NSEvent) {
        if handleRecordingEvent(event) { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, [kVK_Space, kVK_Return].contains(Int(event.keyCode)) {
            beginRecording()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleRecordingEvent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, settings.isEnabled(shortcutAction) else { return false }
        toggleRecording()
        return true
    }

    /// Returns true only for an event consumed by this recording session.
    @discardableResult
    func handleRecordingEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let token = recordingToken else { return false }
        guard settings.isRecording(token) else {
            removeLocalMonitor()
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if Int(event.keyCode) == kVK_Escape {
            endRecording()
        } else if Int(event.keyCode) == kVK_Tab, flags.isEmpty || flags == .shift {
            endRecording()
            if flags == .shift { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else if !event.isARepeat {
            settings.record(Self.shortcut(from: event), token: token)
            if !settings.isRecording(token) { endRecording() }
        }
        return true
    }

    static func shortcut(from event: NSEvent) -> GlobalShortcut {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    private var accessibilityActionTitle: String {
        switch shortcutAction {
        case .selection: L10n.string("Translate selection")
        case .input: L10n.string("Open translation window")
        case .ocr: L10n.string("Screenshot Translation")
        }
    }

    isolated deinit {
        if let recordingToken { settings.endRecording(recordingToken) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        NotificationCenter.default.removeObserver(self)
    }
}

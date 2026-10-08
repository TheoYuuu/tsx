import AppKit
import Carbon
import XCTest
@testable import LumaxTranslate

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    func testApplicationKeyDispatchConsumesReservedMenuCommandOnlyWhileRecording() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        _ = NSApplication.shared
        let panel = NSPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 80),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        let recorder = ShortcutRecorderControl(action: .selection, settings: fixture.settings)
        recorder.frame = NSRect(x: 0, y: 0, width: 155, height: 30)
        panel.contentView?.addSubview(recorder)
        let probe = RecorderMenuActionProbe()
        let menu = NSMenu()
        let menuRoot = NSMenuItem(title: "Test", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        menuRoot.submenu = submenu
        menu.addItem(menuRoot)
        let command = NSMenuItem(title: "Test Command", action: #selector(RecorderMenuActionProbe.invoke), keyEquivalent: "q")
        command.target = probe
        submenu.addItem(command)
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = menu
        defer {
            recorder.endRecording()
            panel.close()
            NSApp.mainMenu = previousMenu
        }
        panel.makeKeyAndOrderFront(nil)
        recorder.beginRecording()
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertTrue(panel.firstResponder === recorder)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_Q)
        ))
        NSApp.sendEvent(event)
        XCTAssertEqual(probe.invocations, 0)
        XCTAssertNotNil(fixture.settings.error(for: .selection))
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)

        recorder.endRecording()
        NSApp.sendEvent(event)
        XCTAssertEqual(probe.invocations, 1, "Normal menu handling must resume after recording.")
    }

    func testLocalKeyCandidateSavesCarbonModifiersAndEndsRecording() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let (window, recorder) = makeRecorder(fixture)
        defer { window.close() }
        recorder.beginRecording()
        XCTAssertEqual(fixture.settings.recordingAction, .selection)

        XCTAssertTrue(recorder.handleRecordingEvent(try key(kVK_ANSI_J, flags: [.command, .option, .capsLock])))
        let expected = GlobalShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | optionKey))
        XCTAssertEqual(fixture.settings.configuredShortcut(for: .selection), expected)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .selection), expected)
        XCTAssertNil(fixture.settings.recordingAction)
        XCTAssertTrue(fixture.events.actions.isEmpty)
        XCTAssertEqual(recorder.title, expected.displayString)
    }

    func testEscapeAndFocusLossPreserveBindingAndRestoreProductActions() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let (window, recorder) = makeRecorder(fixture)
        defer { window.close() }
        recorder.beginRecording()
        XCTAssertTrue(recorder.handleRecordingEvent(try key(kVK_ANSI_Q, flags: .command)))
        XCTAssertNotNil(fixture.settings.error(for: .selection))
        XCTAssertTrue(recorder.handleRecordingEvent(try key(kVK_Escape)))
        XCTAssertNil(fixture.settings.recordingAction)
        XCTAssertNil(fixture.settings.error(for: .selection))
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)

        recorder.beginRecording()
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNil(fixture.settings.recordingAction)
        fixture.registrar.onHotKey?(try fixture.id(for: .selection))
        XCTAssertEqual(fixture.events.actions, [.selection])
        XCTAssertFalse(recorder.handleRecordingEvent(try key(kVK_ANSI_J, flags: [.command, .option])))
    }

    func testReservedMenuEquivalentIsConsumedWithoutInvokingMenuOrChangingBinding() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let (window, recorder) = makeRecorder(fixture)
        defer { window.close() }
        recorder.beginRecording()
        XCTAssertTrue(recorder.performKeyEquivalent(with: try key(kVK_ANSI_Q, flags: .command)))
        XCTAssertEqual(fixture.settings.recordingAction, .selection)
        XCTAssertNotNil(fixture.settings.error(for: .selection))
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
    }

    func testInvalidUnmodifiedKeyAndAutoRepeatDoNotSaveCandidate() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let (window, recorder) = makeRecorder(fixture)
        defer { window.close() }
        recorder.beginRecording()
        XCTAssertTrue(recorder.handleRecordingEvent(try key(kVK_ANSI_J)))
        XCTAssertNotNil(fixture.settings.error(for: .selection))
        XCTAssertTrue(recorder.handleRecordingEvent(try key(kVK_ANSI_J, flags: [.command, .option], repeatKey: true)))
        XCTAssertEqual(fixture.settings.recordingAction, .selection)
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)
    }

    func testWindowResignCloseAndViewRemovalEndRecording() async {
        let fixture = ShortcutSettingsFixture()
        let (window, recorder) = makeRecorder(fixture)
        defer { window.close() }
        recorder.beginRecording()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNil(fixture.settings.recordingAction)
        recorder.beginRecording()
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertNil(fixture.settings.recordingAction)
        recorder.beginRecording()
        recorder.removeFromSuperview()
        XCTAssertNil(fixture.settings.recordingAction)
    }

    func testTabEndsRecordingAndMovesToNextControl() async throws {
        let fixture = ShortcutSettingsFixture()
        let (window, recorder) = makeRecorder(fixture)
        defer { window.close() }
        let next = NSTextField(frame: NSRect(x: 180, y: 0, width: 100, height: 28))
        window.contentView?.addSubview(next)
        recorder.nextKeyView = next
        recorder.beginRecording()
        XCTAssertTrue(recorder.handleRecordingEvent(try key(kVK_Tab)))
        XCTAssertNil(fixture.settings.recordingAction)
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)
        XCTAssertTrue(window.firstResponder === next.currentEditor())
    }

    func testKeyboardActivationAndAccessiblePressEnterRecording() async throws {
        let fixture = ShortcutSettingsFixture()
        let (window, recorder) = makeRecorder(fixture)
        defer { window.close() }
        window.makeFirstResponder(recorder)
        recorder.keyDown(with: try key(kVK_Space))
        XCTAssertEqual(fixture.settings.recordingAction, .selection)
        XCTAssertTrue(recorder.accessibilityPerformPress())
        XCTAssertNil(fixture.settings.recordingAction)
        XCTAssertTrue(recorder.accessibilityPerformPress())
        XCTAssertEqual(fixture.settings.recordingAction, .selection)
    }

    func testOptionLetterUsesPhysicalKeyAndDisabledRecorderCannotStart() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let (window, recorder) = makeRecorder(fixture)
        defer { window.close() }
        XCTAssertEqual(recorder.focusRingType, .none)
        recorder.beginRecording()
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "å", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_A)
        ))
        XCTAssertTrue(recorder.handleRecordingEvent(event))
        XCTAssertEqual(fixture.settings.configuredShortcut(for: .selection)?.displayKeys, ["⌥", "A"])
        XCTAssertNil(fixture.settings.recordingAction)
        recorder.isEnabled = false
        recorder.beginRecording()
        XCTAssertNil(fixture.settings.recordingAction)
        XCTAssertFalse(recorder.accessibilityPerformPress())
        // AppKit/SwiftUI may refresh a represented control's enabled flag. The
        // persisted pause still wins even if the native flag temporarily differs.
        XCTAssertTrue(fixture.settings.setEnabled(false, for: .selection))
        recorder.isEnabled = true
        recorder.beginRecording()
        XCTAssertNil(fixture.settings.recordingAction)
        XCTAssertFalse(recorder.accessibilityPerformPress())
    }

    private func makeRecorder(_ fixture: ShortcutSettingsFixture) -> (NSWindow, ShortcutRecorderControl) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let recorder = ShortcutRecorderControl(action: .selection, settings: fixture.settings)
        recorder.frame = NSRect(x: 0, y: 0, width: 155, height: 30)
        window.contentView?.addSubview(recorder)
        return (window, recorder)
    }

    private func key(
        _ code: Int, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: repeatKey, keyCode: UInt16(code)
        ))
    }
}

@MainActor
private final class RecorderMenuActionProbe: NSObject {
    var invocations = 0
    @objc func invoke() { invocations += 1 }
}

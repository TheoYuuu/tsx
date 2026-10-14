import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class WindowLayoutTests: XCTestCase {
    func testSharedSizeSurvivesDismissalNewCaptureAndCoordinatorRestart() async throws {
        _ = NSApplication.shared
        let preferences = try preferences()
        let windows = try isolatedWindows(preferences: preferences)
        windows.inputModel.text = "Constructed sample"
        windows.showCapturedTranslation(source: nil)
        let panel = try window("translatex.main")
        let chosen = NSSize(width: 810, height: 510)
        resize(panel, to: chosen, coordinator: windows)
        windows.dismissTranslation(restoreFocus: false)
        windows.prepareCapturedTranslation()
        windows.inputModel.text = "Another constructed sample"
        windows.showCapturedTranslation(source: nil)
        XCTAssertEqual(panel.frame.size, chosen)
        windows.shutdown()

        let restarted = try isolatedWindows(preferences: preferences)
        defer { restarted.shutdown() }
        restarted.inputModel.text = "Restored reading workspace"
        restarted.showCapturedTranslation(source: nil)
        XCTAssertEqual(try window("translatex.main").frame.size, chosen)
    }

    func testPermissionSizeIsSeparateAndRecognitionKeepsTheRememberedMainSize() async throws {
        _ = NSApplication.shared
        let preferences = try preferences()
        let chosen = NSSize(width: 830, height: 540)
        preferences.rememberWindowSize(chosen, for: .main, layout: .sideBySide)
        let windows = try isolatedWindows(preferences: preferences)
        defer { windows.shutdown() }
        windows.showPermission(.accessibility, source: nil)
        let permission = try window("translatex.permission")
        resize(permission, to: NSSize(width: 440, height: 380), coordinator: windows)
        windows.closePermission()
        windows.prepareCapturedTranslation()
        windows.inputModel.beginRecognition()
        windows.showCapturedTranslation(source: nil)
        let main = try window("translatex.main")
        XCTAssertEqual(main.frame.size, chosen)
        XCTAssertEqual(main.minSize, TranslationLayout.sideBySide.minimumSize(for: .main))
        windows.inputModel.text = "Recognized constructed sample"
        windows.inputModel.cancel()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(main.frame.size, chosen)
        XCTAssertEqual(preferences.windowSize(for: .main, layout: .sideBySide), chosen)
        XCTAssertFalse(permission.isVisible)
    }

    func testEachLayoutRestoresItsOwnSharedSizeAndKeepsEditorComposition() async throws {
        _ = NSApplication.shared
        let inputMonitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(inputMonitor) }
        let preferences = try preferences()
        let windows = try isolatedWindows(preferences: preferences)
        defer { windows.shutdown() }
        let service = TranslationServiceConfiguration(kind: .openAI)
        try windows.services.save(service, apiKey: "constructed-invalid-key")
        windows.inputModel.selectService(service.id)
        windows.inputModel.text = "Editable source "
        windows.showCapturedTranslation(source: nil)
        try await Task.sleep(for: .milliseconds(150))
        let panel = try window("translatex.main")
        let editor = try XCTUnwrap(findEditor(try XCTUnwrap(panel.contentView)))
        let horizontal = NSSize(width: 800, height: 500)
        resize(panel, to: horizontal, coordinator: windows)
        panel.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        preferences.translationLayout = .stacked
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(panel.frame.size, TranslationLayout.stacked.defaultSize(for: .main))
        XCTAssertTrue(findEditor(try XCTUnwrap(panel.contentView)) === editor)
        XCTAssertTrue(editor.hasMarkedText(), "Changing orientation must not abandon input method composition")
        XCTAssertTrue(windows.inputModel.isComposing)
        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(windows.inputModel.text, "Editable source 你好")
        XCTAssertTrue(try XCTUnwrap(editor.undoManager).canUndo)
        XCTAssertNil(windows.inputModel.request)
        let vertical = NSSize(width: 700, height: 740)
        resize(panel, to: vertical, coordinator: windows)
        preferences.translationLayout = .sideBySide
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(panel.frame.size, horizontal)
        preferences.translationLayout = .stacked
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(panel.frame.size, vertical)
        XCTAssertEqual(editor.string, "Editable source 你好")
    }

    func testMainSizePersistsAcrossRecreationAndBothLayouts() async throws {
        _ = NSApplication.shared
        let preferences = try preferences()
        let windows = try isolatedWindows(preferences: preferences)
        windows.showMain()
        let main = try window("translatex.main")
        let horizontal = NSSize(width: 920, height: 560)
        // Native zoom has no end-live-resize event. Layout switching must still
        // retain its last geometry before replacing the current frame.
        main.setFrame(NSRect(origin: main.frame.origin, size: horizontal), display: true)
        preferences.translationLayout = .stacked
        try await Task.sleep(for: .milliseconds(180))
        let vertical = NSSize(width: 700, height: 740)
        resize(main, to: vertical, coordinator: windows)
        preferences.translationLayout = .sideBySide
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(main.frame.size, horizontal)
        windows.shutdown()
        let restarted = try isolatedWindows(preferences: preferences)
        defer { restarted.shutdown() }
        restarted.showMain()
        XCTAssertEqual(try window("translatex.main").frame.size, horizontal)
        preferences.translationLayout = .stacked
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(try window("translatex.main").frame.size, vertical)
    }

    func testScreenClampingDoesNotEraseTheLargerRememberedSize() async throws {
        _ = NSApplication.shared
        let preferences = try preferences()
        let preferred = NSSize(width: 12000, height: 9000)
        preferences.rememberWindowSize(preferred, for: .main, layout: .sideBySide)
        let windows = try isolatedWindows(preferences: preferences)
        windows.inputModel.text = "Constructed sample"
        windows.showCapturedTranslation(source: nil)
        let panel = try window("translatex.main")
        let visible = try XCTUnwrap(panel.screen).visibleFrame
        XCTAssertLessThanOrEqual(panel.frame.width, visible.width)
        XCTAssertLessThanOrEqual(panel.frame.height, visible.height)
        windows.shutdown()
        XCTAssertEqual(preferences.windowSize(for: .main, layout: .sideBySide), preferred)
    }

    private func preferences() throws -> AppPreferences {
        let suite = "TranslateXTests.WindowLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return AppPreferences(defaults: defaults)
    }

    private func window(_ identifier: String) throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == identifier && $0.isVisible })
    }

    private func resize(_ window: NSWindow, to size: NSSize, coordinator: WindowCoordinator) {
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
        coordinator.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
    }

    private func findEditor(_ view: NSView) -> TranslationInputTextView? {
        if let editor = view as? TranslationInputTextView { return editor }
        return view.subviews.compactMap(findEditor).first
    }
}

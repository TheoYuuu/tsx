import AppKit
import XCTest
@testable import LumaxTranslate

@MainActor
final class WindowLayoutTests: XCTestCase {
    func testQuickSizeSurvivesDismissalNewCaptureAndCoordinatorRestart() async throws {
        _ = NSApplication.shared
        let preferences = try preferences()
        let windows = try isolatedWindows(preferences: preferences)
        windows.quickModel.text = "Constructed sample"
        windows.showQuick(source: nil)
        let panel = try window("lumax.quick")
        let chosen = NSSize(width: 810, height: 510)
        resize(panel, to: chosen, coordinator: windows)
        windows.closeQuick(restoreFocus: false)
        windows.prepareQuickTranslation()
        windows.quickModel.text = "Another constructed sample"
        windows.showQuick(source: nil)
        XCTAssertEqual(panel.frame.size, chosen)
        windows.shutdown()

        let restarted = try isolatedWindows(preferences: preferences)
        defer { restarted.shutdown() }
        restarted.quickModel.text = "Restored reading workspace"
        restarted.showQuick(source: nil)
        XCTAssertEqual(try window("lumax.quick").frame.size, chosen)
    }

    func testPermissionAndRecognitionSizesNeverOverwriteTheReadingSize() async throws {
        _ = NSApplication.shared
        let preferences = try preferences()
        let chosen = NSSize(width: 830, height: 540)
        preferences.rememberWindowSize(chosen, for: .quick, layout: .sideBySide)
        let windows = try isolatedWindows(preferences: preferences)
        defer { windows.shutdown() }
        windows.showQuick(source: nil, permission: .accessibility)
        let panel = try window("lumax.quick")
        resize(panel, to: NSSize(width: 440, height: 380), coordinator: windows)
        windows.closeQuick(restoreFocus: false)
        windows.prepareQuickTranslation()
        windows.quickModel.beginRecognition()
        windows.showQuick(source: nil)
        XCTAssertEqual(panel.frame.size, NSSize(width: 392, height: 315))
        windows.quickModel.text = "Recognized constructed sample"
        windows.quickModel.cancel()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(panel.frame.size, chosen)
        XCTAssertEqual(preferences.windowSize(for: .quick, layout: .sideBySide), chosen)
    }

    func testEachLayoutRestoresItsOwnQuickSizeAndKeepsEditorComposition() async throws {
        _ = NSApplication.shared
        let inputMonitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(inputMonitor) }
        let preferences = try preferences()
        let windows = try isolatedWindows(preferences: preferences)
        defer { windows.shutdown() }
        let service = TranslationServiceConfiguration(kind: .openAI)
        try windows.services.save(service, apiKey: "constructed-invalid-key")
        windows.quickModel.selectService(service.id)
        windows.quickModel.text = "Editable source "
        windows.showQuick(source: nil)
        try await Task.sleep(for: .milliseconds(150))
        let panel = try window("lumax.quick")
        let editor = try XCTUnwrap(findEditor(try XCTUnwrap(panel.contentView)))
        let horizontal = NSSize(width: 800, height: 500)
        resize(panel, to: horizontal, coordinator: windows)
        panel.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        preferences.translationLayout = .stacked
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(panel.frame.size, TranslationLayout.stacked.defaultSize(for: .quick))
        XCTAssertTrue(findEditor(try XCTUnwrap(panel.contentView)) === editor)
        XCTAssertTrue(editor.hasMarkedText(), "Changing orientation must not abandon input method composition")
        XCTAssertTrue(windows.quickModel.isComposing)
        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(windows.quickModel.text, "Editable source 你好")
        XCTAssertTrue(try XCTUnwrap(editor.undoManager).canUndo)
        XCTAssertNil(windows.quickModel.request)
        let vertical = NSSize(width: 570, height: 680)
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
        let main = try window("lumax.main")
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
        XCTAssertEqual(try window("lumax.main").frame.size, horizontal)
        preferences.translationLayout = .stacked
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(try window("lumax.main").frame.size, vertical)
    }

    func testScreenClampingDoesNotEraseTheLargerRememberedSize() async throws {
        _ = NSApplication.shared
        let preferences = try preferences()
        let preferred = NSSize(width: 12000, height: 9000)
        preferences.rememberWindowSize(preferred, for: .quick, layout: .sideBySide)
        let windows = try isolatedWindows(preferences: preferences)
        windows.quickModel.text = "Constructed sample"
        windows.showQuick(source: nil)
        let panel = try window("lumax.quick")
        let visible = try XCTUnwrap(panel.screen).visibleFrame
        XCTAssertLessThanOrEqual(panel.frame.width, visible.width)
        XCTAssertLessThanOrEqual(panel.frame.height, visible.height)
        windows.shutdown()
        XCTAssertEqual(preferences.windowSize(for: .quick, layout: .sideBySide), preferred)
    }

    private func preferences() throws -> AppPreferences {
        let suite = "LumaxTranslateTests.WindowLayout.\(UUID().uuidString)"
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

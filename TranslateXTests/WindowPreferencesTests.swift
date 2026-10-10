import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class WindowPreferencesTests: XCTestCase {
    func testDefaultTargetStartsNewQuickIntentsWithoutChangingAnActiveInputPair() throws {
        _ = NSApplication.shared
        let suite = "TranslateX.WindowPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousAppearance = NSApp.appearance
        defer { defaults.removePersistentDomain(forName: suite); NSApp.appearance = previousAppearance }
        let preferences = AppPreferences(defaults: defaults)
        preferences.setDefaultTarget("en")
        let windows = try isolatedWindows(preferences: preferences)
        XCTAssertEqual(windows.inputModel.target, "en")
        windows.inputModel.text = "Keep my current language pair."
        preferences.setDefaultTarget("ja")
        windows.applyDefaultTarget()
        XCTAssertEqual(windows.inputModel.target, "en")
        windows.quickModel.text = "Discard this old selection."
        windows.quickModel.source = "en"
        windows.prepareQuickTranslation()
        XCTAssertEqual(windows.quickModel.target, "ja")
        XCTAssertEqual(windows.quickModel.source, "auto")
        XCTAssertTrue(windows.quickModel.text.isEmpty)
        windows.inputModel.clear()
        windows.applyDefaultTarget()
        XCTAssertEqual(windows.inputModel.target, "ja")
    }

    func testAppearanceOverridesOnlyTheAppAndCanReturnToSystem() throws {
        _ = NSApplication.shared
        let suite = "TranslateX.WindowPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousAppearance = NSApp.appearance
        defer { defaults.removePersistentDomain(forName: suite); NSApp.appearance = previousAppearance }
        let preferences = AppPreferences(defaults: defaults)
        let windows = try isolatedWindows(preferences: preferences)
        windows.inputModel.target = "en"
        preferences.appearance = .dark
        windows.applyAppearance()
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        XCTAssertEqual(windows.inputModel.target, "en", "Changing appearance must preserve a manually selected input language, even before typing")
        preferences.appearance = .light
        windows.applyAppearance()
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        preferences.appearance = .system
        windows.applyAppearance()
        XCTAssertNil(NSApp.appearance)
    }

    func testSettingsWindowReusesItsInstanceAndDoesNotRegisterShortcutsByOpening() async throws {
        _ = NSApplication.shared
        let suite = "TranslateX.WindowPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let windows = try isolatedWindows(preferences: preferences)
        let manager = ShortcutManager()
        let shortcuts = ShortcutSettings(preferences: preferences, manager: manager, onAction: { _ in }, onBindingsChanged: {})
        defer { windows.shutdown() }
        windows.showSettings(shortcuts: shortcuts)
        let first = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.settings" && $0.isVisible })
        first.performClose(nil)
        windows.showSettings(shortcuts: shortcuts)
        let second = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.settings" && $0.isVisible })
        XCTAssertTrue(first === second)
        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == "translatex.settings" && $0.isVisible }.count, 1)
        XCTAssertTrue(ShortcutAction.allCases.allSatisfy { manager.shortcut(for: $0) == nil })
    }

    func testOpeningSettingsCancelsQueuedMainEditorFocus() async throws {
        let monitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(monitor) }
        let windows = try isolatedWindows()
        let shortcuts = ShortcutSettings(preferences: windows.preferences, manager: ShortcutManager(),
                                         onAction: { _ in }, onBindingsChanged: {})
        defer { windows.shutdown() }
        windows.showMain()
        let main = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible })
        func findEditor(in view: NSView) -> TranslationInputTextView? {
            if let editor = view as? TranslationInputTextView { return editor }
            return view.subviews.compactMap { findEditor(in: $0) }.first
        }
        let content = try XCTUnwrap(main.contentView)
        for _ in 0..<30 {
            content.layoutSubtreeIfNeeded()
            if findEditor(in: content) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try XCTUnwrap(findEditor(in: content))
        // Queue another editor focus, then open Settings before it can run.
        windows.showMain()
        XCTAssertTrue(main.makeFirstResponder(nil))
        let responder = main.firstResponder
        windows.showSettings(shortcuts: shortcuts)
        let settings = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.settings" && $0.isVisible })
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(settings.isVisible)
        XCTAssertTrue(main.firstResponder === responder, "A queued main-editor callback must not run after opening Settings.")
        XCTAssertFalse(main.firstResponder === editor)
    }
}

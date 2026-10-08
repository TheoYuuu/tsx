import AppKit
import XCTest
@testable import LumaxTranslate

@MainActor
final class WindowPreferencesTests: XCTestCase {
    func testDefaultTargetStartsNewQuickIntentsWithoutChangingAnActiveInputPair() throws {
        _ = NSApplication.shared
        let suite = "Lumax.WindowPreferencesTests.\(UUID().uuidString)"
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
        let suite = "Lumax.WindowPreferencesTests.\(UUID().uuidString)"
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
        let suite = "Lumax.WindowPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let windows = try isolatedWindows(preferences: preferences)
        let manager = ShortcutManager()
        let shortcuts = ShortcutSettings(preferences: preferences, manager: manager, onAction: { _ in }, onBindingsChanged: {})
        defer { windows.shutdown() }
        windows.showSettings(shortcuts: shortcuts)
        let first = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.settings" && $0.isVisible })
        first.performClose(nil)
        windows.showSettings(shortcuts: shortcuts)
        let second = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.settings" && $0.isVisible })
        XCTAssertTrue(first === second)
        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == "lumax.settings" && $0.isVisible }.count, 1)
        XCTAssertTrue(ShortcutAction.allCases.allSatisfy { manager.shortcut(for: $0) == nil })
    }
}

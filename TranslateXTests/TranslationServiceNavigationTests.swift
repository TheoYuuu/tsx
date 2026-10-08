import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class TranslationServiceNavigationTests: XCTestCase {
    func testCleanExitRunsImmediatelyWithoutAViewOwner() {
        let navigation = TranslationServiceNavigationCoordinator()
        var exited = false
        navigation.requestExit { exited = true }
        XCTAssertTrue(exited)
    }

    func testDirtyExitCanWaitForConfirmationWithoutLosingTheRequestedAction() {
        let navigation = TranslationServiceNavigationCoordinator()
        var pending: (@MainActor () -> Void)?
        navigation.exitHandler = { pending = $0 }
        var exits = 0
        navigation.requestExit { exits += 1 }
        XCTAssertEqual(exits, 0)
        pending?()
        XCTAssertEqual(exits, 1)
    }

    func testContinuingEditingDoesNotExecuteExitAndReleasedViewCannotInterceptLater() {
        let navigation = TranslationServiceNavigationCoordinator()
        var pending: (@MainActor () -> Void)?
        navigation.exitHandler = { pending = $0 }
        var exited = false
        navigation.requestExit { exited = true }
        pending = nil
        XCTAssertFalse(exited)
        XCTAssertNil(pending)
        navigation.exitHandler = nil
        navigation.requestExit { exited = true }
        XCTAssertTrue(exited)
    }

    func testNativeSettingsCloseWaitsForTheDraftDecision() throws {
        _ = NSApplication.shared
        let suite = "TranslateX.ServiceNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let windows = try isolatedWindows(preferences: preferences)
        let shortcuts = ShortcutSettings(preferences: preferences, manager: ShortcutManager(), onAction: { _ in }, onBindingsChanged: {})
        defer { windows.shutdown() }
        windows.showSettings(shortcuts: shortcuts)
        let window = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.settings" && $0.isVisible })
        var pending: (@MainActor () -> Void)?
        windows.serviceNavigation.exitHandler = { pending = $0 }
        window.performClose(nil)
        XCTAssertTrue(window.isVisible, "Dirty draft must stay visible until the decision")
        XCTAssertNotNil(pending)
        pending = nil // Continue editing.
        XCTAssertTrue(window.isVisible)
        window.performClose(nil)
        pending?() // Explicitly discard and execute the original window action.
        XCTAssertFalse(window.isVisible)
    }

}

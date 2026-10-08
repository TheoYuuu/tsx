import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testMenuActionsDispatchToTheirOwnerWithoutRequiringAnOpenWindow() async throws {
        _ = NSApplication.shared
        var actions: [String] = []
        let controller = MenuBarController(
            onSelection: { actions.append("selection") },
            onScreenshot: { actions.append("screenshot") },
            onOpenMain: { actions.append("main") },
            onSettings: { actions.append("settings") },
            onQuit: { actions.append("quit") }
        )
        for identifier in ["translatex.menu.selection", "translatex.menu.screenshot", "translatex.menu.input", "translatex.menu.settings", "translatex.menu.quit"] {
            let index = try XCTUnwrap(controller.menu.items.firstIndex { $0.identifier?.rawValue == identifier })
            controller.menu.performActionForItem(at: index)
        }
        XCTAssertEqual(actions, ["selection", "screenshot", "main", "settings", "quit"])
    }

    func testUnavailableShortcutIsRemovedWithoutDisablingMenuEntryOrAddingKeyEquivalent() async throws {
        _ = NSApplication.shared
        var invocations = 0
        let controller = MenuBarController(onSelection: { invocations += 1 }, onScreenshot: {}, onOpenMain: {}, onSettings: {}, onQuit: {})
        let selection = try XCTUnwrap(controller.menu.items.first { $0.identifier?.rawValue == "translatex.menu.selection" })
        let input = try XCTUnwrap(controller.menu.items.first { $0.identifier?.rawValue == "translatex.menu.input" })
        let initialSelectionTitle = selection.title
        let initialInputTitle = input.title
        controller.updateShortcuts(selection: ShortcutAction.selection.defaultShortcut, input: ShortcutAction.input.defaultShortcut)
        XCTAssertTrue(selection.title.hasSuffix(ShortcutAction.selection.defaultShortcut.displayString))
        XCTAssertTrue(input.title.hasSuffix(ShortcutAction.input.defaultShortcut.displayString))

        controller.updateShortcuts(selection: nil, input: ShortcutAction.input.defaultShortcut)
        XCTAssertEqual(selection.title, initialSelectionTitle)
        XCTAssertNotEqual(input.title, initialInputTitle)
        XCTAssertTrue(selection.isEnabled)
        controller.menu.performActionForItem(at: controller.menu.index(of: selection))
        XCTAssertEqual(invocations, 1)
        XCTAssertTrue(controller.menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    func testInvalidBindingsAreNotAdvertisedAsUsableShortcuts() async throws {
        _ = NSApplication.shared
        let controller = MenuBarController(onSelection: {}, onScreenshot: {}, onOpenMain: {}, onSettings: {}, onQuit: {})
        let titles = controller.menu.items.map(\.title)
        controller.updateShortcuts(selection: GlobalShortcut(keyCode: 0, modifiers: 0), input: nil)
        XCTAssertEqual(controller.menu.items.map(\.title), titles)
        XCTAssertFalse(controller.isRunning, "Constructing routing must not install a status item")
    }

    func testSystemStatusItemCanStartStopAndRestartWithoutDuplicateOwnership() async throws {
        _ = NSApplication.shared
        let controller = MenuBarController(onSelection: {}, onScreenshot: {}, onOpenMain: {}, onSettings: {}, onQuit: {})
        defer { controller.stop() }
        weak var removedItem: NSStatusItem?

        try autoreleasepool {
            controller.start()
            let item = try XCTUnwrap(controller.statusItem)
            removedItem = item
            let button = try XCTUnwrap(item.button)
            XCTAssertTrue(controller.isRunning)
            XCTAssertTrue(item.menu === controller.menu)
            XCTAssertTrue(item.isVisible)
            XCTAssertEqual(button.accessibilityLabel(), "TSX")
            XCTAssertEqual(button.accessibilityIdentifier(), "translatex.menu.button")
            let image = try XCTUnwrap(button.image, "The packaged menu-bar artwork must be available")
            XCTAssertTrue(image.isValid)
            XCTAssertEqual(image.name(), NSImage.Name("MenuBarIcon"))
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertTrue(image.isTemplate)

            controller.start()
            XCTAssertTrue(controller.statusItem === item, "Repeated startup must reuse the live status item")
            controller.stop()
            XCTAssertFalse(controller.isRunning)
            XCTAssertNil(controller.statusItem)
            XCTAssertNil(item.menu)
        }
        // The system removes its status-item scene asynchronously.
        for _ in 0..<20 where removedItem != nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(removedItem, "Stopping must release both controller and system-bar ownership")

        controller.stop()
        controller.start()
        XCTAssertTrue(controller.isRunning)
        XCTAssertTrue(controller.statusItem?.menu === controller.menu)
        XCTAssertNotNil(controller.statusItem?.button)
        controller.stop()
        XCTAssertNil(controller.statusItem)
    }
}

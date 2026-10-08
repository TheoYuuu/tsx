import AppKit
import Carbon
import XCTest
@testable import LumaxTranslate

@MainActor
final class QuickPanelKeyboardTests: XCTestCase {
    func testCloseMenuValidatesAndDispatchesOnceForHiddenNonclosablePanel() async throws {
        _ = NSApplication.shared
        let panel = makePanel()
        defer { panel.close() }
        let model = TranslationModel()
        model.source = "en"
        model.target = "zh-Hans"
        model.text = "A quiet morning."
        model.submit()
        XCTAssertNotNil(model.request)
        var closeRequests = 0
        panel.onEscape = {
            closeRequests += 1
            model.cancel()
        }
        let menu = NSMenu(title: "File")
        let close = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        // A hidden window cannot become NSApp.keyWindow. Use an explicit target
        // to exercise real menu validation and key dispatch without showing UI;
        // the source app's nonactivating-panel menu path needs interactive QA.
        close.target = panel
        menu.addItem(close)
        menu.update()

        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.styleMask.contains(.closable))
        XCTAssertTrue(panel.validateUserInterfaceItem(close))
        XCTAssertTrue(panel.validateMenuItem(close))
        XCTAssertTrue(close.isEnabled)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_W)
        ))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(closeRequests, 1)
        XCTAssertNil(model.request)
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertFalse(panel.isVisible)
    }

    func testCloseMenuIsDisabledWithoutCoordinatorAndEscapeUsesSameCallback() async {
        _ = NSApplication.shared
        let panel = makePanel()
        defer { panel.close() }
        let close = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        XCTAssertFalse(panel.validateUserInterfaceItem(close))
        XCTAssertFalse(panel.validateMenuItem(close))
        var closeRequests = 0
        panel.onEscape = { closeRequests += 1 }
        panel.cancelOperation(nil)
        XCTAssertEqual(closeRequests, 1)
        panel.onEscape = nil
        panel.performClose(nil)
        XCTAssertEqual(closeRequests, 1)
    }

    private func makePanel() -> QuickPanel {
        let panel = QuickPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        return panel
    }
}

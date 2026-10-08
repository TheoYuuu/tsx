import AppKit
import XCTest
@testable import LumaxTranslate

@MainActor
final class QuickWindowTests: XCTestCase {
    func testPermissionContentDoesNotExpandPanelBeyondItsRequestedHeight() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showQuick(source: nil, permission: .screenCapture)
        try await Task.sleep(for: .milliseconds(200))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.quick" && $0.isVisible })
        XCTAssertEqual(panel.title, "TSX")
        XCTAssertEqual(panel.accessibilityTitle(), "TSX")
        XCTAssertEqual(panel.titleVisibility, .hidden)
        XCTAssertLessThanOrEqual(panel.frame.height, 365, "SwiftUI content must not expand a permission panel beyond the designed size")
        XCTAssertGreaterThanOrEqual(panel.frame.height, panel.minSize.height)
    }

    func testReplacingHostedContentPreservesPanelResizeMinimum() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }

        for permission in [SystemPermission.screenCapture, nil, .accessibility, nil] {
            windows.showQuick(source: nil, permission: permission)
            let panel = try XCTUnwrap(NSApp.windows.first {
                $0.identifier?.rawValue == "lumax.quick" && $0.isVisible
            })
            // Keep the just-presented panel before yielding to external mouse
            // events. This test checks hosting geometry, not outside dismissal.
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(panel.minSize, permission == nil ? NSSize(width: 600, height: 340) : NSSize(width: 340, height: 300),
                           "A replacement hosting view must not remove the panel's user-resize limits")
        }
    }

    func testRecognitionResultGrowsPanelWhileKeepingItsTopEdgeOnScreen() async throws {
        _ = NSApplication.shared
        let handoff = try await completedHandoff()
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.quickModel.beginRecognition()
        windows.showQuick(source: nil)
        try await Task.sleep(for: .milliseconds(100))
        let panel = try quickPanel()
        XCTAssertEqual(panel.frame.size, NSSize(width: 392, height: 315))
        let visibleFrame = try XCTUnwrap(panel.screen ?? NSScreen.main).visibleFrame
        // Move without resizing: the last automatically chosen size still belongs
        // to the coordinator. Put the right edge close enough to exercise clamping.
        let initialFrame = NSRect(x: visibleFrame.maxX - 12 - panel.frame.width,
                                  y: visibleFrame.maxY - 40 - panel.frame.height,
                                  width: panel.frame.width, height: panel.frame.height)
        panel.setFrame(initialFrame, display: true)
        let initialTop = panel.frame.maxY

        windows.quickModel.acceptHandoff(handoff)
        try await waitForPanelSize(NSSize(width: 720, height: 430), panel: panel)

        XCTAssertEqual(windows.quickModel.phase, .completed)
        XCTAssertNil(windows.quickModel.request, "Completed handoff must not start a live Apple session in this test")
        XCTAssertEqual(panel.frame.maxY, initialTop, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(panel.frame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(panel.frame.maxX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(panel.frame.maxY, visibleFrame.maxY)
    }

    func testRecognitionResultDoesNotReplaceTheUsersResizedPanel() async throws {
        _ = NSApplication.shared
        let handoff = try await completedHandoff()
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.quickModel.beginRecognition()
        windows.showQuick(source: nil)
        try await Task.sleep(for: .milliseconds(100))
        let panel = try quickPanel()
        XCTAssertEqual(panel.frame.size, NSSize(width: 392, height: 315))
        let visibleFrame = try XCTUnwrap(panel.screen ?? NSScreen.main).visibleFrame
        let userFrame = NSRect(x: visibleFrame.midX - 320, y: visibleFrame.maxY - 530,
                               width: 640, height: 490)
        panel.setFrame(userFrame, display: true)
        XCTAssertEqual(panel.frame.size, userFrame.size)

        windows.quickModel.acceptHandoff(handoff)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(windows.quickModel.phase, .completed)
        XCTAssertNil(windows.quickModel.request)
        XCTAssertEqual(panel.frame, userFrame, "A result may update content but must respect a user's custom panel size and position")
    }

    func testNarrowRecognitionPanelOnlyGrowsToTheEditableWorkspaceMinimum() async throws {
        _ = NSApplication.shared
        let handoff = try await completedHandoff()
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.quickModel.beginRecognition()
        windows.showQuick(source: nil)
        let panel = try quickPanel()
        // Hold the presented object before yielding to legitimate outside-click
        // dismissal. This test verifies sizing, not global mouse interaction.
        try await Task.sleep(for: .milliseconds(100))
        let oldTop = try XCTUnwrap(panel.screen ?? NSScreen.main).visibleFrame.maxY - 40
        panel.setFrame(NSRect(x: panel.frame.minX, y: oldTop - 320, width: 360, height: 320), display: true)
        windows.quickModel.acceptHandoff(handoff)
        try await waitForPanelSize(NSSize(width: 600, height: 340), panel: panel)
        XCTAssertEqual(panel.frame.maxY, oldTop, accuracy: 0.5)
        XCTAssertEqual(panel.minSize, NSSize(width: 600, height: 340))
        windows.quickModel.fail("Constructed retry state")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(panel.frame.size, NSSize(width: 600, height: 340), "Later status changes must keep the user's size after enforcing the workspace minimum")
    }

    func testQueuedResultObservationCannotResizeANewPermissionPresentation() async throws {
        _ = NSApplication.shared
        let handoff = try await completedHandoff()
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.quickModel.beginRecognition()
        windows.showQuick(source: nil)
        try await Task.sleep(for: .milliseconds(100))

        // Completion schedules an observation callback. Replace its presentation
        // synchronously before yielding so that callback sees the permission page.
        windows.quickModel.acceptHandoff(handoff)
        windows.showQuick(source: nil, permission: .accessibility)
        let panel = try quickPanel()
        let permissionFrame = panel.frame
        XCTAssertEqual(permissionFrame.size, NSSize(width: 430, height: 365))
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(windows.quickModel.phase, .completed)
        XCTAssertEqual(panel.frame, permissionFrame)
        windows.quickModel.beginRecognition()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(panel.frame, permissionFrame, "Underlying model activity must not change the current permission presentation")
    }

    func testEscapeStopsPendingTranslationButCloseAlwaysDismissesThePanel() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showQuick(source: nil)
        let panel = try XCTUnwrap(quickPanel() as? QuickPanel)
        windows.quickModel.editingChanged("A pending translation.", isComposing: false)
        XCTAssertEqual(windows.quickModel.phase, .waiting)
        panel.cancelOperation(nil)
        XCTAssertEqual(windows.quickModel.phase, .cancelled)
        XCTAssertTrue(panel.isVisible)
        windows.quickModel.editingChanged("Another pending translation.", isComposing: false)
        panel.performClose(nil)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(windows.quickModel.phase, .cancelled)
    }

    func testEscapeClosesNativeMenusBeforeDismissingTheQuickWorkspace() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showQuick(source: nil)
        let panel = try XCTUnwrap(quickPanel() as? QuickPanel)
        let menu = NSMenu()
        let submenu = NSMenu()
        for item in [menu, submenu] {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: item)
        }
        panel.cancelOperation(nil)
        XCTAssertTrue(panel.isVisible, "An open menu must own Escape before the translation panel")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        panel.cancelOperation(nil)
        XCTAssertTrue(panel.isVisible, "Finishing a submenu must not discard the parent menu's protection")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        panel.cancelOperation(nil)
        XCTAssertFalse(panel.isVisible, "Escape must dismiss the panel after all menus have closed")

        windows.showQuick(source: nil)
        XCTAssertFalse(panel.isTrackingMenu, "A new presentation cannot inherit menu tracking from its predecessor")
    }

    private func quickPanel() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.quick" && $0.isVisible })
    }

    private func completedHandoff() async throws -> TranslationHandoff {
        let donor = TranslationModel()
        donor.source = "en"
        donor.target = "zh-Hans"
        donor.text = "A bright window helps you focus."
        donor.submit()
        await donor.run(try XCTUnwrap(donor.request), provider: QuickWindowResultProvider())
        XCTAssertEqual(donor.phase, .completed)
        return try XCTUnwrap(donor.makeHandoff())
    }

    private func waitForPanelSize(_ size: NSSize, panel: NSWindow) async throws {
        for _ in 0..<50 {
            if panel.frame.size == size { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(panel.frame.size, size, "The completed result did not receive its automatic reading size")
    }
}

@MainActor
private struct QuickWindowResultProvider: TranslationProvider {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        TranslationResult(text: "明亮的窗户让你更专注。", source: "en", target: "zh-Hans")
    }
}

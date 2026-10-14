import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class QuickWindowTests: XCTestCase {
    func testBothPermissionPromptsReuseTheCompactPanelWithoutChangingTheMainWorkspace() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.text = "An existing editable passage."
        windows.showMain()
        let main = try mainWindow()
        let host = main.contentView
        let frame = main.frame
        var previousPanel: NSWindow?
        for permission in [SystemPermission.accessibility, .screenCapture] {
            windows.showPermission(permission, source: nil)
            let panel = try permissionPanel()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(panel.title, permission.name)
            XCTAssertEqual(panel.accessibilityTitle(), permission.name)
            XCTAssertEqual(panel.titleVisibility, .visible)
            XCTAssertEqual(panel.frame.size, PermissionPromptView.permissionWindowSize)
            XCTAssertEqual(panel.minSize, PermissionPromptView.minimumWindowSize)
            XCTAssertEqual(panel.maxSize, PermissionPromptView.maximumWindowSize)
            XCTAssertTrue(panel.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
            XCTAssertFalse(panel.styleMask.contains(.fullSizeContentView))
            XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertFalse(panel.titlebarAppearsTransparent)
            for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(panel.standardWindowButton(buttonType))
                XCTAssertFalse(button.isHidden)
                XCTAssertTrue(button.isEnabled)
            }
            let content = try XCTUnwrap(panel.contentView)
            XCTAssertLessThan(content.frame.height, panel.frame.height, "Content must stay below the native titlebar")
            if let previousPanel { XCTAssertTrue(panel === previousPanel) }
            previousPanel = panel
            windows.closePermission()
            XCTAssertFalse(panel.isVisible)
            XCTAssertTrue(main.isVisible)
            XCTAssertTrue(main.contentView === host)
            XCTAssertEqual(main.frame, frame)
            XCTAssertEqual(windows.inputModel.text, "An existing editable passage.")
            XCTAssertFalse(windows.inputModel.canRestorePreviousWorkspace)
        }
    }

    func testNativePermissionCloseAndEscapePreserveTheRunningTranslationAndPreviousWorkspace() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.text = "Keep this earlier draft."
        windows.prepareCapturedTranslation()
        windows.inputModel.source = "en"
        windows.inputModel.text = "A bright window helps you focus."
        windows.inputModel.submit()
        let request = try XCTUnwrap(windows.inputModel.request)
        var permissionRequests = 0
        windows.onPermission = { _ in permissionRequests += 1 }

        windows.showPermission(.screenCapture, source: nil)
        let panel = try permissionPanel()
        let close = try XCTUnwrap(panel.standardWindowButton(.closeButton))
        close.performClick(nil)
        XCTAssertFalse(panel.isVisible, "The real traffic light must route through coordinator cleanup")
        XCTAssertEqual(windows.inputModel.request, request)
        XCTAssertEqual(windows.inputModel.phase, .translating)
        XCTAssertTrue(windows.inputModel.canRestorePreviousWorkspace)

        windows.showPermission(.accessibility, source: nil)
        XCTAssertTrue(try permissionPanel() === panel)
        panel.cancelOperation(nil)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(windows.inputModel.request, request)
        XCTAssertEqual(permissionRequests, 0, "Showing or dismissing guidance must never request system access")
        windows.restorePreviousTranslation()
        XCTAssertEqual(windows.inputModel.text, "Keep this earlier draft.")
    }

    func testPermissionPanelReopensAfterNativeMinimization() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showPermission(.screenCapture, source: nil)
        let panel = try permissionPanel()
        panel.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(panel.isMiniaturized)
        windows.showPermission(.accessibility, source: nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(panel.isMiniaturized)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(try permissionPanel() === panel)
        XCTAssertEqual(panel.title, SystemPermission.accessibility.name)
        XCTAssertEqual(panel.frame.size, PermissionPromptView.permissionWindowSize)
    }

    func testNativePermissionZoomStaysCompactAndRestoresThePreviousFrame() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showPermission(.screenCapture, source: nil)
        let panel = try permissionPanel()
        let original = panel.frame
        panel.performZoom(nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(panel.frame.width, PermissionPromptView.maximumWindowSize.width)
        XCTAssertLessThanOrEqual(panel.frame.height, PermissionPromptView.maximumWindowSize.height)
        XCTAssertNotEqual(panel.frame.size, original.size, "The native green button should still zoom")
        panel.performZoom(nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(panel.frame, original, "A second native zoom restores the previous size and position")
    }

    func testPermissionTitleFollowsTheInterfaceLanguageWithoutReplacingThePanel() async throws {
        _ = NSApplication.shared
        let originalLanguage = try XCTUnwrap(AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier))
        let windows = try isolatedWindows()
        defer {
            windows.shutdown()
            L10n.apply(originalLanguage)
        }
        windows.preferences.interfaceLanguage = .english
        windows.applyInterfaceLanguage()
        windows.showPermission(.screenCapture, source: nil)
        let panel = try permissionPanel()
        XCTAssertEqual(panel.title, "Screen Recording permission")
        windows.preferences.interfaceLanguage = .simplifiedChinese
        windows.applyInterfaceLanguage()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(panel.title, "屏幕录制权限")
        XCTAssertTrue(try permissionPanel() === panel)
    }

    func testRecognitionAndItsResultUseTheMainWindowSizeAndTheSameHost() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let preferred = NSSize(width: 920, height: 560)
        windows.preferences.rememberWindowSize(preferred, for: .main, layout: .sideBySide)
        windows.prepareCapturedTranslation()
        windows.inputModel.beginRecognition()
        windows.showCapturedTranslation(source: nil)
        let main = try mainWindow()
        let host = main.contentView
        let frame = main.frame
        XCTAssertEqual(frame.size, preferred)
        XCTAssertEqual(main.minSize, TranslationLayout.sideBySide.minimumSize(for: .main))
        windows.inputModel.acceptHandoff(try await completedHandoff())
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(windows.inputModel.phase, .completed)
        XCTAssertNil(windows.inputModel.request)
        XCTAssertTrue(main.contentView === host)
        XCTAssertEqual(main.frame, frame, "OCR completion updates content without resizing the shared workspace")
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "translatex.quick" && $0.isVisible })
    }

    func testAnotherCaptureAndResultRespectTheUsersWindowSizeAndPosition() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showMain()
        let main = try mainWindow()
        let visible = try XCTUnwrap(main.screen ?? NSScreen.main).visibleFrame
        let chosen = NSRect(x: visible.minX + 30, y: visible.maxY - 610, width: 900, height: 560)
        main.setFrame(chosen, display: true)
        windows.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: main))
        windows.prepareCapturedTranslation()
        windows.inputModel.beginRecognition()
        windows.showCapturedTranslation(source: nil, bounds: CGRect(x: 20, y: 20, width: 100, height: 30))
        XCTAssertEqual(main.frame, chosen, "A visible shared window should not jump back to the selection")
        windows.inputModel.acceptHandoff(try await completedHandoff())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(main.frame, chosen)
        XCTAssertEqual(windows.preferences.windowSize(for: .main, layout: .sideBySide), chosen.size)
    }

    func testQueuedResultCannotResizeOrReplaceTheSeparatePermissionPrompt() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showMain()
        windows.inputModel.beginRecognition()
        windows.inputModel.acceptHandoff(try await completedHandoff())
        windows.showPermission(.accessibility, source: nil)
        let panel = try permissionPanel()
        let host = panel.contentView
        let frame = panel.frame
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(panel.frame, frame)
        XCTAssertTrue(panel.contentView === host)
        XCTAssertEqual(windows.inputModel.phase, .completed)
        windows.showTranslationWindow()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(try mainWindow().isVisible)
        XCTAssertEqual(windows.inputModel.phase, .completed)
    }

    func testEscapeAndCloseDismissTheSharedWindowAndCancelPendingWorkWithoutClearingText() throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showCapturedTranslation(source: nil)
        let main = try mainWindow()
        var cancellations = 0
        windows.onQuickOperationCancelled = { cancellations += 1 }
        windows.inputModel.editingChanged("A pending translation.", isComposing: false)
        XCTAssertEqual(windows.inputModel.phase, .waiting)
        main.cancelOperation(nil)
        XCTAssertFalse(main.isVisible)
        XCTAssertEqual(windows.inputModel.phase, .cancelled)
        XCTAssertEqual(windows.inputModel.text, "A pending translation.")
        XCTAssertEqual(cancellations, 1)
        windows.showTranslationWindow()
        XCTAssertTrue(try mainWindow() === main)
        windows.inputModel.editingChanged("Another pending translation.", isComposing: false)
        main.performClose(nil)
        XCTAssertFalse(main.isVisible)
        XCTAssertEqual(windows.inputModel.phase, .cancelled)
        XCTAssertEqual(windows.inputModel.text, "Another pending translation.")
        XCTAssertEqual(cancellations, 2)
    }

    func testEscapeClosesNativeMenusBeforeDismissingTheSharedWorkspace() throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showCapturedTranslation(source: nil)
        let main = try mainWindow()
        let menu = NSMenu(), submenu = NSMenu()
        for item in [menu, submenu] {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: item)
        }
        main.cancelOperation(nil)
        XCTAssertTrue(main.isVisible)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        main.cancelOperation(nil)
        XCTAssertTrue(main.isVisible, "The parent menu still owns Escape")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        main.cancelOperation(nil)
        XCTAssertFalse(main.isVisible)
        windows.showTranslationWindow()
        XCTAssertFalse(main.isTrackingMenu)
    }

    func testLosingKeyStatusLeavesTheSharedTranslationVisible() throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.text = "Continue editing after another app is focused."
        windows.showCapturedTranslation(source: nil)
        let main = try mainWindow()
        windows.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: main))
        XCTAssertTrue(main.isVisible)
        XCTAssertEqual(windows.inputModel.text, "Continue editing after another app is focused.")
    }

    func testCancellingExternalCaptureAndShowingPermissionKeepTheCurrentTranslationRunning() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.source = "en"
        windows.inputModel.text = "A bright window helps you focus."
        windows.inputModel.submit()
        let request = try XCTUnwrap(windows.inputModel.request)
        var externalCancellations = 0
        windows.onQuickOperationCancelled = { externalCancellations += 1 }

        windows.cancelExternalCapture()
        windows.showPermission(.screenCapture, source: nil)
        XCTAssertEqual(externalCancellations, 1)
        XCTAssertEqual(windows.inputModel.request, request)
        XCTAssertEqual(windows.inputModel.phase, .translating)
        XCTAssertFalse(windows.inputModel.canRestorePreviousWorkspace)
        let permission = try permissionPanel()
        windows.cancelExternalCapture()
        XCTAssertFalse(permission.isVisible, "A subsequent capture must not include the previous permission prompt")
        await windows.inputModel.run(request, provider: QuickWindowResultProvider())
        XCTAssertEqual(windows.inputModel.phase, .completed)
        XCTAssertEqual(windows.inputModel.translatedText, "明亮的窗户让你更专注。")
        XCTAssertEqual(windows.inputModel.request, request)
    }

    func testExternalCaptureCancellationKeepsScheduledEditingUntilContentIsDelivered() throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.source = "en"
        windows.inputModel.editingChanged("A scheduled editable passage.", isComposing: false)
        XCTAssertEqual(windows.inputModel.phase, .waiting)
        windows.cancelExternalCapture()
        XCTAssertEqual(windows.inputModel.phase, .waiting)
        XCTAssertEqual(windows.inputModel.text, "A scheduled editable passage.")
        XCTAssertFalse(windows.inputModel.canRestorePreviousWorkspace)
        windows.prepareCapturedTranslation()
        XCTAssertEqual(windows.inputModel.phase, .empty)
        XCTAssertTrue(windows.inputModel.canRestorePreviousWorkspace)
        XCTAssertNil(windows.inputModel.request)
    }

    func testCancellingOldRecognitionCannotCancelTheNextScreenshotWorkflowOnDelivery() throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        var workflow = ScreenshotWorkflowState()
        var recognitionCancellations = 0
        windows.onQuickOperationCancelled = { workflow.cancel() }
        let old = workflow.begin(restoration: .input, inheritedRestoration: nil)
        windows.inputModel.beginRecognition(cancellation: {
            recognitionCancellations += 1
            workflow.cancel()
        })
        windows.cancelExternalCapture()
        XCTAssertEqual(recognitionCancellations, 1)
        XCTAssertNil(workflow.requestID)
        XCTAssertEqual(windows.inputModel.phase, .cancelled)

        let current = workflow.begin(restoration: .input, inheritedRestoration: nil)
        XCTAssertNotEqual(current, old)
        windows.prepareCapturedTranslation()
        XCTAssertEqual(workflow.requestID, current, "The old OCR callback must already have been detached")
        let image = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let region = ScreenshotRegion(id: UUID(), text: "A clear captured passage.",
            bounds: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.2), confidence: 1, role: .paragraph, separator: "")
        windows.inputModel.beginRecognition(image: image, cancellation: {
            recognitionCancellations += 1
            workflow.cancel()
        })
        windows.inputModel.submitCapturedDocument(ScreenshotDocument(image: image, regions: [region]),
                                                   serviceRevision: windows.inputModel.captureServiceIntent())
        XCTAssertEqual(recognitionCancellations, 1, "Successful OCR delivery releases its callback without cancelling itself")
        XCTAssertEqual(workflow.requestID, current)
        XCTAssertEqual(windows.inputModel.phase, .translating)
        XCTAssertEqual(workflow.finish(current), .input)
    }

    private func mainWindow() throws -> TranslationWindow {
        try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible } as? TranslationWindow)
    }

    private func permissionPanel() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.permission" && $0.isVisible })
    }

    private func completedHandoff() async throws -> TranslationHandoff {
        let donor = TranslationModel()
        donor.source = "en"
        donor.target = "zh-Hans"
        donor.text = "A bright window helps you focus."
        donor.submit()
        await donor.run(try XCTUnwrap(donor.request), provider: QuickWindowResultProvider())
        return try XCTUnwrap(donor.makeHandoff())
    }
}

@MainActor
private struct QuickWindowResultProvider: TranslationProvider {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        TranslationResult(text: "明亮的窗户让你更专注。", source: "en", target: "zh-Hans")
    }
}

import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class QuickHandoffWindowTests: XCTestCase {
    func testRecognizingRejectsStaleActionWithoutCancellingOrReplacingWorkspace() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let previous = try await complete(windows.inputModel, text: "Previous passage.", translated: "原有译文。")
        let previousRequest = windows.inputModel.request
        let existingMainWindows = NSApp.windows.filter { $0.identifier?.rawValue == "translatex.main" }.count
        var cancellations = 0
        windows.onQuickOperationCancelled = { cancellations += 1 }
        let staleAction = { windows.openQuickInMain() }

        windows.quickModel.beginRecognition()
        staleAction()
        windows.openQuickInMain()

        XCTAssertFalse(windows.canOpenQuickInMain)
        XCTAssertEqual(windows.quickModel.phase, .recognizing)
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(windows.inputModel.text, "Previous passage.")
        XCTAssertEqual(windows.inputModel.result, previous)
        XCTAssertEqual(windows.inputModel.request, previousRequest)
        XCTAssertEqual(windows.inputModel.phase, .completed)
        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == "translatex.main" }.count, existingMainWindows)
    }

    func testCompletedRecognitionTransfersThroughActualCoordinatorEntry() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.text = "Previous workspace."
        windows.quickModel.beginRecognition()
        var cancellations = 0
        windows.onQuickOperationCancelled = { cancellations += 1 }
        windows.openQuickInMain()
        XCTAssertEqual(cancellations, 0)
        let result = try await complete(windows.quickModel, text: "Recognized passage.", translated: "识别后的译文。")

        XCTAssertTrue(windows.canOpenQuickInMain)
        windows.openQuickInMain()

        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(windows.inputModel.text, "Recognized passage.")
        XCTAssertEqual(windows.inputModel.source, "en")
        XCTAssertEqual(windows.inputModel.target, "zh-Hans")
        XCTAssertEqual(windows.inputModel.result, result)
        XCTAssertEqual(windows.inputModel.phase, .completed)
        XCTAssertNil(windows.inputModel.request)
        XCTAssertNil(windows.quickModel.request)
    }

    func testPassageStillTranslatingCanMoveWithoutStartingAnotherRequest() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.quickModel.source = "en"
        windows.quickModel.target = "fr"
        windows.quickModel.text = "A recognized passage."
        windows.quickModel.submit()
        let original = try XCTUnwrap(windows.quickModel.request)
        var cancellations = 0
        windows.onQuickOperationCancelled = { cancellations += 1 }

        XCTAssertTrue(windows.canOpenQuickInMain)
        windows.openQuickInMain()

        XCTAssertNil(windows.inputModel.request)
        XCTAssertEqual(windows.inputModel.text, original.text)
        XCTAssertEqual(windows.inputModel.source, original.source)
        XCTAssertEqual(windows.inputModel.target, original.target)
        XCTAssertEqual(windows.inputModel.phase, .cancelled)
        XCTAssertEqual(cancellations, 1)
        XCTAssertNil(windows.quickModel.request)
    }

    func testPermissionAndOrdinaryEmptyEntriesPreserveExistingWorkspace() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let previous = try await complete(windows.inputModel, text: "Previous passage.", translated: "原有译文。")
        let previousRequest = windows.inputModel.request
        var cancellations = 0
        windows.onQuickOperationCancelled = { cancellations += 1 }

        for permission in [SystemPermission.accessibility, .screenCapture, nil] {
            windows.showQuick(source: nil, permission: permission)
            XCTAssertTrue(windows.canOpenQuickInMain)
            windows.openQuickInMain()
            XCTAssertEqual(windows.inputModel.text, "Previous passage.")
            XCTAssertEqual(windows.inputModel.result, previous)
            XCTAssertEqual(windows.inputModel.request, previousRequest)
            XCTAssertEqual(windows.inputModel.phase, .completed)
        }
        XCTAssertEqual(cancellations, 3)
    }

    private func complete(_ model: TranslationModel, text: String, translated: String) async throws -> TranslationResult {
        model.source = "en"
        model.target = "zh-Hans"
        model.text = text
        model.submit()
        let result = TranslationResult(text: translated, source: "en", target: "zh-Hans")
        await model.run(try XCTUnwrap(model.request), provider: QuickHandoffProvider(result: result))
        return result
    }

    func testReopeningDismissedQuickResultKeepsItsHostFrameAndMainDraftWithoutRequest() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showMain()
        let main = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible })
        windows.inputModel.text = "An independent main draft."
        let result = try await complete(windows.quickModel, text: "Recent selection.", translated: "最近的译文。")
        windows.showQuick(source: nil)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.quick" && $0.isVisible })
        let host = try XCTUnwrap(panel.contentView)
        let frame = panel.frame
        windows.closeQuick(restoreFocus: false)
        XCTAssertFalse(panel.isVisible)
        windows.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: main))
        await Task.yield()

        windows.showTranslationWindow()

        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.contentView === host, "Keep local mode, scroll, zoom and editor state")
        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(windows.quickModel.result, result)
        XCTAssertEqual(windows.quickModel.translatedText, "最近的译文。")
        XCTAssertNil(windows.quickModel.request, "Viewing a result never submits it again")
        XCTAssertEqual(windows.inputModel.text, "An independent main draft.")
    }

    func testReopeningScreenshotPreservesImageRegionsCorrectionsAndFailure() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let image = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let document = try ScreenshotDocument(image: image, blocks: [OCRTextBlock(text: "A recent screenshot.", bounds: CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.1))])
        windows.quickModel.source = "en"
        windows.quickModel.submitCapturedDocument(document, serviceRevision: windows.quickModel.serviceRevision)
        await windows.quickModel.run(try XCTUnwrap(windows.quickModel.request), provider: QuickHandoffProvider(result: .init(text: "截图译文。", source: "en", target: "zh-Hans")))
        windows.quickModel.editScreenshotRegion(document.regions[0].id, text: "手动修改的完整译文。", side: .target)
        windows.quickModel.fail("Constructed failure; keep the corrected region")
        windows.showQuick(source: nil)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.quick" && $0.isVisible })
        let expected = windows.quickModel.screenshot
        windows.closeQuick(restoreFocus: false)
        windows.showTranslationWindow()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(windows.quickModel.screenshot, expected)
        XCTAssertEqual(windows.quickModel.screenshot?.image.width, 400)
        XCTAssertEqual(windows.quickModel.translatedText, "手动修改的完整译文。")
        XCTAssertTrue(windows.quickModel.hasTranslationFailure)
        XCTAssertNil(windows.quickModel.request)
    }

    func testReopeningEmptyOrPermissionPanelFallsBackToExistingMainContent() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let result = try await complete(windows.inputModel, text: "Main passage.", translated: "主窗口译文。")
        let request = windows.inputModel.request
        for permission in [nil, SystemPermission.screenCapture] {
            windows.showQuick(source: nil, permission: permission)
            let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.quick" && $0.isVisible })
            windows.closeQuick(restoreFocus: false)
            windows.showTranslationWindow()
            XCTAssertFalse(panel.isVisible)
            XCTAssertTrue(NSApp.windows.contains { $0.identifier?.rawValue == "translatex.main" && $0.isVisible })
            XCTAssertEqual(windows.inputModel.result, result)
            XCTAssertEqual(windows.inputModel.request, request, "Reopening must not start another request")
        }
    }

    func testExplicitMainPresentationBecomesTheWorkspaceToReopen() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        _ = try await complete(windows.quickModel, text: "Older quick passage.", translated: "较早的译文。")
        windows.showQuick(source: nil)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.quick" && $0.isVisible })
        windows.showMain()
        windows.inputModel.text = "The latest main draft."
        windows.showTranslationWindow()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(windows.inputModel.text, "The latest main draft.")
        XCTAssertEqual(windows.quickModel.translatedText, "较早的译文。")
        XCTAssertNil(windows.quickModel.request)
    }

    func testReopeningHiddenQuickHostAppliesNewLayoutAndItsRememberedSize() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        _ = try await complete(windows.quickModel, text: "Retained passage.", translated: "保留的译文。")
        windows.showQuick(source: nil)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.quick" && $0.isVisible })
        let host = panel.contentView
        windows.closeQuick(restoreFocus: false)
        windows.preferences.rememberWindowSize(NSSize(width: 500, height: 600), for: .quick, layout: .stacked)
        windows.preferences.translationLayout = .stacked
        await Task.yield()
        windows.showTranslationWindow()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.contentView === host)
        XCTAssertEqual(panel.minSize, TranslationLayout.stacked.minimumSize(for: .quick))
        XCTAssertEqual(panel.frame.size, NSSize(width: 500, height: 600))
        XCTAssertEqual(windows.quickModel.translatedText, "保留的译文。")
        XCTAssertNil(windows.quickModel.request)
    }

    func testUpdateUsesMainWindowAndRestoresItsEditorsWithoutReplacingContent() async throws {
        let monitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(monitor) }
        let (windows, updates, _) = try updateWindowFixture()
        defer { windows.shutdown() }
        let result = try await complete(windows.inputModel, text: "Constructed update draft.", translated: "更新前保留的译文。")
        let completedRequest = windows.inputModel.request
        var settingsRequests = 0
        windows.onSettings = { settingsRequests += 1 }
        windows.showMain()
        let main = try visibleUpdateMainWindow()
        let surface = try XCTUnwrap(main.contentView as? WindowSurface<InputTranslationView>)
        try await waitForUpdateWindowState { self.updateEditors(in: surface).count == 2 }
        let editors = updateEditors(in: surface)
        let editorContents = editors.map(\.string)
        XCTAssertTrue(editors.allSatisfy(\.isEditable))

        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true, reply: { _ in })
        try await waitForUpdateWindowState {
            surface.modalHostingView != nil && editors.allSatisfy { !$0.isInteractionEnabled }
        }

        XCTAssertTrue(updates.showsMainUpdate)
        XCTAssertTrue(updates.isPresentingMainModal)
        XCTAssertTrue(try visibleUpdateMainWindow() === main)
        XCTAssertTrue(main.contentView === surface)
        XCTAssertEqual(settingsRequests, 0)
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "translatex.settings" && $0.isVisible })
        XCTAssertFalse(main.firstResponder is TranslationInputTextView)
        let overlay = try XCTUnwrap(surface.modalHostingView)
        XCTAssertTrue(surface.subviews.last === overlay)
        XCTAssertTrue(editors.allSatisfy { !$0.isEditable && !$0.isSelectable && !$0.acceptsFirstResponder })
        for editor in editors {
            editor.insertText("Blocked modal edit", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        XCTAssertEqual(editors.map(\.string), editorContents)

        updates.dismissUpdate()
        try await waitForUpdateWindowState {
            surface.modalHostingView == nil && editors.allSatisfy(\.isInteractionEnabled)
        }
        XCTAssertFalse(updates.showsMainUpdate)
        XCTAssertFalse(updates.isPresentingMainModal)
        XCTAssertTrue(main.isVisible)
        XCTAssertTrue(main.contentView === surface)
        XCTAssertEqual(updateEditors(in: surface).map(ObjectIdentifier.init), editors.map(ObjectIdentifier.init))
        XCTAssertTrue(editors.allSatisfy(\.isEditable))
        XCTAssertEqual(editors.map(\.string), editorContents)
        XCTAssertEqual(windows.inputModel.text, "Constructed update draft.")
        XCTAssertEqual(windows.inputModel.result, result)
        XCTAssertEqual(windows.inputModel.request, completedRequest, "Showing or dismissing the update must not replace the completed request.")
    }

    func testUpdateWaitsForServiceDraftExitBeforeShowingItsMainModal() async throws {
        let monitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(monitor) }
        let (windows, updates, _) = try updateWindowFixture()
        defer { windows.shutdown() }
        var pendingExit: (@MainActor () -> Void)?
        var exitRequests = 0
        windows.serviceNavigation.exitHandler = { [weak windows] action in
            exitRequests += 1
            pendingExit = action
            windows?.serviceNavigation.isPresentingConfirmation = true
        }
        let visibleMainCount = NSApp.windows.filter { $0.identifier?.rawValue == "translatex.main" && $0.isVisible }.count

        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true, reply: { _ in })

        XCTAssertEqual(exitRequests, 1)
        XCTAssertNotNil(pendingExit)
        XCTAssertEqual(updates.updatePresentation?.phase, .available)
        XCTAssertFalse(updates.showsMainUpdate)
        XCTAssertFalse(updates.isPresentingMainModal)
        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == "translatex.main" && $0.isVisible }.count, visibleMainCount)
        updates.focusUpdate()
        XCTAssertEqual(exitRequests, 1, "Refocusing a pending update must not replace the draft confirmation action.")

        // Keeping the service draft cancels only that navigation attempt. The
        // available update must remain reachable when the user opens it again.
        pendingExit = nil
        windows.serviceNavigation.isPresentingConfirmation = false
        updates.focusUpdate()
        XCTAssertEqual(exitRequests, 2)
        XCTAssertNotNil(pendingExit)
        XCTAssertFalse(updates.showsMainUpdate)

        // An independent translation-window request cannot approve leaving the
        // settings draft or mount the pending update behind its confirmation.
        windows.showMain()
        let main = try visibleUpdateMainWindow()
        let surface = try XCTUnwrap(main.contentView as? WindowSurface<InputTranslationView>)
        try await waitForUpdateWindowState { self.updateEditors(in: surface).count == 2 }
        XCTAssertFalse(updates.showsMainUpdate)
        XCTAssertNil(surface.modalHostingView)
        XCTAssertTrue(updateEditors(in: surface).allSatisfy(\.isInteractionEnabled))
        XCTAssertEqual(exitRequests, 2)

        windows.serviceNavigation.isPresentingConfirmation = false
        try XCTUnwrap(pendingExit)()
        pendingExit = nil
        try await waitForUpdateWindowState {
            surface.modalHostingView != nil && self.updateEditors(in: surface).allSatisfy { !$0.isInteractionEnabled }
        }
        XCTAssertTrue(updates.showsMainUpdate)
        XCTAssertTrue(updates.isPresentingMainModal)
        XCTAssertTrue(try visibleUpdateMainWindow() === main)
        XCTAssertEqual(exitRequests, 2)
    }

    func testDismissingUpdateKeepsPendingInstalledNotesUnacknowledged() async throws {
        try await assertUpdatePreservesMainNotes(showRecent: false)
    }

    func testDismissingUpdateKeepsRecentNotesAndPendingInstalledVersionUnacknowledged() async throws {
        try await assertUpdatePreservesMainNotes(showRecent: true)
    }

    private func assertUpdatePreservesMainNotes(showRecent: Bool) async throws {
        let monitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(monitor) }
        let (windows, updates, defaults) = try updateWindowFixture()
        defer { windows.shutdown() }
        defaults.set("1.0.0", forKey: "TSXLastLaunchedReleaseVersion")
        updates.prepareInstalledReleaseNotes()
        if showRecent { updates.showRecentReleaseNotes(in: .mainWindow) }
        let expectedMode: AppReleaseNotesMode = showRecent ? .recent : .installed(version: "1.1.0")
        let main = try visibleUpdateMainWindow()
        let surface = try XCTUnwrap(main.contentView as? WindowSurface<InputTranslationView>)
        try await waitForUpdateWindowState { self.updateEditors(in: surface).count == 2 }
        XCTAssertEqual(updates.mainReleaseNotesPresentation, expectedMode)

        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true, reply: { _ in })
        XCTAssertTrue(updates.showsMainUpdate)
        XCTAssertEqual(updates.mainReleaseNotesPresentation, expectedMode)
        updates.dismissUpdate()
        try await waitForUpdateWindowState {
            surface.modalHostingView != nil && self.updateEditors(in: surface).allSatisfy { !$0.isInteractionEnabled }
        }

        XCTAssertNil(updates.updatePresentation)
        XCTAssertFalse(updates.showsMainUpdate)
        XCTAssertTrue(updates.isPresentingMainModal, "Closing an update must leave the older release-notes modal in place.")
        XCTAssertEqual(updates.mainReleaseNotesPresentation, expectedMode)
        XCTAssertEqual(updates.pendingReleaseNotesVersion, "1.1.0")
        XCTAssertEqual(defaults.string(forKey: "TSXPendingInstalledReleaseVersion"), "1.1.0")
        XCTAssertNil(defaults.string(forKey: "TSXAcknowledgedReleaseNotesVersion"))
        XCTAssertFalse(main.firstResponder is TranslationInputTextView)
    }

    private func updateWindowFixture() throws -> (WindowCoordinator, AppUpdateController, UserDefaults) {
        _ = NSApplication.shared
        let suite = "TranslateXTests.MainUpdate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let releases = ["1.1.0", "2.0.0"].map {
            AppRelease(version: $0, publishedAt: .distantPast, notes: "Constructed release notes.",
                       url: URL(string: "https://github.com/TheoYuuu/tsx/releases/tag/v\($0)")!)
        }
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          currentVersion: "1.1.0", defaults: defaults,
                                          recordsInstalledVersions: true, backend: QuickHandoffUpdateBackend(),
                                          releases: AppReleaseNotesStore(entries: releases, allowsNetworkLoading: false))
        let windows = try isolatedWindows()
        windows.inputModel.setAutomaticTranslation(false)
        windows.updates = updates
        updates.onPresentUpdate = { [weak windows] in windows?.showMainUpdate() }
        updates.onPresentReleaseNotes = { [weak windows] in windows?.showMainReleaseNotes() }
        return (windows, updates, defaults)
    }

    private func visibleUpdateMainWindow() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible })
    }

    private func updateEditors(in view: NSView) -> [TranslationInputTextView] {
        if let editor = view as? TranslationInputTextView { return [editor] }
        return view.subviews.flatMap { updateEditors(in: $0) }
    }

    private func waitForUpdateWindowState(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "The main update window did not reach the expected state.", file: file, line: line)
    }
}

@MainActor
private struct QuickHandoffProvider: TranslationProvider {
    let result: TranslationResult
    func translate(_ request: TranslationRequest) async throws -> TranslationResult { result }
}

@MainActor
private final class QuickHandoffUpdateBackend: AppUpdaterBackend {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    func start() throws {}
    func checkInformation() {}
    func checkUpdates() {}
}

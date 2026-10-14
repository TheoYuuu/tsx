import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class QuickHandoffWindowTests: XCTestCase {
    func testCapturedContentReplacesTheSharedWorkspaceAndPreviousCompletionCanBeRestored() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let previous = try await complete(windows.inputModel, text: "Previous passage.", translated: "原有译文。")
        windows.inputModel.sourceName = "Constructed source application"
        windows.showMain()
        let main = try visibleUpdateMainWindow()
        let host = main.contentView
        windows.prepareCapturedTranslation()
        XCTAssertEqual(windows.inputModel.source, "auto")
        XCTAssertEqual(windows.inputModel.target, "zh-Hans")
        XCTAssertTrue(windows.inputModel.text.isEmpty)
        XCTAssertTrue(windows.inputModel.canRestorePreviousWorkspace)
        windows.inputModel.beginRecognition()
        let current = try await complete(windows.inputModel, text: "Recognized passage.", translated: "识别后的译文。")
        windows.showCapturedTranslation(source: nil)
        XCTAssertTrue(try visibleUpdateMainWindow() === main)
        XCTAssertTrue(main.contentView === host)
        XCTAssertEqual(windows.inputModel.result, current)
        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == "translatex.main" && $0.isVisible }.count, 1)
        var cancellations = 0
        windows.onQuickOperationCancelled = { cancellations += 1 }

        windows.restorePreviousTranslation()
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(windows.inputModel.text, "Previous passage.")
        XCTAssertEqual(windows.inputModel.sourceName, "Constructed source application")
        XCTAssertEqual(windows.inputModel.result, previous)
        XCTAssertEqual(windows.inputModel.phase, .completed)
        XCTAssertNil(windows.inputModel.request)
        XCTAssertTrue(main.contentView === host)
        XCTAssertFalse(windows.inputModel.canRestorePreviousWorkspace)
        windows.restorePreviousTranslation()
        XCTAssertEqual(cancellations, 1, "A consumed recovery slot cannot cancel unrelated work")
    }

    func testRestoringPreviousContentStopsCurrentRecognitionAndKeepsTheSameWindow() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.text = "The previous draft."
        windows.showMain()
        let main = try visibleUpdateMainWindow()
        var cancellations = 0
        var recognitionCancellations = 0
        windows.onQuickOperationCancelled = { cancellations += 1 }
        windows.prepareCapturedTranslation()
        windows.inputModel.beginRecognition(cancellation: { recognitionCancellations += 1 })
        windows.showCapturedTranslation(source: nil)
        windows.restorePreviousTranslation()
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(recognitionCancellations, 1)
        XCTAssertEqual(windows.inputModel.text, "The previous draft.")
        XCTAssertFalse(windows.inputModel.isBusy)
        XCTAssertNil(windows.inputModel.request)
        XCTAssertTrue(try visibleUpdateMainWindow() === main)
    }

    func testPermissionPromptsPreserveCurrentResultAndThePreviousWorkspaceSlot() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let previous = try await complete(windows.inputModel, text: "Previous passage.", translated: "原有译文。")
        windows.prepareCapturedTranslation()
        let current = try await complete(windows.inputModel, text: "Current passage.", translated: "当前译文。")
        let currentRequest = windows.inputModel.request
        windows.showCapturedTranslation(source: nil)
        let main = try visibleUpdateMainWindow()
        for permission in [SystemPermission.accessibility, .screenCapture] {
            windows.showPermission(permission, source: nil)
            let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.permission" && $0.isVisible })
            windows.showTranslationWindow()
            XCTAssertFalse(panel.isVisible)
            XCTAssertTrue(try visibleUpdateMainWindow() === main)
            XCTAssertEqual(windows.inputModel.result, current)
            XCTAssertEqual(windows.inputModel.request, currentRequest)
            XCTAssertTrue(windows.inputModel.canRestorePreviousWorkspace)
        }
        windows.restorePreviousTranslation()
        XCTAssertEqual(windows.inputModel.result, previous)
    }

    func testDismissedResultReopensItsExistingHostAndFrameWithoutRequest() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let result = try await complete(windows.inputModel, text: "Recent selection.", translated: "最近的译文。")
        windows.showCapturedTranslation(source: nil)
        let main = try visibleUpdateMainWindow()
        let host = try XCTUnwrap(main.contentView)
        let frame = main.frame
        windows.dismissTranslation(restoreFocus: false)
        XCTAssertFalse(main.isVisible)
        windows.showTranslationWindow()
        XCTAssertTrue(try visibleUpdateMainWindow() === main)
        XCTAssertTrue(main.contentView === host, "Reopening preserves native editor and screenshot presentation state")
        XCTAssertEqual(main.frame, frame)
        XCTAssertEqual(windows.inputModel.result, result)
        XCTAssertEqual(windows.inputModel.translatedText, "最近的译文。")
        XCTAssertNil(windows.inputModel.request)
    }

    func testScreenshotReplacementAndRecoveryPreservePixelsRegionsCorrectionsAndFailure() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let image = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let document = try ScreenshotDocument(image: image, blocks: [OCRTextBlock(text: "A recent screenshot.", bounds: CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.1))])
        windows.inputModel.source = "en"
        windows.inputModel.useScreenshotSourceName()
        windows.inputModel.submitCapturedDocument(document, serviceRevision: windows.inputModel.serviceRevision)
        await windows.inputModel.run(try XCTUnwrap(windows.inputModel.request), provider: QuickHandoffProvider(result: .init(text: "截图译文。", source: "en", target: "zh-Hans")))
        windows.inputModel.editScreenshotRegion(document.regions[0].id, text: "手动修改的完整译文。", side: .target)
        windows.inputModel.fail("Constructed failure; keep the corrected region")
        windows.showCapturedTranslation(source: nil)
        let main = try visibleUpdateMainWindow()
        let host = main.contentView
        let expected = windows.inputModel.screenshot
        windows.dismissTranslation(restoreFocus: false)
        windows.showTranslationWindow()
        XCTAssertTrue(main.contentView === host)
        XCTAssertEqual(windows.inputModel.screenshot, expected)
        windows.prepareCapturedTranslation()
        windows.inputModel.text = "A newer text capture."
        windows.restorePreviousTranslation()
        XCTAssertEqual(windows.inputModel.screenshot, expected)
        XCTAssertEqual(windows.inputModel.screenshot?.image.width, 400)
        XCTAssertEqual(windows.inputModel.translatedText, "手动修改的完整译文。")
        XCTAssertEqual(windows.inputModel.sourceName, L10n.string("Screenshot"))
        XCTAssertTrue(windows.inputModel.hasTranslationFailure)
        XCTAssertNil(windows.inputModel.request)
    }

    func testCancelledScreenshotSelectionReopensWithoutReplacingContentOrRecoverySlot() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.text = "The previous draft."
        windows.prepareCapturedTranslation()
        let result = try await complete(windows.inputModel, text: "The current passage.", translated: "当前译文。")
        windows.showMain()
        let main = try visibleUpdateMainWindow()
        let host = main.contentView
        _ = windows.hideForScreenshot()
        XCTAssertFalse(main.isVisible)
        windows.restoreAfterScreenshotCancellation(.input)
        XCTAssertTrue(try visibleUpdateMainWindow() === main)
        XCTAssertTrue(main.contentView === host)
        XCTAssertEqual(windows.inputModel.result, result)
        XCTAssertTrue(windows.inputModel.canRestorePreviousWorkspace)
        windows.restorePreviousTranslation()
        XCTAssertEqual(windows.inputModel.text, "The previous draft.")
    }

    func testMainAndShortcutPresentationsAlwaysReuseTheLatestSharedDraft() throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showCapturedTranslation(source: nil)
        let main = try visibleUpdateMainWindow()
        windows.inputModel.text = "The latest shared draft."
        windows.showMain()
        windows.showTranslationWindow()
        XCTAssertTrue(try visibleUpdateMainWindow() === main)
        XCTAssertEqual(windows.inputModel.text, "The latest shared draft.")
        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == "translatex.main" && $0.isVisible }.count, 1)
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "translatex.quick" && $0.isVisible })
    }

    func testReopeningHiddenHostAppliesNewLayoutAndItsRememberedMainSize() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        _ = try await complete(windows.inputModel, text: "Retained passage.", translated: "保留的译文。")
        windows.showCapturedTranslation(source: nil)
        let main = try visibleUpdateMainWindow()
        let host = main.contentView
        windows.dismissTranslation(restoreFocus: false)
        windows.preferences.rememberWindowSize(NSSize(width: 700, height: 740), for: .main, layout: .stacked)
        windows.preferences.translationLayout = .stacked
        await Task.yield()
        windows.showTranslationWindow()
        XCTAssertTrue(try visibleUpdateMainWindow() === main)
        XCTAssertTrue(main.contentView === host)
        XCTAssertEqual(main.minSize, TranslationLayout.stacked.minimumSize(for: .main))
        XCTAssertEqual(main.frame.size, NSSize(width: 700, height: 740))
        XCTAssertEqual(windows.inputModel.translatedText, "保留的译文。")
        XCTAssertNil(windows.inputModel.request)
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
        updates.onPresentUpdate = { [weak windows] in windows?.showUpdate() }
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

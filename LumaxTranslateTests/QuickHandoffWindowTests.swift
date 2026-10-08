import AppKit
import XCTest
@testable import LumaxTranslate

@MainActor
final class QuickHandoffWindowTests: XCTestCase {
    func testRecognizingRejectsStaleActionWithoutCancellingOrReplacingWorkspace() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let previous = try await complete(windows.inputModel, text: "Previous passage.", translated: "原有译文。")
        let previousRequest = windows.inputModel.request
        let existingMainWindows = NSApp.windows.filter { $0.identifier?.rawValue == "lumax.main" }.count
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
        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == "lumax.main" }.count, existingMainWindows)
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
        let main = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.main" && $0.isVisible })
        windows.inputModel.text = "An independent main draft."
        let result = try await complete(windows.quickModel, text: "Recent selection.", translated: "最近的译文。")
        windows.showQuick(source: nil)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.quick" && $0.isVisible })
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
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.quick" && $0.isVisible })
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
            let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.quick" && $0.isVisible })
            windows.closeQuick(restoreFocus: false)
            windows.showTranslationWindow()
            XCTAssertFalse(panel.isVisible)
            XCTAssertTrue(NSApp.windows.contains { $0.identifier?.rawValue == "lumax.main" && $0.isVisible })
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
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.quick" && $0.isVisible })
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
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.quick" && $0.isVisible })
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
}

@MainActor
private struct QuickHandoffProvider: TranslationProvider {
    let result: TranslationResult
    func translate(_ request: TranslationRequest) async throws -> TranslationResult { result }
}

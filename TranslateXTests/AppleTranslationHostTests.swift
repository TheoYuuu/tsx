import AppKit
import SwiftUI
import XCTest
@testable import TranslateX

@MainActor
final class AppleTranslationHostTests: XCTestCase {
    func testScreenshotLabelsCompleteInTheShippingQuickPanel() async throws {
        guard await LanguageCatalog.status(source: "en", target: "zh-Hans") == .installed else {
            throw XCTSkip("This integration test uses installed English/Chinese resources and never downloads languages")
        }
        let inputMonitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(inputMonitor) }
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 300, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let labels = ["Datacenter", "Mobile", "Web Unblocker"]
        let document = ScreenshotDocument(image: image, regions: labels.enumerated().map { index, label in
            ScreenshotRegion(id: UUID(), text: label,
                             bounds: CGRect(x: 0.1, y: 0.8 - Double(index) * 0.3, width: 0.6, height: 0.1),
                             confidence: 1, role: .paragraph, separator: index == 0 ? "" : "\n\n")
        })
        windows.prepareQuickTranslation()
        windows.quickModel.beginRecognition(image: image)
        windows.showQuick(source: nil)
        try await Task.sleep(for: .milliseconds(100))
        // Guard the real framework call: a regression must not download a new
        // language during this test or block on its system permission sheet.
        XCTAssertEqual(TranslationModel.detectLanguage(document.sourceText, target: "zh-Hans"), "en")
        guard TranslationModel.detectLanguage(document.sourceText, target: "zh-Hans") == "en" else { return }
        windows.quickModel.submitCapturedDocument(document, serviceRevision: windows.services.revision)
        XCTAssertEqual(windows.quickModel.request?.source, "en")
        try await assertCompleted(windows.quickModel)
        XCTAssertEqual(windows.quickModel.screenshot?.translations.count, labels.count)
        // Closing a completed quick panel clears its live request, while the
        // translated result keeps the language actually used by the session.
        XCTAssertEqual(windows.quickModel.result?.source, "en")
        XCTAssertEqual(windows.quickModel.source, "auto")
    }

    func testViewOwnedSessionCompletesSuccessiveRequestsAfterMountAndCancellation() async throws {
        guard await LanguageCatalog.status(source: "en", target: "zh-Hans") == .installed else {
            throw XCTSkip("This integration test uses installed English/Chinese resources and never downloads languages")
        }
        let model = TranslationModel()
        model.source = "en"
        model.target = "zh-Hans"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AppleTranslationHost(model: model))
        window.orderFront(nil)
        defer { model.cancel(); window.close() }
        try await Task.sleep(for: .milliseconds(150))

        for text in ["A quiet window helps you focus.", "The library opens in the morning."] {
            model.text = text
            model.submit()
            try await assertCompleted(model)
        }

        model.text = "This request is cancelled before the view updates."
        model.submit()
        model.cancel()
        model.text = "Keep the original image."
        model.submit()
        try await assertCompleted(model)
    }

    private func assertCompleted(_ model: TranslationModel,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if !model.isBusy { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.phase, .completed, file: file, line: line)
        _ = try XCTUnwrap(model.result, "View-owned Apple session did not complete", file: file, line: line)
        XCTAssertFalse(model.translatedText.isEmpty, file: file, line: line)
        XCTAssertNotEqual(model.translatedText, model.text, file: file, line: line)
    }
}

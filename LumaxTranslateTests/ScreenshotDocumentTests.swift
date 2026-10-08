import AppKit
import XCTest
@preconcurrency import Translation
@testable import LumaxTranslate

@MainActor
final class ScreenshotDocumentTests: XCTestCase {
    func testWrapsBecomeParagraphsButHeadingsListsAndPriceRowsStaySeparate() throws {
        let document = try ScreenshotDocument(image: image(), blocks: [
            block("A clear heading", y: 0.88, h: 0.08),
            block("A wrapped paragraph begins", y: 0.75), block("and continues here.", y: 0.69),
            block("• Keep the source", y: 0.55), block("• Keep the structure", y: 0.49),
            block("Coffee", y: 0.3, w: 0.3), block("$4.50", x: 0.7, y: 0.3, w: 0.2),
            block("Tea", y: 0.24, w: 0.3), block("$3.00", x: 0.7, y: 0.24, w: 0.2)
        ])
        XCTAssertEqual(document.regions.map(\.text), ["A clear heading", "A wrapped paragraph begins and continues here.",
            "• Keep the source", "• Keep the structure", "Coffee", "$4.50", "Tea", "$3.00"])
        XCTAssertEqual(document.regions.map(\.role), [.heading, .paragraph, .listItem, .listItem, .paragraph, .price, .paragraph, .price])
        XCTAssertTrue(document.sourceText.contains("source\n•"))
        XCTAssertTrue(document.sourceText.contains("Coffee\t$4.50\n\nTea"))
        XCTAssertEqual(Set(document.regions.map(\.id)).count, document.regions.count)
    }

    func testCJKVisualWrapHasNoArtificialSpacesAndKeepsBoundsAndConfidence() throws {
        let blocks = [block("阅读清晰的文字", y: 0.85), OCRTextBlock(text: "让理解更轻松", bounds: CGRect(x: 0.1, y: 0.79, width: 0.65, height: 0.04), confidence: 0.42)]
        let document = try ScreenshotDocument(image: image(), blocks: blocks)
        XCTAssertEqual(document.regions.count, 1)
        XCTAssertEqual(document.sourceText, "阅读清晰的文字让理解更轻松")
        XCTAssertEqual(document.regions[0].bounds, blocks[0].bounds.union(blocks[1].bounds))
        XCTAssertEqual(document.regions[0].confidence, 0.42)
        XCTAssertEqual(document.regions[0].lineBounds.count, blocks.count)
        for (actual, expected) in zip(document.regions[0].lineBounds, blocks.map(\.bounds)) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.000001)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.000001)
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.000001)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.000001)
        }
    }

    func testQuotedItemsKeepTheirBreaksAndWrappedContinuationBelongsToItsItem() throws {
        let document = try ScreenshotDocument(image: image(), blocks: [
            block("> A quoted item starts here", y: 0.9), block("and wraps onto this line.", y: 0.84),
            block("> Another quoted item", y: 0.78), block("A final paragraph.", y: 0.5)
        ])
        XCTAssertEqual(document.regions.map(\.text), ["> A quoted item starts here and wraps onto this line.", "> Another quoted item", "A final paragraph."])
        XCTAssertEqual(document.regions.map(\.role), [.listItem, .listItem, .paragraph])
        XCTAssertEqual(document.regions.map { $0.lineBounds.count }, [2, 1, 1])
        XCTAssertTrue(document.sourceText.contains("line.\n> Another"))
    }

    func testOriginalImageParagraphFontFollowsItsLinesAndUsesMoreThanTwoLines() throws {
        let rows = (0..<6).map { block("A line in a long paragraph.", y: 0.9 - Double($0) * 0.06) }
        let document = try ScreenshotDocument(image: image(), blocks: rows)
        let paragraph = try XCTUnwrap(document.regions.first)
        XCTAssertEqual(paragraph.lineBounds.count, 6)
        let oneLine = try ScreenshotDocument(image: image(), blocks: [rows[0]]).regions[0]
        let size = CGSize(width: 600, height: 400)
        let metrics = ScreenshotOverlayMetrics(region: paragraph, imageSize: size)
        let single = ScreenshotOverlayMetrics(region: oneLine, imageSize: size)
        XCTAssertEqual(metrics.fontSize, single.fontSize, accuracy: 0.01, "Joining wraps must not enlarge the paragraph font")
        XCTAssertGreaterThan(metrics.lineLimit, 2, "The image must use its available paragraph area")
        XCTAssertLessThanOrEqual(metrics.lineSpacing, metrics.fontSize * 0.45)
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(metrics.frame))
        let smaller = ScreenshotOverlayMetrics(region: paragraph, imageSize: CGSize(width: 300, height: 200))
        XCTAssertLessThan(smaller.fontSize, metrics.fontSize, "Screenshot zoom scales the original line metrics")
        XCTAssertEqual(smaller.frame.midY, metrics.frame.midY / 2, accuracy: 1)
    }

    func testColumnBoundaryAndIndentationDoNotMergeUnrelatedText() throws {
        let document = try ScreenshotDocument(image: image(), blocks: [
            block("Left one", y: 0.9, w: 0.25), block("Left two", y: 0.84, w: 0.25),
            block("Right one", x: 0.6, y: 0.9, w: 0.25), block("Right two", x: 0.6, y: 0.84, w: 0.25)
        ])
        XCTAssertEqual(document.regions.map(\.text), ["Left one Left two", "Right one Right two"])
        XCTAssertEqual(document.regions[1].separator, "\n\n")
        let indented = try ScreenshotDocument(image: image(), blocks: [block("First item", y: 0.9), block("Indented item", x: 0.2, y: 0.84)])
        XCTAssertEqual(indented.regions.count, 2)
    }

    func testFittingUsesBothDimensionsAndNormalizedCoordinatesRemainStable() {
        let original = CGSize(width: 380, height: 490)
        let narrow = ScreenshotDocument.fittedSize(image: original, available: CGSize(width: 200, height: 200))
        XCTAssertEqual(narrow.height, 200, accuracy: 0.01)
        XCTAssertEqual(narrow.width / narrow.height, original.width / original.height, accuracy: 0.0001)
        let zoomed = ScreenshotDocument.fittedSize(image: original, available: CGSize(width: 200, height: 200), zoom: 2)
        XCTAssertEqual(zoomed.width, narrow.width * 2)
        let box = CGRect(x: 0.1, y: 0.7, width: 0.3, height: 0.1)
        let rect = ScreenshotDocument.displayBounds(box, in: CGSize(width: 100, height: 200))
        XCTAssertEqual(rect.minX, 10, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 40, accuracy: 0.0001)
        XCTAssertEqual(rect.size, CGSize(width: 30, height: 20))
        XCTAssertEqual(ScreenshotDocument.fittedSize(image: .zero, available: original), .zero)
    }

    func testEachRegionUsesStableRequestIDAndLongResponseKeepsFullText() async throws {
        let model = TranslationModel()
        let document = try document()
        model.submitCapturedDocument(document, serviceRevision: 0)
        let request = try XCTUnwrap(model.request)
        let provider = RecordingRegionProvider()
        await model.run(request, provider: provider)
        XCTAssertEqual(provider.requests.map(\.id), document.regions.prefix(2).map(\.id))
        XCTAssertEqual(provider.requests.map(\.text), document.regions.prefix(2).map(\.text))
        XCTAssertEqual(model.screenshot?.translations[document.regions[2].id], "$4.50")
        XCTAssertTrue(model.translatedText.contains(provider.longOutput))
        XCTAssertEqual(model.screenshot?.translatedText, model.translatedText)
        XCTAssertEqual(model.result?.text, model.translatedText)
        XCTAssertEqual(model.phase, .completed)
    }

    func testNumericScreenshotCopiesLocallyWithoutRequestAndKeepsRegionMap() throws {
        let document = try ScreenshotDocument(image: image(), blocks: [block("123.45", y: 0.8)])
        let model = TranslationModel()
        model.submitCapturedDocument(document, serviceRevision: 0)
        XCTAssertNil(model.request)
        XCTAssertEqual(model.translatedText, "123.45")
        XCTAssertEqual(model.screenshot?.translations[document.regions[0].id], "123.45")
        XCTAssertEqual(model.phase, .unchanged)
    }

    func testFailedLaterRegionRetainsEarlierTranslationWithoutFalseSuccess() async throws {
        let model = TranslationModel()
        let document = try document()
        model.submitCapturedDocument(document, serviceRevision: 0)
        let provider = RecordingRegionProvider(failOnCall: 2)
        await model.run(try XCTUnwrap(model.request), provider: provider)
        XCTAssertNil(model.result)
        XCTAssertEqual(model.screenshot?.translations.count, 1)
        XCTAssertEqual(model.partialSide, .target)
        XCTAssertTrue(model.hasTranslationFailure)
        XCTAssertEqual(model.screenshot?.id, document.id)
        XCTAssertTrue(model.undoWorkspaceChange())
        XCTAssertEqual(model.screenshot?.translations.count, 0)
    }

    func testStopAndLateResultDoNotModifyMappedRegions() async throws {
        let model = TranslationModel()
        let document = try document()
        model.submitCapturedDocument(document, serviceRevision: 0)
        let gate = RegionGate()
        let request = try XCTUnwrap(model.request)
        let task = Task { await model.run(request, provider: gate) }
        await waitFor(gate)
        model.cancel()
        gate.complete()
        await task.value
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertEqual(model.screenshot?.translations.count, 0)
        XCTAssertNil(model.result)
    }

    func testEditingRegionRejectsOldResponseAndKeepsPixelMapping() async throws {
        let model = TranslationModel()
        let document = try document()
        model.submitCapturedDocument(document, serviceRevision: 0)
        let gate = RegionGate()
        let request = try XCTUnwrap(model.request)
        let task = Task { await model.run(request, provider: gate) }
        await waitFor(gate)
        model.editScreenshotRegion(document.regions[0].id, text: "A newly edited paragraph.", side: .source)
        gate.complete()
        await task.value
        XCTAssertEqual(model.screenshot?.regions[0].bounds, document.regions[0].bounds)
        XCTAssertEqual(model.screenshot?.regions[0].text, "A newly edited paragraph.")
        XCTAssertTrue(model.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNil(model.result)
    }

    func testOutputCorrectionsUndoAndHandoffRetainImageAndFullRegions() async throws {
        let document = try document()
        let model = TranslationModel()
        model.submitCapturedDocument(document, serviceRevision: 0)
        await model.run(try XCTUnwrap(model.request), provider: RecordingRegionProvider())
        let before = model.translatedText
        model.editScreenshotRegion(document.regions[0].id, text: "完整手动修改的译文", side: .target)
        XCTAssertNil(model.request, "Corrections do not trigger backward image translation")
        XCTAssertTrue(model.translatedText.contains("完整手动修改的译文"))
        let main = TranslationModel()
        main.acceptHandoff(model.makeHandoff())
        XCTAssertEqual(main.screenshot, model.screenshot)
        XCTAssertEqual(main.screenshot?.image.width, document.image.width)
        XCTAssertNil(main.result, "An edited output is not a verified provider result")
        XCTAssertTrue(model.undoWorkspaceChange())
        XCTAssertEqual(model.translatedText, before)
        XCTAssertTrue(model.redoWorkspaceChange())
        XCTAssertTrue(model.translatedText.contains("完整手动修改的译文"))
        model.clear()
        XCTAssertNil(model.screenshot)
        XCTAssertTrue(model.undoWorkspaceChange())
        XCTAssertEqual(model.screenshot?.id, document.id)
    }

    func testRecognitionFailureKeepsOriginalImageAndCanBeClearedOrHandedOff() {
        let model = TranslationModel()
        let original = image()
        model.beginRecognition(image: original)
        XCTAssertEqual(model.phase, .recognizing)
        XCTAssertTrue(model.showsQuickWorkspace)
        XCTAssertTrue(model.canClear)
        model.fail("Recognition failed")
        let main = TranslationModel()
        main.acceptHandoff(model.makeHandoff())
        XCTAssertEqual(main.screenshot?.id, model.screenshot?.id)
        XCTAssertTrue(main.hasTranslationFailure)
        model.clear()
        XCTAssertNil(model.screenshot)
        XCTAssertTrue(model.undoWorkspaceChange())
        XCTAssertEqual(model.screenshot?.image.width, original.width)
    }

    func testRealVisionDocumentRetainsTextConfidenceAndValidCoordinates() async throws {
        let document = try await OCRService().recognizeDocument(image(lines: ["A clear heading", "Read the original text.", "Keep each paragraph.", "$4.50"]))
        XCTAssertTrue(document.sourceText.contains("A clear heading"))
        XCTAssertTrue(document.sourceText.contains("$4.50"))
        XCTAssertGreaterThan(document.regions.count, 1)
        for region in document.regions {
            XCTAssertGreaterThan(region.confidence, 0)
            XCTAssertLessThanOrEqual(region.bounds.maxX, 1)
            XCTAssertLessThanOrEqual(region.bounds.maxY, 1)
            XCTAssertGreaterThan(region.bounds.width, 0)
        }
    }

    func testInstalledAppleTranslatesRealVisionRegions() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Installed-session QA requires macOS 26; shipping uses its view-owned session on macOS 15") }
        guard await LanguageCatalog.status(source: "en", target: "zh-Hans") == .installed else { throw XCTSkip("English/Chinese resources are not installed; this test never downloads files") }
        let document = try await OCRService().recognizeDocument(image(lines: ["A quiet reading room", "Keep the original image.", "Read a clear paragraph.", "$4.50"]))
        let model = TranslationModel()
        model.source = "en"
        model.submitCapturedDocument(document, serviceRevision: 0)
        let session = TranslationSession(installedSource: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
        await model.run(try XCTUnwrap(model.request), provider: AppleLocalTranslationProvider(session: session))
        XCTAssertEqual(model.phase, .completed)
        XCTAssertNotNil(model.result)
        XCTAssertEqual(model.screenshot?.translations.count, document.regions.count)
        XCTAssertTrue(model.translatedText.contains("$4.50"))
        XCTAssertTrue(model.translatedText.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) })
        XCTAssertNotEqual(model.translatedText, document.sourceText)
    }

    func testStaleCaptureKeepsImageButDoesNotSubmit() throws {
        let model = TranslationModel()
        let document = try document()
        model.submitCapturedDocument(document, serviceRevision: -1)
        XCTAssertTrue(model.hasTranslationFailure)
        XCTAssertNil(model.request)
        XCTAssertEqual(model.screenshot?.id, document.id)
        XCTAssertEqual(model.text, document.sourceText)
    }

    func testCompositionDefersScreenshotAutomaticRequest() async throws {
        let model = TranslationModel(automaticallyTranslates: true, updateInterval: .milliseconds(1))
        let document = try document()
        model.submitCapturedDocument(document, serviceRevision: 0)
        model.editScreenshotRegion(document.regions[0].id, text: "An unfinished edit", side: .source, isComposing: true)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.phase, .composing)
        XCTAssertNil(model.request)
        model.editScreenshotRegion(document.regions[0].id, text: "An unfinished edit", side: .source, isComposing: false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(model.request)
        XCTAssertTrue(model.request?.text.contains("An unfinished edit") == true)
        model.cancel()
    }

    func testSelectedRemoteFactoryReceivesOnlyMappedTextAndSuppressesWholeStreamEcho() async throws {
        let domain = "TSX.CaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = TranslationServiceStore(defaults: defaults, credentials: CaptureCredentials())
        var config = TranslationServiceConfiguration(kind: .openAICompatible)
        config.model = "constructed-capture-test-model"
        config.endpoint = "https://example.invalid/v1"
        try store.save(config, apiKey: nil)
        try store.select(config.id)
        let provider = RecordingRegionProvider()
        var receivedConfiguration: TranslationServiceConfiguration?
        let model = TranslationModel(services: store, remoteProvider: { config, _, partial in
            receivedConfiguration = config
            partial("This whole-stream echo must not replace regional output")
            return provider
        })
        let document = try document()
        model.submitCapturedDocument(document, serviceRevision: model.serviceRevision)
        let deadline = Date().addingTimeInterval(2)
        while model.phase == .translating, Date() < deadline { await Task.yield() }
        XCTAssertEqual(model.phase, .completed)
        XCTAssertEqual(receivedConfiguration?.id, config.id)
        XCTAssertEqual(provider.requests.map(\.text), document.regions.prefix(2).map(\.text))
        XCTAssertFalse(model.translatedText.contains("whole-stream echo"))
        XCTAssertEqual(model.screenshot?.translations.count, document.regions.count)
    }

    func testClearStopAndReplacementCancelRecognitionButDeliveryDoesNot() throws {
        let model = TranslationModel()
        var cancellations = 0
        model.beginRecognition(image: image(), cancellation: { cancellations += 1 })
        model.clear()
        XCTAssertEqual(cancellations, 1)
        model.beginRecognition(image: image(), cancellation: { cancellations += 1 })
        model.cancel()
        XCTAssertEqual(cancellations, 2)
        model.beginRecognition(image: image(), cancellation: { cancellations += 1 })
        model.beginRecognition(image: image(), cancellation: { cancellations += 1 })
        XCTAssertEqual(cancellations, 3)
        model.target = "en"
        XCTAssertEqual(model.phase, .recognizing, "Changing target during OCR does not abandon the image")
        model.source = "en"
        model.target = "zh-Hans"
        model.submitCapturedDocument(try document(), serviceRevision: 0)
        XCTAssertEqual(cancellations, 3, "Delivery releases the cancel callback without cancelling itself")
        model.cancel()
        XCTAssertEqual(cancellations, 3)
    }

    func testLightFiniteConfirmationsStopAndIdleNeverAnimates() {
        for phase in [TranslationPhase.empty, .composing, .cancelled] {
            let style = TranslationStatusLightStyle(phase: phase)
            XCTAssertFalse(style.breathes)
            XCTAssertEqual(style.intensity(elapsed: 0.5), 0)
        }
        for style in [TranslationStatusLightStyle.waiting, .recognizing, .translating] {
            XCTAssertGreaterThan(style.intensity(elapsed: style.period / 2), 0.9)
            XCTAssertEqual(style.intensity(elapsed: 0.4, reduced: true), 0)
        }
        XCTAssertEqual(TranslationStatusLightStyle.updated.intensity(elapsed: 1), 0)
        XCTAssertEqual(TranslationStatusLightStyle.failed.intensity(elapsed: 1.6), 0)
    }

    private func waitFor(_ gate: RegionGate) async {
        let deadline = Date().addingTimeInterval(2)
        while gate.continuation == nil, Date() < deadline { await Task.yield() }
        XCTAssertNotNil(gate.continuation)
    }
    private func document() throws -> ScreenshotDocument {
        try ScreenshotDocument(image: image(), blocks: [block("A clear first paragraph.", y: 0.9),
            block("Another complete paragraph.", y: 0.6), block("$4.50", y: 0.2)])
    }
    private func block(_ text: String, x: CGFloat = 0.1, y: CGFloat, w: CGFloat = 0.65, h: CGFloat = 0.04) -> OCRTextBlock {
        .init(text: text, bounds: CGRect(x: x, y: y, width: w, height: h))
    }
    private func image(lines: [String] = []) -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 70, y: 670 - i * 150), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage!
    }
}

@MainActor private final class RecordingRegionProvider: TranslationProvider {
    var requests: [TranslationRequest] = []
    let failOnCall: Int?
    let longOutput = String(repeating: "完整的区域译文不会因为原框很小而被丢弃。", count: 15)
    init(failOnCall: Int? = nil) { self.failOnCall = failOnCall }
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requests.append(request)
        if requests.count == failOnCall { throw RemoteTranslationError.offline }
        return .init(text: longOutput, source: request.source, target: request.target)
    }
}
@MainActor private final class RegionGate: TranslationProvider {
    var continuation: CheckedContinuation<TranslationResult, any Error>?
    var request: TranslationRequest?
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        self.request = request
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func complete() {
        continuation?.resume(returning: .init(text: "Late output", source: request?.source, target: request?.target ?? "zh-Hans"))
        continuation = nil
    }
}

@MainActor private final class CaptureCredentials: TranslationCredentialStore {
    func credential(for id: UUID) throws -> TranslationServiceCredential? { nil }
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { }
    func removeCredential(for id: UUID) throws { }
}

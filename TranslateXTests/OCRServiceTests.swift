import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class OCRServiceTests: XCTestCase {
    func testLinesFollowTopToBottomOrderAndKeepParagraphGap() throws {
        let blocks = [
            block("New paragraph", x: 0.1, y: 0.55),
            block("Second line", x: 0.1, y: 0.82),
            block("First line", x: 0.1, y: 0.9)
        ]
        XCTAssertEqual(try OCRReadingOrder.text(from: blocks), "First line\nSecond line\n\nNew paragraph")
    }

    func testAlignedFragmentsRemainOnOneLine() throws {
        let blocks = [
            block("world", x: 0.52, y: 0.898, width: 0.22),
            block("Hello", x: 0.1, y: 0.9, width: 0.22)
        ]
        XCTAssertEqual(try OCRReadingOrder.text(from: blocks), "Hello world")
    }

    func testClearColumnsReadDownLeftThenDownRight() throws {
        let blocks = [
            block("Right second", x: 0.6, y: 0.82, width: 0.3),
            block("Left first", x: 0.1, y: 0.9, width: 0.3),
            block("Right first", x: 0.6, y: 0.9, width: 0.3),
            block("Left second", x: 0.1, y: 0.82, width: 0.3)
        ]
        XCTAssertEqual(try OCRReadingOrder.text(from: blocks), "Left first\nLeft second\n\nRight first\nRight second")
    }

    func testFullWidthHeadingPrecedesTwoColumns() throws {
        let blocks = [
            block("Heading", x: 0.1, y: 0.92, width: 0.8),
            block("Left first", x: 0.1, y: 0.78, width: 0.3),
            block("Left second", x: 0.1, y: 0.70, width: 0.3),
            block("Right first", x: 0.6, y: 0.78, width: 0.3),
            block("Right second", x: 0.6, y: 0.70, width: 0.3)
        ]
        XCTAssertEqual(try OCRReadingOrder.text(from: blocks), "Heading\n\nLeft first\nLeft second\n\nRight first\nRight second")
    }

    func testFullWidthFooterFollowsTwoColumns() throws {
        let blocks = [
            block("Left first", x: 0.1, y: 0.9, width: 0.3),
            block("Left second", x: 0.1, y: 0.82, width: 0.3),
            block("Right first", x: 0.6, y: 0.9, width: 0.3),
            block("Right second", x: 0.6, y: 0.82, width: 0.3),
            block("Footer", x: 0.1, y: 0.65, width: 0.8)
        ]
        XCTAssertEqual(try OCRReadingOrder.text(from: blocks), "Left first\nLeft second\n\nRight first\nRight second\n\nFooter")
    }

    func testStaggeredParagraphsAreNotMistakenForColumns() throws {
        let blocks = [
            block("Upper one", x: 0.1, y: 0.9, width: 0.3),
            block("Upper two", x: 0.1, y: 0.82, width: 0.3),
            block("Lower one", x: 0.6, y: 0.5, width: 0.3),
            block("Lower two", x: 0.6, y: 0.42, width: 0.3)
        ]
        XCTAssertEqual(try OCRReadingOrder.text(from: blocks), "Upper one\nUpper two\n\nLower one\nLower two")
    }

    func testHeadingAndFooterCanSurroundTwoColumns() throws {
        let blocks = [
            block("Heading", x: 0.1, y: 0.92, width: 0.8),
            block("Left first", x: 0.1, y: 0.78, width: 0.3),
            block("Left second", x: 0.1, y: 0.70, width: 0.3),
            block("Right first", x: 0.6, y: 0.78, width: 0.3),
            block("Right second", x: 0.6, y: 0.70, width: 0.3),
            block("Footer", x: 0.1, y: 0.55, width: 0.8)
        ]
        XCTAssertEqual(try OCRReadingOrder.text(from: blocks), "Heading\n\nLeft first\nLeft second\n\nRight first\nRight second\n\nFooter")
    }

    func testInvalidBoundsAndWhitespaceDoNotProduceText() {
        let blocks = [
            block(" \n ", x: 0.1, y: 0.9),
            block("Outside", x: 2, y: 2),
            block("Zero", x: 0, y: 0, width: 0),
            block("Invalid", x: .nan, y: 0)
        ]
        XCTAssertThrowsError(try OCRReadingOrder.text(from: blocks)) { XCTAssertEqual($0 as? OCRError, .noText) }
    }

    func testTextLimitIncludesAddedLineSeparators() throws {
        let maximum = SelectionText.maximumLength
        XCTAssertEqual(try OCRReadingOrder.text(from: [block(String(repeating: "a", count: maximum), x: 0.1, y: 0.9)]).count, maximum)
        let blocks = [
            block(String(repeating: "a", count: maximum / 2), x: 0.1, y: 0.9),
            block(String(repeating: "b", count: maximum / 2), x: 0.1, y: 0.82)
        ]
        XCTAssertThrowsError(try OCRReadingOrder.text(from: blocks)) { XCTAssertEqual($0 as? OCRError, .tooMuchText) }
    }

    func testVisionRecognizesSyntheticEnglishAndChineseLines() async throws {
        let image = try syntheticImage(lines: ["Clear words. Quiet focus.", "你好，世界"])
        let text = try await OCRService().recognize(image)
        XCTAssertTrue(text.contains("Clear words"), text)
        XCTAssertTrue(text.contains("Quiet focus"), text)
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        XCTAssertTrue(compact.contains("你好世界"), text)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Clear")?.lowerBound), try XCTUnwrap(text.range(of: "你好")?.lowerBound))
    }

    func testVisionRejectsBlankSyntheticImage() async throws {
        let image = try syntheticImage(lines: [])
        do {
            _ = try await OCRService().recognize(image)
            XCTFail("A blank image must not invent recognized text")
        } catch {
            XCTAssertEqual(error as? OCRError, .noText)
        }
    }

    func testCancelledRequestCannotReturnRecognizedText() async throws {
        let image = try syntheticImage(lines: ["A cancelled request."])
        let task = Task { try await OCRService().recognize(image) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationReachesSuspendedRecognition() async throws {
        let gate = ControlledRecognition(cooperatesWithCancellation: true)
        let service = OCRService { _ in try await gate.recognize() }
        let image = try syntheticImage(lines: [])
        let task = Task { try await service.recognize(image) }
        defer { task.cancel() }
        try await gate.waitForCalls(1)
        task.cancel()
        await expectCancellation(task)
        XCTAssertTrue(gate.observedCancellation)
    }

    func testCancelledRecognitionRejectsLateSuccessfulText() async throws {
        let gate = ControlledRecognition()
        let service = OCRService { _ in try await gate.recognize() }
        let image = try syntheticImage(lines: [])
        let task = Task { try await service.recognize(image) }
        defer { task.cancel(); gate.releaseAll() }
        try await gate.waitForCalls(1)
        task.cancel()
        gate.finish(call: 0, result: .success([block("Old text", x: 0.1, y: 0.8)]))
        await expectCancellation(task)
    }

    func testCancelledRecognitionDoesNotBecomeAnErrorWhenLateWorkFails() async throws {
        let gate = ControlledRecognition()
        let service = OCRService { _ in try await gate.recognize() }
        let image = try syntheticImage(lines: [])
        let task = Task { try await service.recognize(image) }
        defer { task.cancel(); gate.releaseAll() }
        try await gate.waitForCalls(1)
        task.cancel()
        gate.finish(call: 0, result: .failure(OCRError.recognitionFailed))
        await expectCancellation(task)
    }

    func testReplacementFinishesWithoutWaitingForCancelledRecognition() async throws {
        let gate = ControlledRecognition()
        let service = OCRService { _ in try await gate.recognize() }
        let image = try syntheticImage(lines: [])
        let old = Task { try await service.recognize(image) }
        defer { old.cancel(); gate.releaseAll() }
        try await gate.waitForCalls(1)
        old.cancel()
        let replacement = Task { try await service.recognize(image) }
        defer { replacement.cancel() }
        try await gate.waitForCalls(2)
        gate.finish(call: 1, result: .success([block("New text", x: 0.1, y: 0.8)]))
        let text = try await replacement.value
        XCTAssertEqual(text, "New text")
        XCTAssertTrue(gate.hasPending(call: 0), "New work must finish before the old engine callback")
        gate.finish(call: 0, result: .success([block("Old text", x: 0.1, y: 0.8)]))
        await expectCancellation(old)
    }

    func testRecognitionFailureDoesNotExposeSystemErrorDetails() async throws {
        let service = OCRService { _ in
            throw NSError(domain: "OCRFixture", code: 17, userInfo: [NSLocalizedDescriptionKey: "Synthetic private detail"])
        }
        do {
            _ = try await service.recognize(syntheticImage(lines: []))
            XCTFail("Expected the fixed recognition error")
        } catch {
            XCTAssertEqual(error as? OCRError, .recognitionFailed)
        }
    }

    private func expectCancellation(_ task: Task<String, any Error>) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled recognition must not deliver text")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func block(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 0.65) -> OCRTextBlock {
        OCRTextBlock(text: text, bounds: CGRect(x: x, y: y, width: width, height: 0.05))
    }

    /// Test pixels are constructed entirely in memory and never include user content.
    private func syntheticImage(lines: [String]) throws -> CGImage {
        let width = 1_200
        let height = 400
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let font = NSFont.systemFont(ofSize: 54, weight: .regular)
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(
                at: NSPoint(x: 55, y: 270 - index * 100),
                withAttributes: [.font: font, .foregroundColor: NSColor.black]
            )
        }
        return try XCTUnwrap(bitmap.cgImage)
    }
}

/// A suspended engine deliberately permits late callbacks, independently of Task cancellation.
@MainActor
private final class ControlledRecognition {
    private let cooperatesWithCancellation: Bool
    private var pending: [Int: CheckedContinuation<[OCRTextBlock], any Error>] = [:]
    private(set) var calls = 0
    private(set) var observedCancellation = false

    init(cooperatesWithCancellation: Bool = false) {
        self.cooperatesWithCancellation = cooperatesWithCancellation
    }

    func recognize() async throws -> [OCRTextBlock] {
        let call = calls
        calls += 1
        if cooperatesWithCancellation {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { observedCancellation = Task.isCancelled; throw error }
            return []
        }
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }

    func waitForCalls(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while calls < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard calls >= count else {
            XCTFail("Recognition did not reach the controlled engine")
            throw OCRError.recognitionFailed
        }
    }

    func hasPending(call: Int) -> Bool { pending[call] != nil }

    func finish(call: Int, result: Result<[OCRTextBlock], any Error>) {
        pending.removeValue(forKey: call)?.resume(with: result)
    }

    func releaseAll() {
        let remaining = pending.values
        pending.removeAll()
        for continuation in remaining { continuation.resume(throwing: CancellationError()) }
    }
}

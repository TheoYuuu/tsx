import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class CaptureLayoutTests: XCTestCase {
    func testUnchangedLayoutAcceptsReorderedCaptureMetadataAndIgnoresUnselectedMirror() throws {
        let snapshot = layout()
        let center = NotificationCenter()
        let guardValue = try CaptureLayoutGuard(notificationCenter: center, currentLayout: { snapshot })
        defer { guardValue.stop() }
        try guardValue.validate(referenceTop: 900)
        let mirror = CaptureDisplay(id: 3, frame: snapshot.displays[0].frame, scale: 1)
        let accepted = try guardValue.validatedDisplays(snapshot.displays.reversed() + [mirror])
        XCTAssertEqual(accepted, snapshot.displays)
        XCTAssertFalse(accepted.contains { $0.id == mirror.id })
    }

    func testChangedReferenceTopRejectsSelectionBeforePixelsAreRead() throws {
        let snapshot = layout()
        let guardValue = try CaptureLayoutGuard(notificationCenter: NotificationCenter(), currentLayout: { snapshot })
        defer { guardValue.stop() }
        assertLayoutChanged { try guardValue.validate(referenceTop: 1080) }
    }

    func testPrimaryScreenResolutionScaleAndAttachmentChangesInvalidateLayout() throws {
        let original = layout()
        let first = original.displays[0]
        let second = original.displays[1]
        let changedLayouts = [
            CaptureLayoutSnapshot(primaryDisplayID: 2, referenceTop: 900, displays: original.displays),
            CaptureLayoutSnapshot(primaryDisplayID: 1, referenceTop: 1080, displays: original.displays),
            CaptureLayoutSnapshot(primaryDisplayID: 1, referenceTop: 900, displays: [
                CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1680, height: 1050), scale: 2), second
            ]),
            CaptureLayoutSnapshot(primaryDisplayID: 1, referenceTop: 900, displays: [
                CaptureDisplay(id: 1, frame: first.frame, scale: 1), second
            ]),
            CaptureLayoutSnapshot(primaryDisplayID: 1, referenceTop: 900, displays: [first]),
            CaptureLayoutSnapshot(primaryDisplayID: 1, referenceTop: 900, displays: original.displays + [
                CaptureDisplay(id: 3, frame: CGRect(x: 1440, y: 0, width: 800, height: 600), scale: 1)
            ])
        ]
        for changed in changedLayouts {
            let source = MutableLayoutSource(original)
            let guardValue = try CaptureLayoutGuard(notificationCenter: NotificationCenter(), currentLayout: source.read)
            defer { guardValue.stop() }
            source.current = changed
            assertLayoutChanged { try guardValue.validate() }
            source.current = original
            assertLayoutChanged { try guardValue.validate() }
        }
    }

    func testNotificationInvalidatesIntentEvenWhenCurrentMetadataHasReturnedToOriginal() throws {
        let snapshot = layout()
        let center = NotificationCenter()
        let guardValue = try CaptureLayoutGuard(notificationCenter: center, currentLayout: { snapshot })
        defer { guardValue.stop() }
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        assertLayoutChanged { try guardValue.validate() }
        assertLayoutChanged { _ = try guardValue.validatedDisplays(snapshot.displays) }
    }

    func testStaleCaptureEnumerationCannotProduceAPlanForChangedOrMissingDisplays() throws {
        let snapshot = layout()
        let first = snapshot.displays[0]
        let second = snapshot.displays[1]
        let candidates = [
            [CaptureDisplay(id: 1, frame: first.frame.offsetBy(dx: 100, dy: 0), scale: first.scale), second],
            [CaptureDisplay(id: 1, frame: first.frame, scale: 1), second],
            [first],
            [first, first, second]
        ]
        for metadata in candidates {
            let guardValue = try CaptureLayoutGuard(notificationCenter: NotificationCenter(), currentLayout: { snapshot })
            defer { guardValue.stop() }
            assertLayoutChanged { _ = try guardValue.validatedDisplays(metadata) }
            assertLayoutChanged { try guardValue.validate() }
        }
    }

    func testUnavailableLayoutDuringCaptureFailsClosed() throws {
        let snapshot = layout()
        let source = MutableLayoutSource(snapshot)
        let guardValue = try CaptureLayoutGuard(notificationCenter: NotificationCenter(), currentLayout: source.read)
        defer { guardValue.stop() }
        source.current = nil
        assertLayoutChanged { try guardValue.validate() }
    }

    func testLayoutChangeDuringSuspendedWorkDiscardsItsLateResult() async throws {
        let snapshot = layout()
        let center = NotificationCenter()
        let guardValue = try CaptureLayoutGuard(notificationCenter: center, currentLayout: { snapshot })
        defer { guardValue.stop() }
        let work = SuspendedLayoutWork()
        var accepted: String?
        let task = Task {
            try guardValue.validate()
            let result = await work.result()
            try guardValue.validate()
            accepted = result
        }
        await work.waitUntilStarted()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        work.complete("A synthetic late OCR result")
        do {
            try await task.value
            XCTFail("Changed screen coordinates must not deliver a late capture or OCR result")
        } catch {
            XCTAssertEqual(error as? CaptureError, .screenConfigurationChanged)
        }
        XCTAssertNil(accepted)
    }

    func testExplicitCancellationWinsOverLayoutFailureAndDoesNotAffectReplacement() async throws {
        let snapshot = layout()
        let center = NotificationCenter()
        let old = try CaptureLayoutGuard(notificationCenter: center, currentLayout: { snapshot })
        let work = SuspendedLayoutWork()
        let task = Task {
            try old.validate()
            _ = await work.result()
            try old.validate()
        }
        await work.waitUntilStarted()
        task.cancel()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        old.stop()
        let replacement = try CaptureLayoutGuard(notificationCenter: center, currentLayout: { snapshot })
        defer { replacement.stop() }
        work.complete("A cancelled capture")
        do {
            try await task.value
            XCTFail("A cancelled old request must not deliver a layout error or result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try replacement.validate()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        assertLayoutChanged { try replacement.validate() }
    }

    func testFinishedGuardCannotBeUsedForAnotherCaptureAndReleasesOwnership() throws {
        let snapshot = layout()
        let center = NotificationCenter()
        weak var released: CaptureLayoutGuard?
        do {
            let guardValue = try CaptureLayoutGuard(notificationCenter: center, currentLayout: { snapshot })
            released = guardValue
            guardValue.stop()
            XCTAssertThrowsError(try guardValue.validate()) { XCTAssertTrue($0 is CancellationError) }
        }
        XCTAssertNil(released)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func layout() -> CaptureLayoutSnapshot {
        CaptureLayoutSnapshot(primaryDisplayID: 1, referenceTop: 900, displays: [
            CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2),
            CaptureDisplay(id: 2, frame: CGRect(x: -1920, y: -180, width: 1920, height: 1080), scale: 1)
        ])
    }

    private func assertLayoutChanged(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureError, .screenConfigurationChanged, file: file, line: line)
        }
    }
}

@MainActor
private final class MutableLayoutSource {
    var current: CaptureLayoutSnapshot?
    init(_ snapshot: CaptureLayoutSnapshot) { current = snapshot }
    func read() throws -> CaptureLayoutSnapshot {
        guard let current else { throw CaptureError.noDisplays }
        return current
    }
}

@MainActor
private final class SuspendedLayoutWork {
    private var continuation: CheckedContinuation<String, Never>?

    func result() async -> String {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        for _ in 0..<500 {
            if continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Synthetic capture did not start")
    }

    func complete(_ value: String) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

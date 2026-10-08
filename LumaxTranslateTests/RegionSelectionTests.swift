import AppKit
import XCTest
@testable import LumaxTranslate

final class RegionSelectionGeometryTests: XCTestCase {
    func testReverseDragAcrossDisplaysUsesGlobalPointsAndNegativeCoordinates() {
        var geometry = RegionSelectionGeometry(screenFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        ])
        geometry.begin(at: CGPoint(x: 700, y: 600))
        geometry.update(to: CGPoint(x: -1000, y: 200))
        XCTAssertEqual(geometry.selection, CGRect(x: -1000, y: 200, width: 1700, height: 400))
        XCTAssertEqual(geometry.finish(at: CGPoint(x: -1200, y: 100)), CGRect(x: -1200, y: 100, width: 1900, height: 500))
        XCTAssertNil(geometry.finish(at: CGPoint(x: -1300, y: 50)), "An extra mouse-up cannot complete the same drag twice")
    }

    func testDragClampsToDesktopWithoutDependingOnPixelScale() {
        var geometry = RegionSelectionGeometry(screenFrames: [CGRect(x: -800, y: 0, width: 1600, height: 900)])
        geometry.begin(at: CGPoint(x: 100.5, y: 200.25))
        let result = geometry.finish(at: CGPoint(x: 2000, y: 1500))
        XCTAssertEqual(result, CGRect(x: 100.5, y: 200.25, width: 699.5, height: 699.75))
    }

    func testTinyDragResetsSoAnotherSelectionCanStart() {
        var geometry = RegionSelectionGeometry(screenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        geometry.begin(at: CGPoint(x: 20, y: 20))
        XCTAssertNil(geometry.finish(at: CGPoint(x: 22, y: 300)))
        XCTAssertNil(geometry.selection)
        XCTAssertNil(geometry.start)
        geometry.begin(at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(geometry.finish(at: CGPoint(x: 200, y: 250)), CGRect(x: 100, y: 100, width: 100, height: 150))
    }

    func testMouseUpAndDragWithoutMouseDownCannotCreateASelection() {
        var geometry = RegionSelectionGeometry(screenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        geometry.update(to: CGPoint(x: 500, y: 500))
        XCTAssertNil(geometry.finish(at: CGPoint(x: 500, y: 500)))
        XCTAssertNil(geometry.selection)
    }

    func testEmptyDesktopAndNonfinitePointerCannotCreateInvalidBounds() {
        var empty = RegionSelectionGeometry(screenFrames: [])
        empty.begin(at: .zero)
        XCTAssertNil(empty.finish(at: CGPoint(x: 100, y: 100)))
        var geometry = RegionSelectionGeometry(screenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 800)])
        geometry.begin(at: CGPoint(x: CGFloat.nan, y: 100))
        XCTAssertNil(geometry.start)
        XCTAssertNil(geometry.selection)
    }
}

@MainActor
final class RegionSelectionEventTests: XCTestCase {
    func testAlreadyCancelledTaskDoesNotStartAnOverlaySession() async {
        let controller = RegionSelectionController()
        let task = Task { try await controller.selectRegion() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled selection task must not produce a region")
        } catch is CancellationError {
            XCTAssertFalse(controller.isSelecting)
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        controller.cancel()
        controller.cancel()
        XCTAssertFalse(controller.isSelecting)
    }

    func testDragEventsOutsideOriginatingWindowKeepTheirGlobalCoordinates() async throws {
        _ = NSApplication.shared
        let frame = CGRect(x: -5000, y: -3000, width: 400, height: 300)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = RegionSelectionOverlayView(frame: CGRect(origin: .zero, size: frame.size), screenFrame: frame)
        window.contentView = view
        defer { window.close() }
        var points: [CGPoint] = []
        view.onBegin = { points.append($0) }
        view.onDrag = { points.append($0) }
        view.onEnd = { points.append($0) }

        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 20, y: 30), window: window))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 750, y: -400), window: window))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 800, y: -450), window: window))

        XCTAssertEqual(points, [
            CGPoint(x: -4980, y: -2970),
            CGPoint(x: -4250, y: -3400),
            CGPoint(x: -4200, y: -3450)
        ])
        XCTAssertFalse(window.isVisible, "Constructed input events do not require showing a real overlay")
    }

    func testEscapeAndRightClickRouteCancellationLocally() async throws {
        _ = NSApplication.shared
        let view = RegionSelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), screenFrame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var cancellations = 0
        view.onCancel = { cancellations += 1 }
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        view.keyDown(with: escape)
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        view.rightMouseDown(with: rightClick)
        XCTAssertEqual(cancellations, 2)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
    }
}

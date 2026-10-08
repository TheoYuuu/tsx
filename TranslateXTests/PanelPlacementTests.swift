import XCTest
@testable import TranslateX

final class PanelPlacementTests: XCTestCase {
    func testPanelFitsNegativeCoordinateMonitor() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1050)
        for point in [CGPoint(x: -1919, y: 1049), CGPoint(x: -1, y: 1)] {
            let frame = PanelPlacement.frame(size: CGSize(width: 430, height: 450), anchor: point, visibleFrame: screen)
            XCTAssertTrue(screen.contains(frame))
        }
    }

    func testPanelFitsSmallVisibleArea() {
        let screen = CGRect(x: 100, y: 100, width: 360, height: 400)
        let frame = PanelPlacement.frame(size: CGSize(width: 430, height: 450), anchor: .zero, visibleFrame: screen)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertGreaterThan(frame.height, 0)
    }

    func testResizeKeepsTopLeftWhenTheLargerPanelFits() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let current = CGRect(x: -900, y: 500, width: 392, height: 315)
        let size = CGSize(width: 430, height: 442)
        let result = PanelPlacement.resizingFrame(current: current, size: size, visibleFrame: screen)
        XCTAssertEqual(result.size, size)
        XCTAssertEqual(result.minX, current.minX)
        XCTAssertEqual(result.maxY, current.maxY)
        XCTAssertTrue(screen.contains(result))
    }

    func testResizeClampsHeightOnShortDisplay() {
        let screen = CGRect(x: 100, y: 100, width: 800, height: 400)
        let current = CGRect(x: 150, y: 185, width: 392, height: 315)
        let result = PanelPlacement.resizingFrame(current: current, size: CGSize(width: 430, height: 442), visibleFrame: screen)
        XCTAssertEqual(result.size, CGSize(width: 430, height: 400))
        XCTAssertEqual(result.minX, current.minX)
        XCTAssertEqual(result.maxY, current.maxY)
        XCTAssertEqual(result.minY, screen.minY)
        XCTAssertTrue(screen.contains(result), "Completing OCR must not grow its panel beyond a short display")
    }

    func testResizeClampsWidthOnNarrowDisplay() {
        let screen = CGRect(x: -360, y: 50, width: 360, height: 700)
        let current = CGRect(x: -350, y: 400, width: 340, height: 315)
        let result = PanelPlacement.resizingFrame(current: current, size: CGSize(width: 430, height: 442), visibleFrame: screen)
        XCTAssertEqual(result.size, CGSize(width: 360, height: 442))
        XCTAssertEqual(result.minX, screen.minX)
        XCTAssertEqual(result.maxY, current.maxY)
        XCTAssertTrue(screen.contains(result))
    }

    func testResizeMovesOnlyTheEdgesThatWouldLeaveTheDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let current = CGRect(x: 888, y: 12, width: 392, height: 315)
        let result = PanelPlacement.resizingFrame(current: current, size: CGSize(width: 430, height: 442), visibleFrame: screen)
        XCTAssertEqual(result.size, CGSize(width: 430, height: 442))
        XCTAssertEqual(result.maxX, screen.maxX)
        XCTAssertEqual(result.minY, screen.minY)
        XCTAssertTrue(screen.contains(result))
    }
}

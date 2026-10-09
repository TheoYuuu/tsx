import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class UsageDatePopoverLayoutTests: XCTestCase {
    func testPopoverPrefersBelowAndClampsToPageEdges() {
        let frame = UsageDatePopoverLayout.frame(anchor: CGRect(x: 565, y: 20, width: 130, height: 32),
            contentSize: CGSize(width: 480, height: 450), containerSize: CGSize(width: 715, height: 544))
        XCTAssertEqual(frame.minX, 215)
        XCTAssertEqual(frame.minY, 60)
        XCTAssertLessThanOrEqual(frame.maxX, 703)
        XCTAssertLessThanOrEqual(frame.maxY, 532)
    }

    func testPopoverMovesAboveLowAnchorAndStaysVisibleAfterResize() {
        let frame = UsageDatePopoverLayout.frame(anchor: CGRect(x: 565, y: 490, width: 130, height: 32),
            contentSize: CGSize(width: 480, height: 450), containerSize: CGSize(width: 715, height: 544))
        XCTAssertEqual(frame.maxY, 482)
        for size in [CGSize(width: 715, height: 544), CGSize(width: 905, height: 644)] {
            let fitted = UsageDatePopoverLayout.frame(anchor: CGRect(x: 5, y: 80, width: 100, height: 32),
                contentSize: CGSize(width: 480, height: 480), containerSize: size)
            XCTAssertGreaterThanOrEqual(fitted.minX, 12)
            XCTAssertGreaterThanOrEqual(fitted.minY, 12)
            XCTAssertLessThanOrEqual(fitted.maxX, size.width - 12)
            XCTAssertLessThanOrEqual(fitted.maxY, size.height - 12)
        }
    }

    func testTallCalendarReceivesAnActualViewportHeightWithinSmallContainer() {
        let frame = UsageDatePopoverLayout.frame(anchor: CGRect(x: 500, y: 20, width: 130, height: 32),
            contentSize: CGSize(width: 480, height: 600), containerSize: CGSize(width: 715, height: 400))
        XCTAssertEqual(frame.height, 376)
        XCTAssertEqual(frame.minY, 12)
        XCTAssertEqual(frame.maxY, 388)
    }

    func testNativeDateMenusFitWithRealEightPointGaps() {
        for (values, minimumWidth) in [
            (Array(1900...2026).map(String.init), UsageDatePopoverLayout.yearWidth),
            (Array(1...31).map { String(format: "%02d", $0) }, UsageDatePopoverLayout.monthDayWidth)
        ] {
            let control = LanguageMenuControl()
            control.labelFont = .systemFont(ofSize: 12, weight: .regular)
            control.minimumWidth = minimumWidth
            for value in values {
                control.languages = [.init(id: value, name: value)]
                control.selection = value
                control.refreshTitle()
                XCTAssertLessThanOrEqual(control.intrinsicContentSize.width, minimumWidth,
                                         "Intrinsic width must not eat the visible space between date menus.")
            }
        }
        let controlsAndGaps = UsageDatePopoverLayout.yearWidth + 2 * UsageDatePopoverLayout.monthDayWidth
            + 2 * UsageDatePopoverLayout.componentGap
        let control = LanguageMenuControl()
        let paintedOverflow = control.alignmentRectInsets.left + control.alignmentRectInsets.right
        XCTAssertEqual(UsageDatePopoverLayout.componentGap - paintedOverflow, 8)
        XCTAssertLessThanOrEqual(controlsAndGaps, UsageDatePopoverLayout.endpointContentWidth)
    }
}

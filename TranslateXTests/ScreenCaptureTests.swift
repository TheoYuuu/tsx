import CoreGraphics
import Foundation
import XCTest
@testable import TranslateX

final class ScreenCaptureTests: XCTestCase {
    func testAppKitConversionUsesPrimaryTopAndKeepsNegativeCoordinates() throws {
        let converted = try CaptureGeometry.quartzRect(
            fromAppKit: CGRect(x: -200, y: 1000, width: 150, height: 300), referenceTop: 1080
        )
        XCTAssertEqual(converted, CGRect(x: -200, y: -220, width: 150, height: 300))
    }

    func testReverseDragIsStandardizedBeforeConversion() throws {
        let converted = try CaptureGeometry.quartzRect(
            fromAppKit: CGRect(x: 100, y: 100, width: -80, height: -60), referenceTop: 200
        )
        XCTAssertEqual(converted, CGRect(x: 20, y: 100, width: 80, height: 60))
    }

    func testMixedScalePlanKeepsBothDisplaysAndNativeTileSizes() throws {
        let displays = [
            CaptureDisplay(id: 1, frame: CGRect(x: -100, y: 0, width: 100, height: 100), scale: 1),
            CaptureDisplay(id: 2, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
        ]
        let plan = try CaptureGeometry.plan(
            region: CGRect(x: -50, y: 25, width: 100, height: 50), referenceTop: 100, displays: displays
        )
        XCTAssertEqual(plan.scale, 2)
        XCTAssertEqual(plan.pixelWidth, 200)
        XCTAssertEqual(plan.pixelHeight, 100)
        let left = try XCTUnwrap(plan.tiles.first { $0.displayID == 1 })
        let right = try XCTUnwrap(plan.tiles.first { $0.displayID == 2 })
        XCTAssertEqual(left.sourceRect, CGRect(x: 50, y: 25, width: 50, height: 50))
        XCTAssertEqual(left.pixelWidth, 50)
        XCTAssertEqual(left.destinationRect, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(right.pixelWidth, 100)
        XCTAssertEqual(right.destinationRect, CGRect(x: 100, y: 0, width: 100, height: 100))
    }

    func testUnselectedRetinaDisplayDoesNotIncreaseCanvasSize() throws {
        let plan = try CaptureGeometry.plan(
            region: CGRect(x: 0, y: 0, width: 10, height: 10), referenceTop: 10,
            displays: [
                CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 1),
                CaptureDisplay(id: 2, frame: CGRect(x: 10, y: 0, width: 10, height: 10), scale: 2)
            ]
        )
        XCTAssertEqual(plan.scale, 1)
        XCTAssertEqual(plan.tiles.count, 1)
        XCTAssertEqual(plan.pixelWidth, 10)
    }

    func testMirroredDisplaysAreCapturedOnceAtHigherScale() throws {
        let frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        let plan = try CaptureGeometry.plan(region: frame, referenceTop: 10, displays: [
            CaptureDisplay(id: 1, frame: frame, scale: 1), CaptureDisplay(id: 2, frame: frame, scale: 2)
        ])
        XCTAssertEqual(plan.tiles.map(\.displayID), [2])
    }

    func testSelectionInDisplayGapIsRejected() {
        XCTAssertThrowsError(try CaptureGeometry.plan(
            region: CGRect(x: 20, y: 0, width: 10, height: 10), referenceTop: 10,
            displays: [CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 1)]
        )) { XCTAssertEqual($0 as? CaptureError, .invalidRegion) }
    }

    func testInvalidAndOverflowingGeometryFailsBeforeAllocation() {
        for rectangle in [CGRect.zero, .null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)] {
            XCTAssertThrowsError(try CaptureGeometry.quartzRect(fromAppKit: rectangle, referenceTop: 100)) {
                XCTAssertEqual($0 as? CaptureError, .invalidRegion)
            }
        }
        XCTAssertThrowsError(try CaptureGeometry.pixelSize(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 2), scale: 2)) {
            XCTAssertEqual($0 as? CaptureError, .tooLarge)
        }
        XCTAssertThrowsError(try CaptureGeometry.pixelSize(CGSize(width: 4000, height: 4000), scale: 2)) {
            XCTAssertEqual($0 as? CaptureError, .tooLarge)
        }
        XCTAssertThrowsError(try CaptureGeometry.pixelSize(CGSize(width: 20_000, height: 1), scale: 1)) {
            XCTAssertEqual($0 as? CaptureError, .tooLarge)
        }
    }

    func testCompositorPreservesVerticalOrientationAndWhiteDisplayGaps() throws {
        let plan = try CaptureGeometry.plan(
            region: CGRect(x: 0, y: 0, width: 1, height: 5), referenceTop: 5,
            displays: [
                CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1, height: 2), scale: 1),
                CaptureDisplay(id: 2, frame: CGRect(x: 0, y: 3, width: 1, height: 2), scale: 1)
            ]
        )
        let top = try image(width: 1, rows: [[255, 0, 0, 255], [0, 0, 255, 255]])
        let bottom = try image(width: 1, rows: [[0, 255, 0, 255], [0, 0, 0, 255]])
        let composed = try CaptureGeometry.composite(plan: plan, images: [1: top, 2: bottom])
        XCTAssertEqual(try pixel(composed, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(composed, x: 0, y: 1), [0, 0, 255, 255])
        XCTAssertEqual(try pixel(composed, x: 0, y: 2), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(composed, x: 0, y: 3), [0, 255, 0, 255])
        XCTAssertEqual(try pixel(composed, x: 0, y: 4), [0, 0, 0, 255])
    }

    func testCompositorScalesMixedDensityTilesIntoOneCanvas() throws {
        let plan = try CaptureGeometry.plan(
            region: CGRect(x: -2, y: 0, width: 4, height: 2), referenceTop: 2,
            displays: [
                CaptureDisplay(id: 1, frame: CGRect(x: -2, y: 0, width: 2, height: 2), scale: 1),
                CaptureDisplay(id: 2, frame: CGRect(x: 0, y: 0, width: 2, height: 2), scale: 2)
            ]
        )
        let red = try image(width: 2, rows: Array(repeating: [255, 0, 0, 255], count: 2))
        let blue = try image(width: 4, rows: Array(repeating: [0, 0, 255, 255], count: 4))
        let composed = try CaptureGeometry.composite(plan: plan, images: [1: red, 2: blue])
        XCTAssertEqual(composed.width, 8)
        XCTAssertEqual(composed.height, 4)
        XCTAssertEqual(try pixel(composed, x: 1, y: 1), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(composed, x: 6, y: 1), [0, 0, 255, 255])
    }

    func testCompositorRejectsMissingTileInsteadOfReturningPartialSelection() throws {
        let frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        let plan = try CaptureGeometry.plan(region: frame, referenceTop: 2, displays: [
            CaptureDisplay(id: 1, frame: frame, scale: 1)
        ])
        XCTAssertThrowsError(try CaptureGeometry.composite(plan: plan, images: [:])) {
            XCTAssertEqual($0 as? CaptureError, .captureFailed)
        }
    }

    private func image(width: Int, rows: [[UInt8]]) throws -> CGImage {
        let bytes = rows.flatMap { Array(repeating: $0, count: width).flatMap { $0 } }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 4)])
    }
}

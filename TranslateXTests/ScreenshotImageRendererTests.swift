import AppKit
import CoreGraphics
import CoreText
import ImageIO
import XCTest
@testable import TranslateX

@MainActor
final class ScreenshotImageRendererTests: XCTestCase {
    func testPreviewMatchesTheSynchronousExportPixels() async throws {
        let image = try fixture { context in
            fill(context, rectangle: CGRect(x: 150, y: 42, width: 30, height: 28), color: [0.1, 0.1, 0.1, 1])
        }
        let target = region(CGRect(x: 20, y: 40, width: 220, height: 35))
        var document = ScreenshotDocument(image: image, regions: [target])
        document.translations[target.id] = "Hello"
        let exported = try XCTUnwrap(ScreenshotImageRenderer.render(document))
        let previewValue = await ScreenshotImageRenderer.renderPreview(document)
        let preview = try XCTUnwrap(previewValue)
        XCTAssertEqual(preview.overflowRegionIDs, exported.overflowRegionIDs)
        XCTAssertEqual(try pixels(preview.image).bytes, try pixels(exported.image).bytes)
    }

    func testCancelledPreviewDoesNotDeliverAnImage() async throws {
        let image = try fixture()
        let target = region(CGRect(x: 20, y: 40, width: 220, height: 35))
        var document = ScreenshotDocument(image: image, regions: [target])
        document.translations[target.id] = "Hello"
        let request = Task { await ScreenshotImageRenderer.renderPreview(document) }
        request.cancel()
        let result = await request.value
        XCTAssertNil(result)
    }

    func testRenderingKeepsOriginalResolutionAndUsesBottomLeftVisionCoordinates() throws {
        let lower = CGRect(x: 20, y: 18, width: 180, height: 30)
        let upper = CGRect(x: 20, y: 120, width: 180, height: 30)
        let image = try fixture { context in
            fill(context, rectangle: CGRect(x: 150, y: 20, width: 35, height: 24), color: [0.1, 0.1, 0.1, 1])
            fill(context, rectangle: upper, color: [0.7, 0.2, 0.4, 1])
        }
        let first = region(lower), second = region(upper)
        let result = try rendered(image, regions: [first, second], translations: [first.id: "Hello"])
        XCTAssertEqual(result.image.width, image.width)
        XCTAssertEqual(result.image.height, image.height)
        XCTAssertTrue(result.overflowRegionIDs.isEmpty)
        let before = try pixels(image), after = try pixels(result.image)
        XCTAssertNotEqual(before.pixel(160, 25), after.pixel(160, 25), "The lower OCR line must be repaired")
        for y in 0..<height {
            for x in 0..<width where !lower.insetBy(dx: -2, dy: -2).contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                XCTAssertEqual(after.pixel(x, y), before.pixel(x, y), "Unexpected change outside the bounded repair area at \(x),\(y)")
            }
        }
        XCTAssertEqual(after.pixel(80, 130), before.pixel(80, 130), "The untranslatable upper region stays untouched")
    }

    func testTightGlyphBoundsFitSmallTextRemoveAntialiasingAndProtectNearbyArtworkAndOCR() throws {
        for pointSize: CGFloat in [12, 14, 48] {
            var glyphs = CGRect.zero
            var nearbyArt = CGRect.zero
            var nearbyText = CGRect.zero
            let image = try fixture { context in
                glyphs = drawText("Read text here", size: pointSize, origin: CGPoint(x: 8, y: 65), in: context)
                nearbyArt = CGRect(x: ceil(glyphs.maxX) + 0.5, y: floor(glyphs.minY), width: 1, height: ceil(glyphs.height))
                nearbyText = CGRect(x: glyphs.minX + 20, y: glyphs.minY - 7, width: 35, height: 6)
                fill(context, rectangle: nearbyArt, color: [0.1, 0.5, 0.9, 1])
                fill(context, rectangle: nearbyText, color: [0.8, 0.2, 0.3, 1])
            }
            let target = region(glyphs), neighbor = region(nearbyText)
            let result = try rendered(image, regions: [target, neighbor], translations: [target.id: "译文"])
            XCTAssertTrue(result.overflowRegionIDs.isEmpty, "A \(pointSize) px source glyph box should fit two translated glyphs")
            let before = try pixels(image), after = try pixels(result.image)
            let repairLimit = glyphs.insetBy(dx: -2, dy: -2)
            for y in 0..<height {
                for x in 0..<width {
                    let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    if !repairLimit.contains(point) || nearbyText.contains(point) || nearbyArt.contains(point) {
                        XCTAssertEqual(after.pixel(x, y), before.pixel(x, y), "Changed a protected pixel at \(x),\(y), font \(pointSize)")
                    }
                }
            }
            let start = Int(ceil(glyphs.minX + glyphs.width * 0.65))
            for y in Int(floor(glyphs.minY))..<Int(ceil(glyphs.maxY) + 2) {
                for x in start..<Int(floor(glyphs.maxX)) {
                    assertClose(after.pixel(x, y), to: before.pixel(0, 0), tolerance: 2)
                }
            }
        }
    }

    func testLooseOCRBoundsAllowShortTranslationToFitDespiteExtraVerticalWhitespace() throws {
        var glyphs = CGRect.zero
        let image = try fixture { context in
            glyphs = drawText("Read text here", size: 12, origin: CGPoint(x: 30, y: 65), in: context)
        }
        let target = region(glyphs.insetBy(dx: -4, dy: -6))
        let result = try rendered(image, regions: [target], translations: [target.id: "阅读这里的文字"])
        XCTAssertTrue(result.overflowRegionIDs.isEmpty, "OCR vertical padding must not impose an oversized minimum font")
        XCTAssertNotEqual(try pixels(result.image).bytes, try pixels(image).bytes)
    }

    func testFullContrastGlyphFringeIsRemovedWhileDisconnectedSameColorArtworkIsPreserved() throws {
        let mask = CGRect(x: 20, y: 40, width: 150, height: 40)
        let artwork = CGRect(x: 130, y: 81, width: 8, height: 1)
        let image = try fixture(background: [0.1, 0.1, 0.1, 1]) { context in
            // Vision can exclude the last solid row of a glyph from its box.
            fill(context, rectangle: CGRect(x: 80, y: 60, width: 20, height: 21), color: [0.95, 0.95, 0.95, 1])
            fill(context, rectangle: artwork, color: [0.95, 0.95, 0.95, 1])
        }
        let target = region(mask)
        let result = try rendered(image, regions: [target], translations: [target.id: "Hi"])
        XCTAssertTrue(result.overflowRegionIDs.isEmpty)
        let before = try pixels(image), after = try pixels(result.image)
        for x in 80..<100 { assertClose(after.pixel(x, 80), to: before.pixel(0, 0), tolerance: 1) }
        for x in 130..<138 { XCTAssertEqual(after.pixel(x, 81), before.pixel(x, 81)) }
    }

    func testVisionDarkTextDoesNotLeaveBrightGlyphFragmentsOutsideLineBoxes() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 1100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 900, height: 1100).fill()
        for (text, y) in [("Good design keeps useful tools close.", 760.0),
                          ("It leaves more space for the conversation.", 715.0),
                          ("Small details make reading easier.", 225.0)] {
            (text as NSString).draw(at: NSPoint(x: 65, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1)
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(bitmap.cgImage)
        var document = try await OCRService().recognizeDocument(image)
        XCTAssertGreaterThanOrEqual(document.regions.count, 2)
        document.translations = Dictionary(uniqueKeysWithValues: document.regions.map { ($0.id, "译文") })
        let result = try XCTUnwrap(ScreenshotImageRenderer.render(document))
        XCTAssertTrue(result.overflowRegionIDs.isEmpty)
        let before = try pixels(image), after = try pixels(result.image)
        var originalInkPixels = 0
        for region in document.regions {
            for line in region.lineBounds {
                let box = CGRect(x: line.minX * 900, y: line.minY * 1100, width: line.width * 900, height: line.height * 1100)
                // A two-character translation occupies only the far left. The
                // rest must be clean, including the solid pixels Vision omitted.
                for y in max(0, Int(floor(box.minY)) - 2)..<min(1100, Int(ceil(box.maxY)) + 2) {
                    for x in Int(ceil(box.minX)) + 150..<min(900, Int(ceil(box.maxX)) + 2) {
                        if before.pixel(x, y)[0] > 100 { originalInkPixels += 1 }
                        assertClose(after.pixel(x, y), to: before.pixel(0, 0), tolerance: 2)
                    }
                }
            }
        }
        XCTAssertGreaterThan(originalInkPixels, 100, "The regression must exercise visible original glyphs")
    }

    func testGlyphRepairAtCanvasEdgeKeepsResolutionAndPixelsAwayFromTheRegion() throws {
        var glyphs = CGRect.zero
        let image = try fixture { context in
            glyphs = drawText("Read text here", size: 12, origin: CGPoint(x: 0, y: 1), in: context)
        }
        let target = region(glyphs)
        let result = try rendered(image, regions: [target], translations: [target.id: "译文"])
        XCTAssertTrue(result.overflowRegionIDs.isEmpty)
        XCTAssertEqual(result.image.width, width)
        XCTAssertEqual(result.image.height, height)
        let before = try pixels(image), after = try pixels(result.image)
        for y in 20..<height {
            for x in 0..<width { XCTAssertEqual(after.pixel(x, y), before.pixel(x, y)) }
        }
    }

    func testBackgroundRepairAndForegroundSamplingSupportLightDarkAndColoredDocuments() throws {
        let rectangle = CGRect(x: 20, y: 40, width: 230, height: 38)
        let samples: [([CGFloat], [CGFloat])] = [
            ([0.95, 0.95, 0.95, 1.0], [0.08, 0.08, 0.08, 1.0]),
            ([0.08, 0.10, 0.14, 1.0], [0.94, 0.95, 0.97, 1.0]),
            ([0.88, 0.94, 0.98, 1.0], [0.05, 0.25, 0.68, 1.0])
        ]
        for (background, foreground) in samples {
            let image = try fixture(background: background) { context in
                fill(context, rectangle: CGRect(x: 180, y: 43, width: 45, height: 30), color: foreground)
            }
            let target = region(rectangle)
            let result = try rendered(image, regions: [target], translations: [target.id: "Hi"])
            XCTAssertTrue(result.overflowRegionIDs.isEmpty)
            let before = try pixels(image), after = try pixels(result.image)
            assertClose(after.pixel(200, 55), to: before.pixel(10, 55), tolerance: 1)
            let ink = before.pixel(200, 55)
            let matchingInk = (40..<78).contains { y in
                (20..<85).contains { x in colorDistance(after.pixel(x, y), ink) <= 4 }
            }
            XCTAssertTrue(matchingInk, "Translated glyphs should retain the sampled foreground color")
        }
    }

    func testGradientRepairAvoidsAFlatWhiteRectangle() throws {
        let rectangle = CGRect(x: 25, y: 45, width: 240, height: 40)
        let image = try fixture { context in
            for x in 0..<width {
                let t = Double(x) / Double(width - 1)
                fill(context, rectangle: CGRect(x: x, y: 0, width: 1, height: height),
                     color: [0.30 + t * 0.55, 0.40 + t * 0.35, 0.50 + t * 0.25, 1])
            }
            fill(context, rectangle: CGRect(x: 160, y: 49, width: 75, height: 30), color: [0.02, 0.02, 0.02, 1])
        }
        let target = region(rectangle)
        let result = try rendered(image, regions: [target], translations: [target.id: "Hi"])
        XCTAssertTrue(result.overflowRegionIDs.isEmpty)
        let before = try pixels(image), after = try pixels(result.image)
        for x in [160, 190, 220] {
            assertClose(after.pixel(x, 60), to: before.pixel(x, 100), tolerance: 4)
        }
        XCTAssertGreaterThan(after.pixel(220, 60)[0] - after.pixel(160, 60)[0], 15)
    }

    func testParagraphRepairUsesIndividualLinesAndPreservesTheGap() throws {
        let rectangle = CGRect(x: 20, y: 25, width: 240, height: 75)
        let lines = [CGRect(x: 20, y: 25, width: 210, height: 27), CGRect(x: 20, y: 73, width: 240, height: 27)]
        let gap = CGRect(x: 160, y: 57, width: 35, height: 8)
        let image = try fixture { context in
            for line in lines {
                fill(context, rectangle: CGRect(x: 170, y: line.minY + 2, width: 25, height: 22), color: [0.1, 0.1, 0.1, 1])
            }
            fill(context, rectangle: gap, color: [0.1, 0.6, 0.9, 1])
        }
        let target = region(rectangle, lines: lines)
        let result = try rendered(image, regions: [target], translations: [target.id: "Short"])
        XCTAssertTrue(result.overflowRegionIDs.isEmpty)
        let before = try pixels(image), after = try pixels(result.image)
        XCTAssertEqual(after.pixel(175, 60), before.pixel(175, 60))
        assertClose(after.pixel(180, 35), to: before.pixel(10, 35), tolerance: 1)
        assertClose(after.pixel(180, 85), to: before.pixel(10, 85), tolerance: 1)
    }

    func testTooLongTranslationPreservesOriginalPixelsAndReportsOverflowWithoutTruncation() throws {
        let image = try fixture { context in
            fill(context, rectangle: CGRect(x: 25, y: 30, width: 45, height: 15), color: [0, 0, 0, 1])
        }
        let target = region(CGRect(x: 20, y: 25, width: 70, height: 25))
        let result = try rendered(image, regions: [target], translations: [target.id: String(repeating: "完整的长译文不能被静默裁剪。", count: 100)])
        XCTAssertEqual(result.overflowRegionIDs, [target.id])
        XCTAssertEqual(try pixels(result.image).bytes, try pixels(image).bytes)
    }

    func testUntranslatedBlankAndUnchangedRegionsReuseTheOriginalImage() throws {
        let image = try fixture()
        let target = region(CGRect(x: 20, y: 20, width: 100, height: 30))
        for translation in [nil, "", " \n ", target.text] {
            let result = try rendered(image, regions: [target], translations: translation.map { [target.id: $0] } ?? [:])
            XCTAssertTrue(result.image === image)
            XCTAssertTrue(result.overflowRegionIDs.isEmpty)
        }
    }

    func testOverlappingAndInvalidRegionsKeepPixelsAndRequireTextDetails() throws {
        let image = try fixture()
        let translated = region(CGRect(x: 20, y: 20, width: 120, height: 35))
        let untouched = region(CGRect(x: 100, y: 20, width: 100, height: 35))
        let invalid = ScreenshotRegion(id: UUID(), text: "Constructed invalid box", bounds: CGRect(x: 2, y: 2, width: 0.1, height: 0.1),
                                       confidence: 1, role: .paragraph, separator: "")
        let result = try rendered(image, regions: [translated, untouched, invalid], translations: [translated.id: "Bonjour", invalid.id: "Hello"])
        XCTAssertEqual(result.overflowRegionIDs, [translated.id, invalid.id])
        XCTAssertEqual(try pixels(result.image).bytes, try pixels(image).bytes)
    }

    func testPNGExportPreservesResolutionTransparencyAndUntouchedAlpha() throws {
        let image = try fixture(background: [0, 0, 0, 0]) { context in
            fill(context, rectangle: CGRect(x: 180, y: 45, width: 35, height: 30), color: [0.05, 0.25, 0.65, 1])
            fill(context, rectangle: CGRect(x: 10, y: 130, width: 30, height: 25), color: [0.7, 0.2, 0.4, 0.5])
        }
        let target = region(CGRect(x: 20, y: 40, width: 230, height: 40))
        let result = try rendered(image, regions: [target], translations: [target.id: "Hello"])
        XCTAssertTrue(result.overflowRegionIDs.isEmpty)
        let data = try XCTUnwrap(ScreenshotImageExport.pngData(result.image))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        let exported = try pixels(decoded)
        XCTAssertEqual(exported.pixel(5, 5)[3], 0)
        XCTAssertEqual(exported.pixel(190, 50)[3], 0, "Old text is repaired to the transparent background")
        XCTAssertEqual(exported.pixel(20, 140), try pixels(image).pixel(20, 140))
        XCTAssertEqual(exported.bytes, try pixels(result.image).bytes)
    }

    private let width = 300
    private let height = 180
    private var colorSpace: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    private func fixture(background: [CGFloat] = [0.95, 0.95, 0.95, 1], draw: (CGContext) -> Void = { _ in }) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        fill(context, rectangle: CGRect(x: 0, y: 0, width: width, height: height), color: background)
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func fill(_ context: CGContext, rectangle: CGRect, color: [CGFloat]) {
        context.setFillColor(CGColor(colorSpace: colorSpace, components: color)!)
        context.fill(rectangle)
    }

    private func drawText(_ text: String, size: CGFloat, origin: CGPoint, in context: CGContext) -> CGRect {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = origin
        CTLineDraw(line, context)
        return CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).offsetBy(dx: origin.x, dy: origin.y)
    }

    private func region(_ rectangle: CGRect, lines: [CGRect] = []) -> ScreenshotRegion {
        func normalized(_ value: CGRect) -> CGRect {
            CGRect(x: value.minX / Double(width), y: value.minY / Double(height),
                   width: value.width / Double(width), height: value.height / Double(height))
        }
        return ScreenshotRegion(id: UUID(), text: "Constructed original text", bounds: normalized(rectangle), confidence: 1,
                                role: .paragraph, separator: "", lineBounds: lines.map(normalized))
    }

    private func rendered(_ image: CGImage, regions: [ScreenshotRegion], translations: [UUID: String]) throws -> ScreenshotRenderedImage {
        var document = ScreenshotDocument(image: image, regions: regions)
        document.translations = translations
        return try XCTUnwrap(ScreenshotImageRenderer.render(document))
    }

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let offset = ((height - 1 - y) * width + x) * 4
            return bytes[offset..<offset + 4].map(Int.init)
        }
    }

    private func pixels(_ image: CGImage) throws -> Pixels {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        return Pixels(bytes: bytes, width: image.width, height: image.height)
    }

    private func colorDistance(_ first: [Int], _ second: [Int]) -> Int { zip(first, second).map { abs($0 - $1) }.max() ?? 0 }
    private func assertClose(_ actual: [Int], to expected: [Int], tolerance: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(colorDistance(actual, expected), tolerance, "\(actual) differs from \(expected)", file: file, line: line)
    }
}

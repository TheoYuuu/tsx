import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScreenshotRenderedImage: Sendable {
    let image: CGImage
    /// These translations cannot fit at a readable size. Their original pixels
    /// remain intact; the presentation must offer the complete text separately.
    let overflowRegionIDs: Set<UUID>
}

/// Local composition only. The complete captured image remains the canvas;
/// translated OCR lines supply the repair mask, colors and typesetting bounds.
enum ScreenshotImageRenderer {
    static func renderPreview(_ document: ScreenshotDocument) async -> ScreenshotRenderedImage? {
        guard !Task.isCancelled else { return nil }
        let task = Task.detached(priority: .userInitiated) { render(document) }
        return await withTaskCancellationHandler {
            let result = await task.value
            return Task.isCancelled ? nil : result
        } onCancel: {
            task.cancel()
        }
    }

    static func render(_ document: ScreenshotDocument) -> ScreenshotRenderedImage? {
        guard !Task.isCancelled else { return nil }
        let translated = document.regions.filter {
            guard let value = document.translations[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !value.isEmpty && value != $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !translated.isEmpty else {
            return ScreenshotRenderedImage(image: document.image, overflowRegionIDs: [])
        }
        guard let original = Bitmap(image: document.image), let output = Bitmap(image: document.image) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let bounds = document.regions.compactMap { region -> (UUID, CGRect)? in
            pixelBounds(region.bounds, canvas: canvas).map { (region.id, $0) }
        }
        let occupied = document.regions.flatMap { region in
            (region.lineBounds.isEmpty ? [region.bounds] : region.lineBounds).compactMap { pixelBounds($0, canvas: canvas) }
        }
        var overflow = Set<UUID>()
        for region in translated {
            guard !Task.isCancelled else { return nil }
            guard let rectangle = pixelBounds(region.bounds, canvas: canvas),
                  rectangle.width >= 2, rectangle.height >= 2,
                  let text = document.translations[region.id]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                overflow.insert(region.id)
                continue
            }
            // Overlapping OCR boxes cannot safely erase one another. Preserve
            // the pixels and expose the full translation instead of guessing.
            guard !bounds.contains(where: { $0.0 != region.id && rectangle.intersects($0.1) }) else {
                overflow.insert(region.id)
                continue
            }
            let lines = region.lineBounds.compactMap { pixelBounds($0, canvas: canvas)?.intersection(rectangle) }
                .filter { !$0.isEmpty }
            let masks = lines.isEmpty ? [rectangle] : lines
            let neighbors = bounds.filter { $0.0 != region.id }.map(\.1)
            let repairMasks = masks.map { mask in
                expanded(mask, within: canvas, avoiding: neighbors + masks.filter { $0 != mask })
            }
            let padded = expanded(rectangle, within: canvas, avoiding: neighbors)
            // Keep the source's left and top edges. A small amount of free
            // space below the glyph box can accommodate a different script.
            let layout = CGRect(x: rectangle.minX, y: padded.minY,
                                width: rectangle.width, height: rectangle.maxY - padded.minY)
            let background = Background(rectangle: rectangle, bitmap: original, occupied: occupied)
            let appearance = textAppearance(in: masks, background: background, bitmap: original)
            let foreground = appearance.color
            guard let fitted = fittedFrame(text: text, size: layout.size, lineHeight: appearance.lineHeight,
                                          heading: region.role == .heading, color: foreground) else {
                overflow.insert(region.id)
                continue
            }
            // Repair individual lines rather than blanking an entire paragraph:
            // line gaps, illustrations and other untouched pixels remain intact.
            for (line, repairMask) in zip(masks, repairMasks) {
                let repair = Background(rectangle: repairMask, bitmap: original, occupied: occupied)
                guard repair.paint(into: output, source: original, originalMask: line, foreground: foreground) else { return nil }
            }
            output.context.saveGState()
            output.context.clip(to: layout)
            output.context.translateBy(x: layout.minX + fitted.offset.x, y: layout.minY + fitted.offset.y)
            output.context.textMatrix = .identity
            output.context.setShouldAntialias(true)
            output.context.setShouldSmoothFonts(false)
            CTFrameDraw(fitted.frame, output.context)
            output.context.restoreGState()
        }
        guard !Task.isCancelled, let image = output.context.makeImage() else { return nil }
        return ScreenshotRenderedImage(image: image, overflowRegionIDs: overflow)
    }

    private static func pixelBounds(_ value: CGRect, canvas: CGRect) -> CGRect? {
        guard [value.minX, value.minY, value.width, value.height].allSatisfy(\.isFinite),
              value.width > 0, value.height > 0 else { return nil }
        let scaled = CGRect(x: value.minX * canvas.width, y: value.minY * canvas.height,
                            width: value.width * canvas.width, height: value.height * canvas.height)
        let clipped = scaled.intersection(canvas)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    /// OCR boxes describe glyphs, so antialiasing can extend into the next
    /// pixel. Never claim more than half the free gap to another text region.
    private static func expanded(_ rectangle: CGRect, within canvas: CGRect, avoiding obstacles: [CGRect]) -> CGRect {
        var result = rectangle.insetBy(dx: -2, dy: -2).intersection(canvas)
        for obstacle in obstacles where result.intersects(obstacle.insetBy(dx: -2, dy: -2)) {
            var left = result.minX, right = result.maxX, bottom = result.minY, top = result.maxY
            if obstacle.maxX <= rectangle.minX { left = max(left, (rectangle.minX + obstacle.maxX) / 2) }
            if obstacle.minX >= rectangle.maxX { right = min(right, (rectangle.maxX + obstacle.minX) / 2) }
            if obstacle.maxY <= rectangle.minY { bottom = max(bottom, (rectangle.minY + obstacle.maxY) / 2) }
            if obstacle.minY >= rectangle.maxY { top = min(top, (rectangle.maxY + obstacle.minY) / 2) }
            result = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        }
        return result
    }

    private struct FittedText {
        let frame: CTFrame
        let offset: CGPoint
    }

    private static func fittedFrame(text: String, size: CGSize, lineHeight: CGFloat,
                                    heading: Bool, color: Pixel) -> FittedText? {
        let maximum = min(120, max(9, lineHeight * 1.2))
        let minimum = max(9, maximum * 0.6)
        func frame(at pointSize: CGFloat) -> FittedText? {
            guard !Task.isCancelled else { return nil }
            let base = CTFontCreateUIFontForLanguage(.system, pointSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
            let font = heading ? CTFontCreateCopyWithSymbolicTraits(base, pointSize, nil, .traitBold, .traitBold) ?? base : base
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let setter = CTFramesetterCreateWithAttributedString(string)
            // Lay out in a tall frame, then measure actual ink. A tight Vision
            // glyph box is often shorter than CoreText's typographic line box.
            let height = max(size.height, pointSize * CGFloat(string.length + 1) * 2)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: size.width, height: height), transform: nil)
            let result = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(result)
            guard visible.location == 0, visible.length >= string.length else { return nil }
            // CoreText can lay out a glyph wider than a very narrow path. Check
            // actual line extents too; a clip is never treated as a successful fit.
            let lines = CTFrameGetLines(result) as! [CTLine]
            guard !lines.isEmpty else { return nil }
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(result, CFRange(location: 0, length: 0), &origins)
            let ink = zip(lines, origins).reduce(CGRect.null) { bounds, line in
                bounds.union(CTLineGetBoundsWithOptions(line.0, [.useGlyphPathBounds])
                    .offsetBy(dx: line.1.x, dy: line.1.y))
            }
            guard !ink.isNull, ink.width <= size.width, ink.height <= size.height else { return nil }
            return FittedText(frame: result, offset: CGPoint(x: -ink.minX, y: size.height - ink.maxY))
        }
        if let largest = frame(at: maximum) { return largest }
        guard var best = frame(at: minimum) else { return nil }
        var lower = minimum, upper = maximum
        for _ in 0..<8 {
            let middle = (lower + upper) / 2
            if let candidate = frame(at: middle) { best = candidate; lower = middle }
            else { upper = middle }
        }
        return best
    }

    private static func textAppearance(in rectangles: [CGRect], background: Background, bitmap: Bitmap) -> (color: Pixel, lineHeight: CGFloat) {
        var candidates: [(contrast: Double, pixel: Pixel, line: Int, y: Int)] = []
        let area = rectangles.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        let step = max(1, Int(ceil(sqrt(area / 2_000))))
        for (index, rectangle) in rectangles.enumerated() {
            for y in stride(from: max(0, Int(rectangle.minY)), to: min(bitmap.height, Int(ceil(rectangle.maxY))), by: step) {
                for x in stride(from: max(0, Int(rectangle.minX)), to: min(bitmap.width, Int(ceil(rectangle.maxX))), by: step) {
                    let pixel = bitmap.pixel(x: x, y: y)
                    let backdrop = background.color(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    let contrast = pixel.distance(to: backdrop)
                    if pixel.a > 0.2, contrast > 0.12 { candidates.append((contrast, pixel, index, y)) }
                }
            }
        }
        candidates.sort { $0.0 > $1.0 }
        if let strongest = candidates.first {
            let significant = candidates.prefix(256).filter { $0.0 >= strongest.0 * 0.7 }.map(\.pixel)
            var color = Pixel.median(significant)
            color.a = 1
            // Vision may include substantial vertical whitespace. Estimate
            // source glyph height from sampled ink before imposing a relative
            // minimum font size, especially for small text in a tall OCR box.
            let heights = rectangles.indices.compactMap { index -> CGFloat? in
                let rows = candidates.filter { $0.line == index && $0.pixel.distance(to: color) < 0.2 }.map(\.y)
                guard let low = rows.min(), let high = rows.max() else { return nil }
                return min(rectangles[index].height, CGFloat(high - low + step))
            }.sorted()
            let measured = heights.isEmpty ? rectangles.map(\.height).sorted()[rectangles.count / 2] : heights[heights.count / 2]
            return (color, measured)
        }
        let center = background.color(x: background.rectangle.midX, y: background.rectangle.midY)
        return (center.luminance > 0.5 || center.a < 0.2 ? .black : .white,
                rectangles.map(\.height).sorted()[rectangles.count / 2])
    }

    private struct Bitmap {
        let context: CGContext
        let bytes: UnsafeMutablePointer<UInt8>
        let width: Int
        let height: Int

        init?(image: CGImage) {
            width = image.width; height = image.height
            guard width > 0, height > 0, width <= CaptureGeometry.maximumDimension,
                  height <= CaptureGeometry.maximumDimension,
                  width <= CaptureGeometry.maximumPixelCount / height,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: Self.colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  let data = context.data else { return nil }
            self.context = context
            bytes = data.assumingMemoryBound(to: UInt8.self)
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.setBlendMode(.normal)
        }

        static var colorSpace: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

        func pixel(x: Int, y: Int) -> Pixel {
            // Bitmap rows are top-first; Quartz and Vision coordinates are bottom-left.
            let offset = ((height - 1 - min(height - 1, max(0, y))) * width + min(width - 1, max(0, x))) * 4
            let alpha = Double(bytes[offset + 3]) / 255
            guard alpha > 0 else { return Pixel(r: 0, g: 0, b: 0, a: 0) }
            return Pixel(r: Double(bytes[offset]) / 255 / alpha,
                         g: Double(bytes[offset + 1]) / 255 / alpha,
                         b: Double(bytes[offset + 2]) / 255 / alpha, a: alpha)
        }

        func setPixel(_ pixel: Pixel, x: Int, y: Int) {
            let offset = ((height - 1 - y) * width + x) * 4
            func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
            bytes[offset] = byte(pixel.r * pixel.a)
            bytes[offset + 1] = byte(pixel.g * pixel.a)
            bytes[offset + 2] = byte(pixel.b * pixel.a)
            bytes[offset + 3] = byte(pixel.a)
        }
    }

    private struct Pixel {
        var r: Double
        var g: Double
        var b: Double
        var a: Double
        static let black = Pixel(r: 0, g: 0, b: 0, a: 1)
        static let white = Pixel(r: 1, g: 1, b: 1, a: 1)
        var luminance: Double { r * 0.2126 + g * 0.7152 + b * 0.0722 }
        var cgColor: CGColor { CGColor(colorSpace: Bitmap.colorSpace, components: [r, g, b, a])! }
        func distance(to other: Pixel) -> Double {
            max(abs(a - other.a), sqrt(pow(r - other.r, 2) + pow(g - other.g, 2) + pow(b - other.b, 2)) / sqrt(3))
        }
        func matchesInk(_ foreground: Pixel, over background: Pixel) -> Bool {
            // Vision can omit solid glyph pixels as well as antialiasing.
            // Connectivity to the original mask decides whether these pixels
            // belong to text; color alone must not erase nearby artwork.
            let base = [background.r * background.a, background.g * background.a, background.b * background.a, background.a]
            let ink = [foreground.r * foreground.a, foreground.g * foreground.a, foreground.b * foreground.a, foreground.a]
            let sample = [r * a, g * a, b * a, a]
            let direction = zip(ink, base).map(-)
            let difference = zip(sample, base).map(-)
            let length = direction.reduce(0) { $0 + $1 * $1 }
            guard length > 0.001 else { return false }
            let fraction = zip(direction, difference).reduce(0) { $0 + $1.0 * $1.1 } / length
            guard fraction > 0.005, fraction < 1.08 else { return false }
            return zip(direction, difference).allSatisfy { abs($0.1 - $0.0 * fraction) < 0.04 }
        }
        static func mix(_ a: Pixel, _ b: Pixel, fraction: Double) -> Pixel {
            let t = max(0, min(1, fraction))
            return Pixel(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t,
                         b: a.b + (b.b - a.b) * t, a: a.a + (b.a - a.a) * t)
        }
        static func median(_ pixels: [Pixel]) -> Pixel {
            guard !pixels.isEmpty else { return .white }
            func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
            return Pixel(r: median(pixels.map(\.r)), g: median(pixels.map(\.g)),
                         b: median(pixels.map(\.b)), a: median(pixels.map(\.a)))
        }
    }

    private struct Background {
        let rectangle: CGRect
        let bottomLeft: Pixel
        let bottomRight: Pixel
        let topLeft: Pixel
        let topRight: Pixel

        init(rectangle: CGRect, bitmap: Bitmap, occupied: [CGRect]) {
            self.rectangle = rectangle
            func sample(x: Double, y: Double, fallback: CGPoint) -> Pixel {
                var pixels: [Pixel] = []
                for dy in -2...2 {
                    for dx in -2...2 {
                        let px = Int(x.rounded()) + dx, py = Int(y.rounded()) + dy
                        guard px >= 0, py >= 0, px < bitmap.width, py < bitmap.height,
                              !occupied.contains(where: { $0.contains(CGPoint(x: Double(px) + 0.5, y: Double(py) + 0.5)) }) else { continue }
                        pixels.append(bitmap.pixel(x: px, y: py))
                    }
                }
                return pixels.isEmpty ? bitmap.pixel(x: Int(fallback.x), y: Int(fallback.y)) : Pixel.median(pixels)
            }
            bottomLeft = sample(x: rectangle.minX - 2, y: rectangle.minY - 2,
                                fallback: CGPoint(x: rectangle.minX, y: rectangle.minY))
            bottomRight = sample(x: rectangle.maxX + 1, y: rectangle.minY - 2,
                                 fallback: CGPoint(x: rectangle.maxX - 1, y: rectangle.minY))
            topLeft = sample(x: rectangle.minX - 2, y: rectangle.maxY + 1,
                             fallback: CGPoint(x: rectangle.minX, y: rectangle.maxY - 1))
            topRight = sample(x: rectangle.maxX + 1, y: rectangle.maxY + 1,
                              fallback: CGPoint(x: rectangle.maxX - 1, y: rectangle.maxY - 1))
        }

        func color(x: Double, y: Double) -> Pixel {
            let horizontal = (x - rectangle.minX) / max(1, rectangle.width)
            let vertical = (y - rectangle.minY) / max(1, rectangle.height)
            return Pixel.mix(Pixel.mix(bottomLeft, bottomRight, fraction: horizontal),
                             Pixel.mix(topLeft, topRight, fraction: horizontal), fraction: vertical)
        }

        func paint(into bitmap: Bitmap, source: Bitmap, originalMask: CGRect, foreground: Pixel) -> Bool {
            let area = rectangle
            guard !area.isEmpty else { return true }
            for y in max(0, Int(floor(area.minY)))..<min(bitmap.height, Int(ceil(area.maxY))) {
                guard !Task.isCancelled else { return false }
                for x in max(0, Int(floor(area.minX)))..<min(bitmap.width, Int(ceil(area.maxX))) {
                    let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    guard area.contains(point) else { continue }
                    let background = color(x: point.x, y: point.y)
                    guard originalMask.contains(point) || connectedToText(x: x, y: y, source: source,
                        originalMask: originalMask, foreground: foreground) else { continue }
                    bitmap.setPixel(background, x: x, y: y)
                }
            }
            return true
        }

        private func connectedToText(x: Int, y: Int, source: Bitmap, originalMask: CGRect, foreground: Pixel) -> Bool {
            // Expansion is capped at two pixels. Follow matching ink only that
            // far, requiring a continuous path back into the source OCR line.
            // Disconnected rules/icons of exactly the same color stay intact.
            var frontier = [(x, y)]
            var visited = Set<Int>()
            for depth in 0...2 {
                var next: [(Int, Int)] = []
                for (px, py) in frontier {
                    guard px >= 0, py >= 0, px < source.width, py < source.height,
                          visited.insert(py * source.width + px).inserted else { continue }
                    let point = CGPoint(x: Double(px) + 0.5, y: Double(py) + 0.5)
                    guard rectangle.contains(point), source.pixel(x: px, y: py)
                        .matchesInk(foreground, over: color(x: point.x, y: point.y)) else { continue }
                    if originalMask.contains(point) { return true }
                    if depth < 2 {
                        for dy in -1...1 {
                            for dx in -1...1 where dx != 0 || dy != 0 { next.append((px + dx, py + dy)) }
                        }
                    }
                }
                frontier = next
            }
            return false
        }
    }
}

/// Encodes only the supplied pixels; no captured application metadata is added.
enum ScreenshotImageExport {
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

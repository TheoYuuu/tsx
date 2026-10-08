import CoreGraphics
import Foundation

struct CaptureDisplay: Sendable, Equatable {
    let id: CGDirectDisplayID
    /// Quartz global screen coordinates: points, with the primary display's top left at zero.
    let frame: CGRect
    let scale: CGFloat
}

/// The coordinate system the user saw while choosing a region, without screen pixels.
struct CaptureLayoutSnapshot: Sendable, Equatable {
    let primaryDisplayID: CGDirectDisplayID
    let referenceTop: CGFloat
    let displays: [CaptureDisplay]

    init(primaryDisplayID: CGDirectDisplayID, referenceTop: CGFloat, displays: [CaptureDisplay]) {
        self.primaryDisplayID = primaryDisplayID
        self.referenceTop = referenceTop
        self.displays = displays.sorted { $0.id < $1.id }
    }

    /// ScreenCaptureKit can include mirrored displays omitted by NSScreen. Capture
    /// only the displays present during selection, and require their metadata to agree.
    func matchingDisplays(in candidates: [CaptureDisplay]) throws -> [CaptureDisplay] {
        guard !displays.isEmpty else { throw CaptureError.screenConfigurationChanged }
        return try displays.map { expected in
            let matches = candidates.filter { $0.id == expected.id }
            guard matches.count == 1, matches.first == expected else {
                throw CaptureError.screenConfigurationChanged
            }
            return expected
        }
    }
}

struct CaptureTile: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    /// Display-local points in the display's logical coordinate system.
    let sourceRect: CGRect
    /// Pixel coordinates in the assembled image, measured from its top left.
    let destinationRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

struct CapturePlan: Sendable, Equatable {
    let quartzRegion: CGRect
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    let tiles: [CaptureTile]
}

enum CaptureGeometry {
    static let maximumPixelCount = 32_000_000
    static let maximumDimension = 16_384

    static func quartzRect(fromAppKit region: CGRect, referenceTop: CGFloat) throws -> CGRect {
        guard referenceTop.isFinite, finite(region) else { throw CaptureError.invalidRegion }
        let rectangle = region.standardized
        guard rectangle.width > 0, rectangle.height > 0 else { throw CaptureError.invalidRegion }
        let result = CGRect(
            x: rectangle.minX, y: referenceTop - rectangle.maxY,
            width: rectangle.width, height: rectangle.height
        )
        guard finite(result) else { throw CaptureError.invalidRegion }
        return result
    }

    static func plan(region: CGRect, referenceTop: CGFloat, displays: [CaptureDisplay]) throws -> CapturePlan {
        let selection = try quartzRect(fromAppKit: region, referenceTop: referenceTop)
        guard !displays.isEmpty else { throw CaptureError.noDisplays }
        var intersections: [(display: CaptureDisplay, rectangle: CGRect)] = []
        // Mirrored displays may have identical frames. Retain their highest-resolution
        // representation so we do not capture and overwrite the same content twice.
        let ordered = displays.sorted { $0.scale == $1.scale ? $0.id < $1.id : $0.scale > $1.scale }
        for display in ordered {
            guard finite(display.frame), display.frame.width > 0, display.frame.height > 0,
                  display.scale.isFinite, display.scale > 0 else { throw CaptureError.captureFailed }
            guard !intersections.contains(where: { $0.display.frame == display.frame }) else { continue }
            let rectangle = selection.intersection(display.frame)
            guard !rectangle.isNull, !rectangle.isEmpty else { continue }
            intersections.append((display, rectangle))
        }
        guard let scale = intersections.map(\.display.scale).max() else { throw CaptureError.invalidRegion }
        let size = try pixelSize(selection.size, scale: scale)
        let tiles = try intersections.map { item in
            let nativeSize = try pixelSize(item.rectangle.size, scale: item.display.scale)
            return CaptureTile(
                displayID: item.display.id,
                sourceRect: item.rectangle.offsetBy(dx: -item.display.frame.minX, dy: -item.display.frame.minY),
                destinationRect: CGRect(
                    x: (item.rectangle.minX - selection.minX) * scale,
                    y: (item.rectangle.minY - selection.minY) * scale,
                    width: item.rectangle.width * scale, height: item.rectangle.height * scale
                ),
                pixelWidth: nativeSize.width, pixelHeight: nativeSize.height
            )
        }
        return CapturePlan(
            quartzRegion: selection, scale: scale,
            pixelWidth: size.width, pixelHeight: size.height, tiles: tiles
        )
    }

    /// Synthetic-image tests exercise this same compositor without requesting screen access.
    static func composite(plan: CapturePlan, images: [CGDirectDisplayID: CGImage]) throws -> CGImage {
        try Task.checkCancellation()
        try validatePixelSize(width: plan.pixelWidth, height: plan.pixelHeight)
        guard !plan.tiles.isEmpty, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: plan.pixelWidth, height: plan.pixelHeight,
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw CaptureError.captureFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: plan.pixelWidth, height: plan.pixelHeight))
        context.interpolationQuality = .high
        context.setShouldAntialias(false)
        for tile in plan.tiles {
            try Task.checkCancellation()
            guard let image = images[tile.displayID] else { throw CaptureError.captureFailed }
            let rectangle = tile.destinationRect
            guard finite(rectangle), rectangle.width > 0, rectangle.height > 0 else {
                throw CaptureError.captureFailed
            }
            // The plan uses top-left pixel coordinates; a Quartz bitmap context uses
            // bottom-left drawing coordinates. CGImage itself needs no additional flip.
            context.draw(image, in: CGRect(
                x: rectangle.minX,
                y: CGFloat(plan.pixelHeight) - rectangle.maxY,
                width: rectangle.width, height: rectangle.height
            ))
        }
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw CaptureError.captureFailed }
        return image
    }

    static func pixelSize(_ size: CGSize, scale: CGFloat) throws -> (width: Int, height: Int) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              scale.isFinite, scale > 0 else { throw CaptureError.invalidRegion }
        let width = ceil(size.width * scale)
        let height = ceil(size.height * scale)
        // Check bounds before converting CGFloat to Int, multiplying, or allocating.
        guard width.isFinite, height.isFinite,
              width <= CGFloat(maximumDimension), height <= CGFloat(maximumDimension) else {
            throw CaptureError.tooLarge
        }
        let result = (width: Int(width), height: Int(height))
        try validatePixelSize(width: result.width, height: result.height)
        return result
    }

    private static func validatePixelSize(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw CaptureError.invalidRegion }
        guard width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixelCount / height else { throw CaptureError.tooLarge }
    }

    private static func finite(_ rectangle: CGRect) -> Bool {
        !rectangle.isNull && !rectangle.isInfinite
            && rectangle.origin.x.isFinite && rectangle.origin.y.isFinite
            && rectangle.width.isFinite && rectangle.height.isFinite
            && rectangle.minX.isFinite && rectangle.minY.isFinite
            && rectangle.maxX.isFinite && rectangle.maxY.isFinite
    }
}
